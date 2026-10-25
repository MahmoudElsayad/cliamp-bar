import Foundation
import Darwin

struct Track: Decodable {
    var title: String?
    var artist: String?
    var album: String?
    var path: String?
    var index: Int?
    var duration: Double?
    var stream: Bool?
    var realtime: Bool?

    var displayTitle: String {
        if let title, !title.isEmpty { return title }
        return path.map { URL(fileURLWithPath: $0).lastPathComponent } ?? "Nothing playing"
    }
}

struct PlayerSnapshot: Decodable {
    let revision: Int
    let playlist_revision: Int
    let state: String
    var track: Track?
    var logical_track: Track?
    var position: Double?
    var duration: Double?
    var seekable: Bool?
    var volume: Double?
    var index: Int?
    var total: Int?
    var shuffle: Bool?
    var `repeat`: String?
    var stream_error: String?

    var currentTrack: Track? { track ?? logical_track }
    var isPlaying: Bool { state == "playing" }
}

struct LibraryProvider: Decodable {
    let key: String
    let name: String
}

struct SavedPlaylist: Decodable {
    let id: String
    let name: String
    var track_count: Int?
}

struct TrackPage: Decodable {
    let tracks: [Track]?
    let total: Int?
}

struct PlaylistPage: Decodable {
    let playlists: [SavedPlaylist]?
    let total: Int?
}

struct ProviderPage: Decodable {
    let providers: [LibraryProvider]
}

struct Capability: Decodable { let name: String }

struct RemoteReply<Result: Decodable>: Decodable {
    let ok: Bool
    var snapshot: PlayerSnapshot?
    var result: Result?
    var job: RemoteJob<Result>?
}

struct RemoteJob<Result: Decodable>: Decodable {
    let state: String
    var result: Result?
    var snapshot: PlayerSnapshot?
}

struct EmptyResult: Decodable {}

enum PlayerCommand {
    case toggle, previous, next, shuffle, repeatMode
    case seek(Double), volume(Double)
    case playQueue(index: Int, revision: Int)
    case openURL(String)
    case appendFile(String)
    case load(provider: String, playlist: String)

    var operation: String {
        switch self {
        case .toggle: return "toggle"
        case .previous: return "prev"
        case .next: return "next"
        case .shuffle: return "shuffle"
        case .repeatMode: return "repeat"
        case .seek: return "seek.absolute"
        case .volume: return "volume"
        case .playQueue: return "queue.play"
        case .openURL: return "url.load"
        case .appendFile: return "queue"
        case .load: return "provider.load"
        }
    }

    var parameters: [String: Any] {
        switch self {
        case .seek(let value), .volume(let value): return ["value": value]
        case .playQueue(let index, let revision): return ["index": index, "if_revision": revision]
        case .openURL(let path): return ["path": path, "play": true]
        case .appendFile(let path): return ["path": path]
        case .load(let provider, let playlist): return ["provider": provider, "playlist": playlist]
        default: return [:]
        }
    }
}

enum PlayerConnection {
    case connecting
    case ready
    case unavailable(String)
}

struct CliampError: LocalizedError {
    let message: String
    var errorDescription: String? { message }
}

enum CliampExecutable {
    static func find(environment: [String: String] = ProcessInfo.processInfo.environment) -> URL? {
        let candidates = [environment["CLIAMP_BINARY"], "/opt/homebrew/bin/cliamp", "/usr/local/bin/cliamp",
                          NSHomeDirectory() + "/.local/bin/cliamp"]
        let paths = (environment["PATH"] ?? "").split(separator: ":").map { String($0) + "/cliamp" }
        return (candidates.compactMap { $0 } + paths)
            .first { FileManager.default.isExecutableFile(atPath: $0) }
            .map { URL(fileURLWithPath: $0) }
    }
}

private final class CapturedOutput: @unchecked Sendable {
    private let lock = NSLock()
    private var bytes = Data()
    func append(_ data: Data) {
        lock.lock()
        if bytes.count < 2_097_152 { bytes.append(data.prefix(2_097_152 - bytes.count)) }
        lock.unlock()
    }
    var data: Data {
        lock.lock()
        defer { lock.unlock() }
        return bytes
    }
}

