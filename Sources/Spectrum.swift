import Foundation
import Darwin

struct SpectrumFrame: Decodable {
    let bands: [Double]
    private enum CodingKeys: String, CodingKey { case ok, bands }

    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        guard try values.decode(Bool.self, forKey: .ok) else {
            throw DecodingError.dataCorruptedError(forKey: .ok, in: values, debugDescription: "Unsuccessful spectrum frame")
        }
        var input = try values.nestedUnkeyedContainer(forKey: .bands)
        var bands: [Double] = []
        while !input.isAtEnd, bands.count < 10 {
            let value = try input.decode(Double.self)
            guard value.isFinite else {
                throw DecodingError.dataCorruptedError(in: input, debugDescription: "Nonfinite spectrum band")
            }
            bands.append(min(1, max(0, value)))
        }
        guard input.isAtEnd, bands.count == 10 else {
            throw DecodingError.dataCorruptedError(in: input, debugDescription: "Expected ten spectrum bands")
        }
        self.bands = bands
    }
}

struct SpectrumParser {
    private var line = Data()
    private var discarding = false
    static let lineLimit = 65_536

    mutating func append(_ data: Data) -> [SpectrumFrame] {
        var frames: [SpectrumFrame] = []
        for byte in data {
            if byte == 10 {
                if !discarding, let frame = try? JSONDecoder().decode(SpectrumFrame.self, from: line) { frames.append(frame) }
                line.removeAll(keepingCapacity: true)
                discarding = false
            } else if !discarding {
                if line.count == Self.lineLimit {
                    line.removeAll(keepingCapacity: true)
                    discarding = true
                } else { line.append(byte) }
            }
        }
        return frames
    }
}

// Main-thread ownership keeps nonblocking reads and pipe cancellation serialized.
final class SpectrumSession {
    var onFrame: ([Double]) -> Void = { _ in }
    private var desiredExecutable: URL?
    private var child: Child?
    private var generation = 0
    private var retries = 0
    private var retry: DispatchWorkItem?
    private var freshness: Timer?
    private var lastFrameAt = 0.0

    private final class Child {
        let process: Process
        let source: DispatchSourceRead
        let generation: Int
        var parser = SpectrumParser()
        var stopping = false
        var retry = false

        init(process: Process, source: DispatchSourceRead, generation: Int) {
            self.process = process
            self.source = source
            self.generation = generation
        }
    }

    func update(visible: Bool, connected: Bool, playing: Bool, reduceMotion: Bool, executable: URL?) {
        let desired = visible && connected && playing && !reduceMotion ? executable : nil
        guard desired != desiredExecutable else { return }
        desiredExecutable = desired
        generation += 1
        retries = 0
        retry?.cancel()
        retry = nil
        clear()
        if child != nil { stopChild(retry: false) }
        else { start() }
    }

    private func start() {
        guard child == nil, let executable = desiredExecutable else { return }
        generation += 1
        let process = Process()
        process.executableURL = executable
        process.arguments = ["visstream", "--fps", "20"]
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
            scheduleRetry()
            return
        }
        let source = DispatchSource.makeReadSource(fileDescriptor: descriptor, queue: .main)
        let child = Child(process: process, source: source, generation: generation)
        source.setEventHandler { [weak self, weak child] in
            guard let self, let child, self.child === child, child.generation == self.generation, !child.stopping else { return }
            var buffer = [UInt8](repeating: 0, count: 16_384)
            var latest: SpectrumFrame?
            for _ in 0..<4 {
                let count = Darwin.read(descriptor, &buffer, buffer.count)
                if count > 0 {
                    if let frame = child.parser.append(Data(buffer.prefix(count))).last { latest = frame }
                } else {
                    if count == 0 || (errno != EAGAIN && errno != EINTR) { self.stopChild(retry: true) }
                    break
                }
            }
            if let latest, !child.stopping {
                self.lastFrameAt = ProcessInfo.processInfo.systemUptime
                self.onFrame(latest.bands)
            }
        }
        source.setCancelHandler { try? handle.close() }
        process.terminationHandler = { [weak self, weak process] _ in
            DispatchQueue.main.async {
                guard let self, let process, let child = self.child, child.process === process else { return }
                let retry = child.retry || !child.stopping
                child.source.cancel()
                self.child = nil
                self.clear()
                if retry { self.scheduleRetry() }
                else { self.start() }
            }
        }
        self.child = child
        source.resume()
        do {
            try process.run()
            try? pipe.fileHandleForWriting.close()
            lastFrameAt = ProcessInfo.processInfo.systemUptime
            freshness = Timer.scheduledTimer(withTimeInterval: 0.25, repeats: true) { [weak self] _ in
                guard let self, ProcessInfo.processInfo.systemUptime - self.lastFrameAt >= 1 else { return }
                self.stopChild(retry: true)
            }
        } catch {
            source.cancel()
            try? pipe.fileHandleForWriting.close()
            self.child = nil
            scheduleRetry()
        }
    }

    private func clear() {
        freshness?.invalidate()
        freshness = nil
        onFrame([])
    }

    private func stopChild(retry: Bool) {
        clear()
        guard let child else { return }
        child.retry = retry
        guard !child.stopping else { return }
        child.stopping = true
        child.source.cancel()
        let process = child.process
        if process.isRunning { process.terminate() }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
            if process.isRunning { kill(process.processIdentifier, SIGKILL) }
        }
    }

    private func scheduleRetry() {
        guard desiredExecutable != nil, retries < 3 else { return }
        let delay = Double(1 << retries)
        retries += 1
        let generation = generation
        let retry = DispatchWorkItem { [weak self] in
            guard let self, self.generation == generation else { return }
            self.retry = nil
            self.start()
        }
        self.retry = retry
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: retry)
    }

    func shutdown() {
        desiredExecutable = nil
        generation += 1
        retry?.cancel()
        retry = nil
        onFrame = { _ in }
        clear()
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
