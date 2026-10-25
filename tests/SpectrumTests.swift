import Foundation
import Darwin

private let spectrumLine = "{\"ok\":true,\"visualizer\":\"Bars\",\"bands\":[0.48,0.35,0.31,0.35,0.30,0.17,0.03,0,0,0]}"

private func pump(_ seconds: TimeInterval) {
    RunLoop.current.run(until: Date().addingTimeInterval(seconds))
}

private func processExists(_ pid: Int32) -> Bool { kill(pid, 0) == 0 }

func spectrumTests() throws {
    var parser = SpectrumParser()
    let frame = Data((spectrumLine + "\n").utf8)
    var frames: [SpectrumFrame] = []
    for byte in frame { frames += parser.append(Data([byte])) }
    try expect(frames.count == 1 && frames[0].bands[0] == 0.48, "Split input decodes the actual v2.3 schema")
    let clamped = spectrumLine.replacingOccurrences(of: "0.48,0.35", with: "-2,3")
    let batch = parser.append(Data((clamped + "\r\n" + spectrumLine + "\n").utf8))
    try expect(batch.count == 2 && batch[0].bands.prefix(2) == [0, 1], "Batched lines decode and bands clamp to zero through one")
    for malformed in ["{}", "not json", spectrumLine.replacingOccurrences(of: "true", with: "false"),
                      spectrumLine.replacingOccurrences(of: "0.48", with: "1e9999"),
                      spectrumLine.replacingOccurrences(of: "0.48", with: "\"NaN\""),
                      "{\"ok\":true,\"bands\":[0]}",
                      "{\"ok\":true,\"bands\":[" + Array(repeating: "0", count: 10_000).joined(separator: ",") + "]}"] {
        try expect(parser.append(Data((malformed + "\n").utf8)).isEmpty, "Malformed and oversized band arrays are ignored")
    }
    _ = parser.append(Data(repeating: 32, count: SpectrumParser.lineLimit))
    _ = parser.append(Data([32]))
    try expect(parser.append(frame).isEmpty, "An oversized line discards even a valid JSON suffix through its newline")
    try expect(parser.append(frame).count == 1, "The next line recovers after an oversized split line")

    let directory = FileManager.default.temporaryDirectory.appendingPathComponent("cliampbar-spectrum-" + UUID().uuidString)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    let log = directory.appendingPathComponent("children")
    let executable = directory.appendingPathComponent("fake-stream")
    let script = """
    #!/bin/sh
    printf '%s %s %s %s\\n' "$$" "$1" "$2" "$3" >> '\(log.path)'
    printf '%s\\n' '\(spectrumLine)'
    exec /bin/sleep 60
    """
    try script.write(to: executable, atomically: true, encoding: .utf8)
    try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: executable.path)
    func launches() -> [(Int32, String)] {
        let text = (try? String(contentsOf: log, encoding: .utf8)) ?? ""
        return text.split(separator: "\n").compactMap { line in
            guard let pid = Int32(line.split(separator: " ")[0]) else { return nil }
            return (pid, String(line))
        }
    }
    let session = SpectrumSession()
    defer { session.shutdown() }
    var received: [[Double]] = []
    var callbackOnMain = true
    session.onFrame = { received.append($0); callbackOnMain = callbackOnMain && Thread.isMainThread }
    func update(_ visible: Bool = true, _ connected: Bool = true, _ playing: Bool = true, _ reduce: Bool = false) {
        session.update(visible: visible, connected: connected, playing: playing, reduceMotion: reduce, executable: executable)
    }
    update(false); update(true, false); update(true, true, false); update(true, true, true, true)
    pump(0.1)
    try expect(launches().isEmpty, "Hidden, paused, disconnected, and Reduce Motion states cannot launch a child")
    update()
    try waitUntil("A fake stream reaches the direct main-thread callback") { received.last?.first == 0.48 }
    let first = launches()[0].0
    try expect(launches()[0].1.hasSuffix("visstream --fps 20") && callbackOnMain, "The stream uses direct CLI arguments and main-thread delivery")
    for _ in 0..<5 { update() }
    pump(0.1)
    try expect(launches().count == 1, "Repeated eligible updates retain exactly one process")
    update(true, true, false)
    let afterPause = received.count
    try waitUntil("Pause terminates the child") { !processExists(first) }
    pump(0.1)
    try expect(received.last?.isEmpty == true && !received.dropFirst(afterPause).contains { !$0.isEmpty }, "Pause clears bars and rejects stale frames")

    for stop in [0, 1, 2, 3] {
        let count = launches().count
        update()
        try waitUntil("Restart receives a new frame") { launches().count == count + 1 && received.last?.first == 0.48 }
        let pid = launches().last!.0
        switch stop {
        case 0: update(false)
        case 1: update(true, false)
        case 2: update(true, true, true, true)
        default: update(true, true, false)
        }
        try waitUntil("Each eligibility guard terminates its child") { !processExists(pid) }
        try expect(received.last?.isEmpty == true, "Each eligibility guard clears the strip")
    }
    update()
    try waitUntil("A stream starts before an immediate eligibility change") { received.last?.first == 0.48 }
    let old = launches().last!.0
    let count = launches().count
    update(false)
    update()
    try waitUntil("An immediate restart waits for the old process to exit") { launches().count == count + 1 && received.last?.first == 0.48 }
    try expect(!processExists(old), "A restart never overlaps the previous child")
    let fresh = launches().last!.0
    try waitUntil("A silent stream clears stale frames after one second") { received.last?.isEmpty == true }
    try waitUntil("A stale stream terminates") { !processExists(fresh) }
    try waitUntil("An eligible stale stream retries") { launches().count == count + 2 && received.last?.first == 0.48 }
    let final = launches().last!.0
    session.shutdown()
    try expect(!processExists(final), "Teardown leaves no running child")
    pump(1.1)
    try expect(launches().count == count + 2, "Teardown cancels pending retries")

    let resistant = directory.appendingPathComponent("resistant-stream")
    try script.replacingOccurrences(of: "#!/bin/sh", with: "#!/bin/sh\ntrap '' TERM").write(to: resistant, atomically: true, encoding: .utf8)
    try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: resistant.path)
    var disposable: SpectrumSession? = SpectrumSession()
    let wasReleased = { [weak disposable] in disposable == nil }
    var delivered = false
    disposable?.onFrame = { if !$0.isEmpty { delivered = true } }
    disposable?.update(visible: true, connected: true, playing: true, reduceMotion: false, executable: resistant)
    try waitUntil("A resistant stream starts") { delivered }
    let resistantPID = launches().last!.0
    let beforeRestart = launches().count
    disposable?.update(visible: false, connected: true, playing: true, reduceMotion: false, executable: resistant)
    disposable?.update(visible: true, connected: true, playing: true, reduceMotion: false, executable: resistant)
    delivered = false
    pump(0.1)
    try expect(processExists(resistantPID) && launches().count == beforeRestart, "Reopening cannot overlap a child that ignores SIGTERM")
    try waitUntil("A resistant stream restarts after its old child exits") { delivered && !processExists(resistantPID) }
    let releasedPID = launches().last!.0
    disposable = nil
    try expect(wasReleased() && !processExists(releasedPID), "Session release breaks callbacks and kills its child")

    let failing = directory.appendingPathComponent("failing-stream")
    try "#!/bin/sh\nprintf '%s\\n' \"$$\" >> '\(log.path)'\nexit 1\n".write(to: failing, atomically: true, encoding: .utf8)
    try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: failing.path)
    let beforeFailures = launches().count
    session.update(visible: true, connected: true, playing: true, reduceMotion: false, executable: failing)
    try waitUntil("An exited stream gets three bounded retries") { launches().count == beforeFailures + 4 }
    pump(1.2)
    try expect(launches().count == beforeFailures + 4, "Failure cannot create an unlimited retry loop")
    session.shutdown()
    try expect(launches().allSatisfy { !processExists($0.0) }, "Every fake stream exits without a leaked child")
    print("PASS: spectrum framing, limits, malformed input, clamping, eligibility, restart, stale frames, retries, teardown")
}

func realSpectrumTests(executable: URL) throws {
    let session = SpectrumSession()
    defer { session.shutdown() }
    var frames: [[Double]] = []
    session.onFrame = { if !$0.isEmpty { frames.append($0) } }
    session.update(visible: true, connected: true, playing: true, reduceMotion: false, executable: executable)
    try waitUntil("Real visstream produces ten bounded bands") { frames.count >= 3 }
    try expect(frames.allSatisfy { $0.count == 10 && $0.allSatisfy { $0.isFinite && (0...1).contains($0) } }, "Real frames use the supported spectrum schema")
    session.update(visible: false, connected: true, playing: true, reduceMotion: false, executable: executable)
    let count = frames.count
    pump(0.2)
    try expect(frames.count == count, "Hidden real streams stop delivering frames")
    session.update(visible: true, connected: true, playing: true, reduceMotion: false, executable: executable)
    try waitUntil("Real visstream restarts after hiding") { frames.count >= count + 3 }
    print("PASS: real v2.3 visstream frames and stop/restart in disposable configuration")
}
