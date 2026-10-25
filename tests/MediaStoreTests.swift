import Foundation
import Darwin

private final class FakeRuntimePlayer {
    let directory: URL
    let executable: URL

    init() throws {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent("cliampbar-media-store-" + UUID().uuidString)
        executable = directory.appendingPathComponent("cliamp")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let script = #"""
        #!/usr/bin/python3
        import json, os, sys, time
        from pathlib import Path
        root = Path(__file__).parent
        args = sys.argv[1:]
        def read(name, default=None):
            try:
                return json.loads((root / name).read_text())
            except FileNotFoundError:
                return default
        def log(kind):
            with (root / 'calls').open('a') as f:
                f.write(json.dumps({'pid':os.getpid(), 'args':args, 'kind':kind}) + '\n')
        def reply(result=None, snapshot=None):
            print(json.dumps({'ok':True, 'job':{'state':'succeeded', 'result':result or {}, 'snapshot':snapshot}}), flush=True)
        log('start')
        if args == ['remote', 'capabilities']:
            print(json.dumps({'ok':True, 'result':[{'name':v} for v in ['play','pause','toggle','next','prev','seek.absolute','queue.list','provider.list','provider.playlists']]}))
        elif args == ['remote', 'state']:
            snapshot = read('state.json')
            delay = read('state-delay.json', 0)
            log('captured')
            time.sleep(delay)
            print(json.dumps({'ok':True, 'snapshot':snapshot}))
        elif args == ['remote', 'events', 'runtime.state']:
            snapshot = read('state.json')
            snapshot['position'] = 1
            print(json.dumps({'event':'runtime.state','seq':1,'time':1792930250,'retained':True,'data':snapshot}), flush=True)
            with (root / 'events').open() as events:
                while True:
                    line = events.readline()
                    if line:
                        sys.stdout.write(line)
                        sys.stdout.flush()
                    else:
                        time.sleep(0.01)
        elif args[:2] == ['remote', 'call']:
            operation = args[2]
            snapshot = read('state.json')
            if operation == 'queue.list':
                result = read('queue.json')
                delay = read('queue-delay.json', 0)
            elif operation == 'provider.list':
                result = {'providers':[{'key':'local','name':'Local'}]}
                delay = 0
            elif operation == 'provider.playlists':
                result = read('playlists.json')
                delay = read('library-delay.json', 0)
            else:
                snapshot = read('command.json', snapshot)
                result = {}
                delay = read('command-delay.json', 0.03)
            log('captured')
            time.sleep(delay)
            reply(result, snapshot)
        else:
            sys.exit(2)
        """#
        try script.write(to: executable, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: executable.path)
        try Data().write(to: directory.appendingPathComponent("events"))
        try state(revision: 10, position: 80)
        try write("queue.json", ["tracks": [["title": "Initial queue", "index": 0]], "total": 1])
        try write("playlists.json", ["playlists": [["id": "old", "name": "Old playlist"]], "total": 1])
    }

    func write(_ name: String, _ value: Any) throws {
        try JSONSerialization.data(withJSONObject: value, options: [.fragmentsAllowed, .sortedKeys])
            .write(to: directory.appendingPathComponent(name), options: .atomic)
    }

    func snapshot(revision: Int, position: Double, playlist: Int = 1, state: String = "playing") -> [String: Any] {
        ["revision": revision, "playlist_revision": playlist, "state": state, "position": position, "speed": 1.5,
         "track": ["title": "Song \(revision)", "duration": 120], "duration": 120, "seekable": true]
    }

    func state(revision: Int, position: Double, playlist: Int = 1, state: String = "playing") throws {
        try write("state.json", snapshot(revision: revision, position: position, playlist: playlist, state: state))
    }

    func event(revision: Int, position: Double, playlist: Int = 1, sequence: Int, retained: Bool = false) throws {
        var event: [String: Any] = ["event": "runtime.state", "seq": sequence, "time": 1792930250,
                                    "data": snapshot(revision: revision, position: position, playlist: playlist)]
        if retained { event["retained"] = true }
        let output = try FileHandle(forWritingTo: directory.appendingPathComponent("events"))
        defer { try? output.close() }
        try output.seekToEnd()
        try output.write(contentsOf: JSONSerialization.data(withJSONObject: event) + Data([10]))
    }

    func calls(_ arguments: [String], kind: String = "start") -> [[String: Any]] {
        let text = (try? String(contentsOf: directory.appendingPathComponent("calls"), encoding: .utf8)) ?? ""
        return text.split(separator: "\n").compactMap { try? JSONSerialization.jsonObject(with: Data($0.utf8)) as? [String: Any] }
            .filter { $0["args"] as? [String] == arguments && $0["kind"] as? String == kind }
    }

    func commandCalls() -> [String] {
        let text = (try? String(contentsOf: directory.appendingPathComponent("calls"), encoding: .utf8)) ?? ""
        return text.split(separator: "\n").compactMap {
            guard let call = try? JSONSerialization.jsonObject(with: Data($0.utf8)) as? [String: Any],
                  call["kind"] as? String == "start", let args = call["args"] as? [String],
                  args.count >= 3, args.prefix(2) == ["remote", "call"],
                  ["play", "pause", "toggle", "next", "prev"].contains(args[2]) else { return nil }
            return args[2]
        }
    }

    deinit { try? FileManager.default.removeItem(at: directory) }
}

func mediaStoreTests() throws {
    let fixture = try FakeRuntimePlayer()
    let previous = ProcessInfo.processInfo.environment["CLIAMP_BINARY"]
    setenv("CLIAMP_BINARY", fixture.executable.path, 1)
    defer {
        if let previous { setenv("CLIAMP_BINARY", previous, 1) } else { unsetenv("CLIAMP_BINARY") }
    }
    let store = PlayerStore(runtime: RuntimeStateSession(retryDelay: 0.02, maximumRetryDelay: 0.04))
    defer { store.shutdown() }
    var regressedPosition = false
    store.onChange = {
        if store.snapshot?.revision == 10, (store.snapshot?.position ?? 80) < 80 { regressedPosition = true }
    }
    store.connect()
    try waitUntil("The store recovers a fresh position after the initial retained event") {
        if case .ready = store.connection { return store.queue.count == 1 && !store.libraryBusy }
        return false
    }
    try expect(store.snapshot?.position == 80 && !regressedPosition, "An old retained position cannot replace a fresh equal-revision connect snapshot")
    try expect(fixture.calls(["remote", "state"]).count == 2, "Connect and retained recovery use two finite state reads")
    let queueCalls = fixture.calls(["remote", "call", "queue.list", "--params", "{\"limit\":100,\"offset\":0}", "--wait"]).count
    try fixture.state(revision: 11, position: 42, playlist: 2)
    try fixture.event(revision: 11, position: 42, playlist: 2, sequence: 2)
    try waitUntil("A hidden panel receives a real-format live state envelope") { store.snapshot?.revision == 11 }
    RunLoop.current.run(until: Date().addingTimeInterval(1.2))
    try expect(fixture.calls(["remote", "state"]).count == 2 && fixture.calls(["remote", "events", "runtime.state"]).count == 1,
               "Hidden playback uses one quiet stream without hidden state polling")
    try expect(fixture.calls(["remote", "call", "queue.list", "--params", "{\"limit\":100,\"offset\":0}", "--wait"]).count == queueCalls,
               "Hidden stream events cannot fetch queue pages")

    try fixture.write("command.json", fixture.snapshot(revision: 9, position: 1))
    let commands: [PlayerCommand] = [.play, .pause, .toggle, .next, .previous, .play, .pause, .toggle,
                                     .next, .previous, .play, .pause, .toggle, .next, .previous, .pause]
    for command in commands { try expect(store.perform(command, queueIfBusy: true), "Each deliberate action enters the bounded serial worker") }
    try expect(!store.perform(.next, queueIfBusy: true) && !store.perform(.toggle), "A full command queue and a busy GUI reject honestly")
    try waitUntil("The serial worker attempts every accepted media action") { !store.busy }
    try expect(fixture.commandCalls() == commands.map(\.operation), "Accepted commands dispatch exactly once, in order, without toggling twice")
    try expect(store.snapshot?.revision == 11, "Old command completions cannot replace stream-authoritative state")
    RunLoop.current.run(until: Date().addingTimeInterval(0.2))

    try fixture.write("state-delay.json", 0.35)
    try fixture.state(revision: 12, position: 15, playlist: 2)
    let reads = fixture.calls(["remote", "state"], kind: "captured").count
    store.refresh()
    try waitUntil("A delayed state read captures an old snapshot") { fixture.calls(["remote", "state"], kind: "captured").count > reads }
    try fixture.state(revision: 13, position: 60, playlist: 2)
    try fixture.event(revision: 13, position: 60, playlist: 2, sequence: 3)
    try waitUntil("A newer live event wins while a read is in flight") { store.snapshot?.revision == 13 }
    RunLoop.current.run(until: Date().addingTimeInterval(0.45))
    try expect(store.snapshot?.revision == 13 && store.snapshot?.position == 60, "A late state read cannot overwrite a newer stream snapshot")
    try fixture.event(revision: 13, position: 1, playlist: 2, sequence: 4, retained: true)
    RunLoop.current.run(until: Date().addingTimeInterval(0.1))
    try expect(store.snapshot?.position == 60, "Equal-revision retained frames cannot rewind a fresh position")
    try fixture.write("state-delay.json", 0)
    try fixture.write("command.json", fixture.snapshot(revision: 14, position: 2, playlist: 2, state: "paused"))
    try fixture.write("command-delay.json", 0.35)
    try expect(store.perform(.toggle, queueIfBusy: true), "A command enters the worker before a newer event")
    try fixture.state(revision: 15, position: 70, playlist: 2)
    try fixture.event(revision: 15, position: 70, playlist: 2, sequence: 5)
    try waitUntil("The stream reaches the newest revision") { store.snapshot?.revision == 15 }
    try waitUntil("The old command result finishes") { !store.busy }
    try expect(store.snapshot?.revision == 15, "A late command result cannot overwrite a newer stream revision")
    RunLoop.current.run(until: Date().addingTimeInterval(0.2))

    let seekReads = fixture.calls(["remote", "state"], kind: "captured").count
    try fixture.write("state-delay.json", 0.35)
    store.refresh()
    try waitUntil("A read starts before a position-only command") {
        fixture.calls(["remote", "state"], kind: "captured").count > seekReads
    }
    try fixture.state(revision: 15, position: 88, playlist: 2)
    try expect(store.perform(.seek(88), queueIfBusy: true), "A position-only command is admitted behind an old read")
    try waitUntil("A command-invalidated read schedules a fresh position read") {
        store.snapshot?.position == 88 && !store.busy
    }
    try fixture.write("state-delay.json", 0)

    store.setVisible(true)
    try waitUntil("Opening the panel refreshes queue rows") { store.queueRevision == 2 && !store.queueLoading }
    store.setVisible(false)
    try fixture.write("queue-delay.json", 0.6)
    try fixture.write("library-delay.json", 0.6)
    let queueArgs = ["remote", "call", "queue.list", "--params", "{\"limit\":100,\"offset\":0}", "--wait"]
    let libraryArgs = ["remote", "call", "provider.playlists", "--params", "{\"limit\":100,\"offset\":0,\"provider\":\"local\"}", "--wait"]
    let beforeQueue = fixture.calls(queueArgs, kind: "captured").count
    let beforeLibrary = fixture.calls(libraryArgs, kind: "captured").count
    store.refreshQueue()
    store.loadPlaylists(provider: "local")
    try waitUntil("Old queue and library requests capture their responses") {
        fixture.calls(queueArgs, kind: "captured").count > beforeQueue && fixture.calls(libraryArgs, kind: "captured").count > beforeLibrary
    }
    var sawClearedQueue = false
    store.onChange = {
        if case .unavailable = store.connection {
            sawClearedQueue = store.snapshot == nil && store.queue.isEmpty && store.queueRevision == nil
        }
    }
    try fixture.state(revision: 1, position: 90, playlist: 2, state: "paused")
    try fixture.write("queue.json", ["tracks": [["title": "Replacement daemon queue", "index": 0]], "total": 1])
    try fixture.write("playlists.json", ["playlists": [["id": "new", "name": "Replacement playlist"]], "total": 1])
    try Data().write(to: fixture.directory.appendingPathComponent("events"))
    let pid = (fixture.calls(["remote", "events", "runtime.state"]).last!["pid"] as! NSNumber).int32Value
    kill(pid, SIGTERM)
    try waitUntil("A replacement daemon can reset snapshot revisions") {
        if case .ready = store.connection { return store.snapshot?.revision == 1 }
        return false
    }
    try expect(sawClearedQueue && store.queue.isEmpty && store.queueRevision == nil,
               "Stream loss invalidates rows even when the replacement reuses the playlist revision")
    try expect(store.snapshot?.position == 90, "Stream reconnect establishes a fresh position instead of its retained position")
    try fixture.write("queue-delay.json", 1.0)
    try fixture.write("library-delay.json", 1.0)
    store.refreshQueue()
    store.loadPlaylists(provider: "local")
    RunLoop.current.run(until: Date().addingTimeInterval(0.65))
    try expect(store.queueLoading && store.libraryBusy && store.queue.isEmpty && store.playlists.isEmpty,
               "Old-epoch replies cannot populate data or clear new loading flags")
    try waitUntil("New-epoch queue and library responses arrive") { !store.queueLoading && !store.libraryBusy }
    try expect(store.queue.first?.title == "Replacement daemon queue" && store.playlists.first?.id == "new",
               "Reused revisions display only the replacement daemon data")
    store.shutdown()
    try expect(kill(pid, 0) != 0, "The old event child exits during replacement")
    print("PASS: hidden store state, retained position barrier, bounded ordered commands, stale reads/results, daemon revision reset, queue/library epochs")
}
