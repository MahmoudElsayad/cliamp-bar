import Foundation
import Darwin

func realRuntimeStoreTests(client: CliampClient, file: URL, daemonPID: Int32) throws -> Process {
    let second = file.deletingLastPathComponent().appendingPathComponent("Hidden event track.wav")
    try silentWAV(at: second, seconds: 60)
    _ = try client.call("queue.clear", as: EmptyResult.self)
    for path in [file.path, second.path] { _ = try client.call("queue", parameters: ["path": path], as: EmptyResult.self) }
    _ = try client.call("play", as: EmptyResult.self)
    _ = try client.call("pause", as: EmptyResult.self)
    _ = try client.call("seek.absolute", parameters: ["value": 3], as: EmptyResult.self)
    let store = PlayerStore()
    defer { store.shutdown() }
    store.connect()
    try waitUntil("The hidden real store connects with a fresh position") {
        if case .ready = store.connection { return store.snapshot?.state == "paused" && store.queue.count == 2 }
        return false
    }
    try expect(abs((store.snapshot?.position ?? -1) - 3) < 0.2,
               "The real retained envelope cannot rewind a seek that does not emit a position event")
    _ = try client.call("play", as: EmptyResult.self)
    try waitUntil("External play reaches the hidden store through an omitted-retained event") { store.snapshot?.isPlaying == true }
    _ = try client.call("pause", as: EmptyResult.self)
    try waitUntil("External pause reaches the hidden store") { store.snapshot?.state == "paused" }
    _ = try client.call("speed", parameters: ["value": 1.5], as: EmptyResult.self)
    try waitUntil("Playback speed reaches the hidden store") { store.snapshot?.speed == 1.5 }
    let revision = try client.snapshot().playlist_revision
    _ = try client.call("queue.play", parameters: ["index": 1, "if_revision": revision], as: EmptyResult.self)
    try waitUntil("An external track change reaches hidden metadata") { store.snapshot?.currentTrack?.path == second.path }
    for command in [PlayerCommand.pause, .pause, .play, .play, .pause] {
        try expect(store.perform(command, queueIfBusy: true), "The real worker accepts separate play and pause commands")
    }
    try waitUntil("Repeated explicit play and pause settle without toggling") { !store.busy && store.snapshot?.state == "paused" }
    try expect(try client.snapshot().state == "paused", "The actual daemon receives idempotent pause operations")
    _ = try client.call("stop", as: EmptyResult.self)
    try waitUntil("An external stop reaches the hidden store") { store.snapshot?.state == "stopped" }
    _ = try client.call("speed", parameters: ["value": 1], as: EmptyResult.self)

    var disconnected = false
    store.onChange = {
        if case .unavailable = store.connection {
            disconnected = store.snapshot == nil && store.queue.isEmpty && store.queueRevision == nil
        }
    }
    kill(daemonPID, SIGTERM)
    try waitUntil("The disposable daemon exits and the hidden store clears its state") { kill(daemonPID, 0) != 0 && disconnected }
    let replacement = Process()
    replacement.executableURL = client.executable
    replacement.arguments = ["--daemon"]
    replacement.environment = CommandRunner.cliampEnvironment()
    replacement.standardInput = FileHandle.nullDevice
    replacement.standardOutput = FileHandle.nullDevice
    replacement.standardError = FileHandle.nullDevice
    try replacement.run()
    do {
        try waitUntil("A real replacement daemon reconnects without reopening the panel") {
            if case .ready = store.connection { return store.snapshot != nil }
            return false
        }
        try expect(store.queue.isEmpty && store.queueRevision == nil,
                   "Hidden daemon recovery cannot reuse the previous displayed queue")
        _ = try client.call("queue.clear", as: EmptyResult.self)
        _ = try client.call("queue", parameters: ["path": second.path], as: EmptyResult.self)
        _ = try client.call("play", as: EmptyResult.self)
        try waitUntil("Live events continue after real daemon replacement") {
            store.snapshot?.isPlaying == true && store.snapshot?.currentTrack?.path == second.path
        }
        _ = try client.call("pause", as: EmptyResult.self)
        print("PASS: actual hidden runtime events, retained seek position, speed, track change, idempotent commands, stop, daemon replacement and recovery")
        return replacement
    } catch {
        if replacement.isRunning { replacement.terminate(); replacement.waitUntilExit() }
        throw error
    }
}
