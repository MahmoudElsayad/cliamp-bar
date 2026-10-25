import Foundation
import Darwin

private func runtimeLine(revision: Int = 8, sequence: Int = 10, retained: Bool = false) -> String {
    "{\"event\":\"runtime.state\",\"seq\":\(sequence),\"time\":1792930250,\(retained ? "\"retained\":true," : "")\"data\":{\"revision\":\(revision),\"playlist_revision\":2,\"state\":\"paused\",\"position\":12,\"speed\":1.5,\"track\":{\"title\":\"Song\"}}}"
}

private func runtimePump(_ seconds: TimeInterval) { RunLoop.current.run(until: Date().addingTimeInterval(seconds)) }

func runtimeStateTests() throws {
    let retained = runtimeLine(retained: true)
    let live = runtimeLine(revision: 9, sequence: 11)
    var parser = RuntimeStateParser()
    var split: [RuntimeStateEvent] = []
    for byte in (retained + "\n").utf8 { split += parser.append(Data([byte])) }
    try expect(split.count == 1 && split[0].retained && split[0].data.speed == 1.5,
               "Split retained envelopes decode the actual runtime state schema")
    let batch = parser.append(Data((live + "\r\n" + retained + "\n").utf8))
    try expect(batch.count == 2 && !batch[0].retained && batch[1].retained,
               "Real live envelopes omit retained and default to false")
    for malformed in ["{}", "garbage", live.replacingOccurrences(of: "runtime.state", with: "other.topic"),
                      live.replacingOccurrences(of: "\"seq\":11", with: "\"seq\":\"bad\""),
                      live.replacingOccurrences(of: "\"position\":12", with: "\"position\":1e9999") ] {
        try expect(parser.append(Data((malformed + "\n").utf8)).isEmpty, "Malformed envelopes cannot publish state")
    }
    _ = parser.append(Data(repeating: 32, count: RuntimeStateParser.lineLimit + 1))
    try expect(parser.append(Data((live + "\n").utf8)).isEmpty, "An oversized envelope discards its valid suffix")
    try expect(parser.append(Data((live + "\n").utf8)).count == 1, "The parser recovers on the following line")

    let directory = FileManager.default.temporaryDirectory.appendingPathComponent("cliampbar-runtime-" + UUID().uuidString)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    let log = directory.appendingPathComponent("children")
    func script(_ name: String, body: String) throws -> URL {
        let path = directory.appendingPathComponent(name)
        let source = "#!/bin/sh\nprintf '%s %s %s %s\\n' \"$$\" \"$1\" \"$2\" \"$3\" >> '\(log.path)'\n" + body
        try source.write(to: path, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: path.path)
        return path
    }
    func launches() -> [(Int32, String)] {
        ((try? String(contentsOf: log, encoding: .utf8)) ?? "").split(separator: "\n").compactMap {
            guard let pid = Int32($0.split(separator: " ")[0]) else { return nil }
            return (pid, String($0))
        }
    }
    let executable = try script("stream", body: """
    printf '%s\\n' '\(retained)' '\(live)' '\(runtimeLine(sequence: 9))' '\(live)' '\(runtimeLine(revision: 10, sequence: 12))'
    exec /bin/sleep 60
    """)
    let session = RuntimeStateSession(retryDelay: 0.02, maximumRetryDelay: 0.04)
    defer { session.shutdown() }
    var events: [RuntimeStateEvent] = []
    var onMain = true
    session.onEvent = { events.append($0); onMain = onMain && Thread.isMainThread }
    session.start(executable: executable)
    try waitUntil("The runtime stream delivers retained and live frames") { events.count >= 3 }
    try expect(events.map(\.seq) == [10, 11, 12] && onMain, "Sequence order and main-thread delivery reject duplicate or older events")
    try expect(launches().count == 1 && launches()[0].1.hasSuffix("remote events runtime.state"), "One direct runtime child supplies state")
    for _ in 0..<5 { session.start(executable: executable) }
    runtimePump(1.2)
    try expect(launches().count == 1 && kill(launches()[0].0, 0) == 0, "A quiet paused stream has no stall timeout or duplicate child")
    let first = launches()[0].0
    events = []
    session.reconnect()
    try waitUntil("The stream restarts after EOF or reconnect") { events.count == 3 && launches().count == 2 }
    try expect(kill(first, 0) != 0, "A restarted stream waits for its old child to exit")
    let second = launches().last!.0
    session.shutdown()
    try expect(kill(second, 0) != 0, "Shutdown reaps the runtime child")
    let count = launches().count
    runtimePump(0.1)
    try expect(launches().count == count, "Shutdown cancels stream retries")

    let attempts = directory.appendingPathComponent("attempts")
    let failing = try script("recovering-stream", body: """
    n=$(cat '\(attempts.path)' 2>/dev/null || echo 0)
    n=$((n+1))
    echo "$n" > '\(attempts.path)'
    if [ "$n" -lt 6 ]; then exit 1; fi
    printf '%s\\n' '\(retained)'
    exec /bin/sleep 60
    """)
    var disconnected = 0
    events = []
    session.onEvent = { events.append($0) }
    session.onDisconnect = { disconnected += 1 }
    session.start(executable: failing)
    try waitUntil("The runtime stream recovers after more than three consecutive losses") { events.count == 1 }
    try expect(launches().count == count + 6 && disconnected >= 5, "Bounded exponential delay never permanently abandons the stream")
    session.shutdown()

    let resistant = try script("resistant-stream", body: "trap '' TERM\nprintf '%s\\n' '\(retained)'\nexec /bin/sleep 60\n")
    var disposable: RuntimeStateSession? = RuntimeStateSession(retryDelay: 0.02, maximumRetryDelay: 0.04)
    let released = { [weak disposable] in disposable == nil }
    var delivered = false
    disposable?.onEvent = { _ in delivered = true }
    disposable?.start(executable: resistant)
    try waitUntil("A resistant runtime stream starts") { delivered }
    let old = launches().last!.0
    let beforeReplacement = launches().count
    disposable?.start(executable: executable)
    runtimePump(0.1)
    try expect(kill(old, 0) == 0 && launches().count == beforeReplacement, "Replacement cannot overlap a child that ignores SIGTERM")
    delivered = false
    try waitUntil("Generation replacement starts after forced cleanup") { delivered && launches().count == beforeReplacement + 1 }
    try expect(kill(old, 0) != 0, "Generation replacement reaps its old child")
    let final = launches().last!.0
    disposable = nil
    try expect(released() && kill(final, 0) != 0, "Deinitialization releases callbacks and reaps the child")
    try expect(launches().allSatisfy { kill($0.0, 0) != 0 }, "Every runtime fixture child exits")
    print("PASS: runtime envelopes, omitted retained, split/batched/oversized input, quiet streams, ordering, repeated reconnect, generations, cleanup")
}
