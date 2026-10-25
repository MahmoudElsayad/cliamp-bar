import Foundation
import Darwin

final class FakeRuntimePlayer {
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
            print(json.dumps({'ok':True, 'result':[{'name':v} for v in read('capabilities.json', ['play','pause','toggle','next','prev','seek.absolute','queue.list','provider.list','provider.playlists','url.load'])]}))
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
            response = read('url-reply.json') if operation == 'url.load' else None
            failure = read('url-error.json') if operation == 'url.load' else None
            log('captured')
            time.sleep(delay)
            if failure:
                print(failure, file=sys.stderr)
                sys.exit(1)
            if response is not None:
                print(json.dumps(response), flush=True)
            else:
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

    func urlCalls(_ url: String, kind: String = "start") -> [[String: Any]] {
        let text = (try? String(contentsOf: directory.appendingPathComponent("calls"), encoding: .utf8)) ?? ""
        return text.split(separator: "\n").compactMap { try? JSONSerialization.jsonObject(with: Data($0.utf8)) as? [String: Any] }
            .filter {
                guard $0["kind"] as? String == kind, let args = $0["args"] as? [String], args.count == 6,
                      args.prefix(4) == ["remote", "call", "url.load", "--params"],
                      let parameters = try? JSONSerialization.jsonObject(with: Data(args[4].utf8)) as? [String: Any] else { return false }
                return parameters["path"] as? String == url && parameters["play"] as? Bool == true
            }
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