enum CommandRunner {
    // Call from a worker queue. Each pipe drains independently, including on failure.
    static func run(_ executable: URL, arguments: [String], timeout: TimeInterval = 30) throws -> Data {
        let process = Process()
        process.executableURL = executable
        process.arguments = arguments
        process.environment = cliampEnvironment()
        let stdout = Pipe(), stderr = Pipe()
        process.standardOutput = stdout
        process.standardError = stderr
        process.standardInput = FileHandle.nullDevice
        try process.run()
        let output = CapturedOutput(), errors = CapturedOutput()
        let drains = DispatchGroup()
        for (pipe, sink) in [(stdout, output), (stderr, errors)] {
            drains.enter()
            DispatchQueue.global(qos: .utility).async {
                let descriptor = pipe.fileHandleForReading.fileDescriptor
                _ = fcntl(descriptor, F_SETFL, O_NONBLOCK)
                var buffer = [UInt8](repeating: 0, count: 16_384)
                var exitedAt: Date?
                while true {
                    if !process.isRunning {
                        if exitedAt == nil { exitedAt = Date() }
                        if Date().timeIntervalSince(exitedAt!) > 0.5 { break }
                    }
                    let count = Darwin.read(descriptor, &buffer, buffer.count)
                    if count > 0 { sink.append(Data(buffer.prefix(count))); continue }
                    if count == 0 { break }
                    if errno != EAGAIN && errno != EINTR { break }
                    // Observe exit before reading, so bytes written just before exit get one final drain.
                    if exitedAt != nil { break }
                    var descriptorState = pollfd(fd: descriptor, events: Int16(POLLIN), revents: 0)
                    _ = poll(&descriptorState, 1, 100)
                }
                try? pipe.fileHandleForReading.close()
                drains.leave()
            }
        }
        let deadline = DispatchWorkItem {
            if process.isRunning { process.terminate() }
            DispatchQueue.global().asyncAfter(deadline: .now() + 1) {
                if process.isRunning { kill(process.processIdentifier, SIGKILL) }
            }
        }
        DispatchQueue.global().asyncAfter(deadline: .now() + timeout, execute: deadline)
        process.waitUntilExit()
        deadline.cancel()
        drains.wait()
        guard process.terminationStatus == 0 else {
            let detail = String(data: errors.data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines)
            throw CliampError(message: detail.flatMap { $0.isEmpty ? nil : $0 }
                ?? "Cliamp did not finish the command. Refresh the player before trying again.")
        }
        return output.data
    }

    static func cliampEnvironment() -> [String: String] {
        var environment = ProcessInfo.processInfo.environment
        let paths = ["/opt/homebrew/bin", "/usr/local/bin", NSHomeDirectory() + "/.local/bin", environment["PATH"] ?? "/usr/bin:/bin"]
        environment["PATH"] = paths.joined(separator: ":")
        return environment
    }
}

final class CliampClient {
    let executable: URL
    init(executable: URL) { self.executable = executable }

    func snapshot() throws -> PlayerSnapshot {
        let data = try CommandRunner.run(executable, arguments: ["remote", "state"], timeout: 5)
        let reply = try JSONDecoder().decode(RemoteReply<EmptyResult>.self, from: data)
        guard reply.ok, let snapshot = reply.snapshot else {
            throw CliampError(message: "Cliamp returned no player state. Install Cliamp 2.3.0 or later.")
        }
        return snapshot
    }

    func capabilities() throws -> Set<String> {
        let data = try CommandRunner.run(executable, arguments: ["remote", "capabilities"], timeout: 5)
        let reply = try JSONDecoder().decode(RemoteReply<[Capability]>.self, from: data)
        guard reply.ok, let values = reply.result else {
            throw CliampError(message: "Cliamp does not expose its controls. Install Cliamp 2.3.0 or later.")
        }
        return Set(values.map(\.name))
    }

    func call<Result: Decodable>(_ operation: String, parameters: [String: Any] = [:],
                                 as type: Result.Type = Result.self) throws -> RemoteReply<Result> {
        let data = try JSONSerialization.data(withJSONObject: parameters, options: [.sortedKeys])
        let json = String(decoding: data, as: UTF8.self)
        let response = try CommandRunner.run(executable, arguments: ["remote", "call", operation, "--params", json, "--wait"])
        let reply = try JSONDecoder().decode(RemoteReply<Result>.self, from: response)
        guard reply.ok, reply.job?.state == "succeeded" else {
            throw CliampError(message: "Cliamp did not complete \(operation). Refresh the player before trying again.")
        }
        return reply
    }

    func startDaemon() throws -> Process {
        let daemon = Process()
        daemon.executableURL = executable
        daemon.arguments = ["--daemon"]
        daemon.environment = CommandRunner.cliampEnvironment()
        daemon.standardInput = FileHandle.nullDevice
        let directory = FileManager.default.urls(for: .libraryDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Logs/CliampBar", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let path = directory.appendingPathComponent("daemon.log")
        if !FileManager.default.fileExists(atPath: path.path) { FileManager.default.createFile(atPath: path.path, contents: nil) }
        let log = try FileHandle(forWritingTo: path)
        try log.seekToEnd()
        daemon.standardOutput = log
        daemon.standardError = log
        try daemon.run()
        try? log.close()
        return daemon
    }
}
