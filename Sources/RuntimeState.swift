import Foundation
import Darwin

struct RuntimeStateEvent: Decodable {
    let event: String
    let seq: Int
    let time: Double
    let retained: Bool
    let data: PlayerSnapshot

    private enum CodingKeys: String, CodingKey { case event, seq, time, retained, data }

    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        event = try values.decode(String.self, forKey: .event)
        seq = try values.decode(Int.self, forKey: .seq)
        time = try values.decode(Double.self, forKey: .time)
        retained = try values.decodeIfPresent(Bool.self, forKey: .retained) ?? false
        data = try values.decode(PlayerSnapshot.self, forKey: .data)
    }
}

struct RuntimeStateParser {
    static let lineLimit = 65_536
    private var line = Data()
    private var discarding = false

    mutating func append(_ data: Data) -> [RuntimeStateEvent] {
        var events: [RuntimeStateEvent] = []
        for byte in data {
            if byte == 10 {
                if !discarding, let event = try? JSONDecoder().decode(RuntimeStateEvent.self, from: line),
                   event.event == "runtime.state" { events.append(event) }
                line.removeAll(keepingCapacity: true)
                discarding = false
            } else if !discarding {
                if line.count == Self.lineLimit {
                    line.removeAll(keepingCapacity: true)
                    discarding = true
                } else { line.append(byte) }
            }
        }
        return events
    }
}

// Main-thread ownership serializes nonblocking reads, cancellation, and child replacement.
final class RuntimeStateSession {
    var onEvent: (RuntimeStateEvent) -> Void = { _ in }
    var onDisconnect: () -> Void = {}
    private var desiredExecutable: URL?
    private var child: Child?
    private var generation = 0
    private var retry: DispatchWorkItem?
    private var retryDelay: TimeInterval
    private let initialRetryDelay: TimeInterval
    private let maximumRetryDelay: TimeInterval

    private final class Child {
        let process: Process
        let source: DispatchSourceRead
        let generation: Int
        var parser = RuntimeStateParser()
        var sequence: Int?
        var stopping = false
        var retry = false

        init(process: Process, source: DispatchSourceRead, generation: Int) {
            self.process = process
            self.source = source
            self.generation = generation
        }
    }

    init(retryDelay: TimeInterval = 1, maximumRetryDelay: TimeInterval = 8) {
        self.initialRetryDelay = retryDelay
        self.retryDelay = retryDelay
        self.maximumRetryDelay = maximumRetryDelay
    }

    func start(executable: URL) {
        guard desiredExecutable != executable else { return }
        desiredExecutable = executable
        generation += 1
        retryDelay = initialRetryDelay
        retry?.cancel()
        retry = nil
        if child != nil { stopChild(retry: false) }
        else { launch() }
    }

    func reconnect() {
        guard desiredExecutable != nil else { return }
        if child != nil { stopChild(retry: true) }
    }

    private func launch() {
        guard child == nil, let executable = desiredExecutable else { return }
        generation += 1
        let process = Process()
        process.executableURL = executable
        process.arguments = ["remote", "events", "runtime.state"]
        process.environment = CommandRunner.cliampEnvironment()
        process.standardInput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        let pipe = Pipe()
        process.standardOutput = pipe
        let handle = pipe.fileHandleForReading
        let descriptor = handle.fileDescriptor
        guard fcntl(descriptor, F_SETFL, O_NONBLOCK) != -1 else {
            try? handle.close()
            try? pipe.fileHandleForWriting.close()
            disconnected()
            return
        }
        let source = DispatchSource.makeReadSource(fileDescriptor: descriptor, queue: .main)
        let child = Child(process: process, source: source, generation: generation)
        source.setEventHandler { [weak self, weak child] in
            guard let self, let child, self.child === child, child.generation == self.generation, !child.stopping else { return }
            var buffer = [UInt8](repeating: 0, count: 16_384)
            for _ in 0..<4 {
                let count = Darwin.read(descriptor, &buffer, buffer.count)
                if count > 0 {
                    for event in child.parser.append(Data(buffer.prefix(count))) {
                        guard !child.stopping, child.generation == self.generation else { return }
                        if let sequence = child.sequence, event.seq <= sequence { continue }
                        child.sequence = event.seq
                        self.retryDelay = self.initialRetryDelay
                        self.onEvent(event)
                    }
                } else {
                    if count == 0 || (errno != EAGAIN && errno != EINTR) { self.stopChild(retry: true) }
                    break
                }
            }
        }
        source.setCancelHandler { try? handle.close() }
        process.terminationHandler = { [weak self, weak process] _ in
            DispatchQueue.main.async {
                guard let self, let process, let child = self.child, child.process === process else { return }
                let retry = child.retry || !child.stopping
                child.source.cancel()
                self.child = nil
                if retry { self.disconnected() }
                else { self.launch() }
            }
        }
        self.child = child
        source.resume()
        do {
            try process.run()
            try? pipe.fileHandleForWriting.close()
        } catch {
            source.cancel()
            try? pipe.fileHandleForWriting.close()
            self.child = nil
            disconnected()
        }
    }

    private func stopChild(retry: Bool) {
        guard let child else { return }
        child.retry = retry
        guard !child.stopping else { return }
        child.stopping = true
        child.source.cancel()
        if retry { onDisconnect() }
        let process = child.process
        if process.isRunning { process.terminate() }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
            if process.isRunning { kill(process.processIdentifier, SIGKILL) }
        }
    }

    private func disconnected() {
        guard desiredExecutable != nil else { return }
        onDisconnect()
        let generation = generation
        let retry = DispatchWorkItem { [weak self] in
            guard let self, self.generation == generation else { return }
            self.retry = nil
            self.launch()
        }
        self.retry = retry
        DispatchQueue.main.asyncAfter(deadline: .now() + retryDelay, execute: retry)
        retryDelay = min(maximumRetryDelay, retryDelay * 2)
    }

    func shutdown() {
        desiredExecutable = nil
        generation += 1
        retry?.cancel()
        retry = nil
        onEvent = { _ in }
        onDisconnect = {}
        if let child {
            child.source.cancel()
            if child.process.isRunning {
                kill(child.process.processIdentifier, SIGKILL)
                child.process.waitUntilExit()
            }
            self.child = nil
        }
    }

    deinit { shutdown() }
}
