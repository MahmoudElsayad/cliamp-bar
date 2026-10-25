import Foundation

func expect(_ condition: @autoclosure () throws -> Bool, _ message: String) throws {
    if try !condition() { throw CliampError(message: message) }
}

func unitTests() throws {
    let zero = Data("""
    {"ok":true,"snapshot":{"revision":1,"playlist_revision":1,"state":"stopped","logical_track":{"title":"Lofi"}}}
    """.utf8)
    let state = try JSONDecoder().decode(RemoteReply<EmptyResult>.self, from: zero).snapshot!
    try expect(state.position == nil && state.volume == nil, "Old snapshots can omit zero-valued fields")
    try expect(state.currentTrack?.displayTitle == "Lofi", "A stopped player exposes the logical track")
    let command = PlayerCommand.playQueue(index: 0, revision: 17)
    try expect(command.parameters["index"] as? Int == 0, "The first queue index is zero")
    try expect(command.parameters["if_revision"] as? Int == 17, "Queue commands reject stale playlists")

    let shell = URL(fileURLWithPath: "/bin/sh")
    let output = try CommandRunner.run(shell, arguments: ["-c", "i=0; while [ $i -lt 10000 ]; do echo stdout; echo stderr >&2; i=$((i+1)); done"], timeout: 5)
    try expect(output.count == 70_000, "Both pipes drain without a deadlock")
    for _ in 0..<80 {
        let response = try CommandRunner.run(shell, arguments: ["-c", "printf '{\"ok\":true}'"])
        try expect(String(decoding: response, as: UTF8.self) == "{\"ok\":true}", "Fast command exits retain their complete response")
    }
    do {
        _ = try CommandRunner.run(shell, arguments: ["-c", "echo 'specific failure' >&2; exit 7"])
        throw CliampError(message: "A failed command must throw")
    } catch let error as CliampError {
        try expect(error.message == "specific failure", "The caller receives the command diagnostic")
    }
    let start = Date()
    do {
        _ = try CommandRunner.run(shell, arguments: ["-c", "exec sleep 10"], timeout: 0.1)
        throw CliampError(message: "A timed-out command must throw")
    } catch {
        try expect(Date().timeIntervalSince(start) < 3, "A stuck command has a bounded deadline")
    }
    let childStart = Date()
    _ = try CommandRunner.run(shell, arguments: ["-c", "sleep 5 & exit 0"], timeout: 0.2)
    try expect(Date().timeIntervalSince(childStart) < 2, "An inherited pipe cannot hang the command runner")
    try spectrumTests()
    print("PASS: snapshot decoding, queue revision, pipe draining, command failures, timeout")
}

func silentWAV(at path: URL, seconds: Int) throws {
    var data = Data()
    func text(_ value: String) { data.append(contentsOf: value.utf8) }
    func u32(_ value: UInt32) { var value = value.littleEndian; withUnsafeBytes(of: &value) { data.append(contentsOf: $0) } }
    func u16(_ value: UInt16) { var value = value.littleEndian; withUnsafeBytes(of: &value) { data.append(contentsOf: $0) } }
    let count = UInt32(44_100 * seconds * 2)
    text("RIFF"); u32(count + 36); text("WAVEfmt "); u32(16); u16(1); u16(1)
    u32(44_100); u32(88_200); u16(2); u16(16); text("data"); u32(count)
    data.append(Data(count: Int(count)))
    try data.write(to: path)
}

func waitUntil(_ description: String, _ predicate: () -> Bool) throws {
    let deadline = Date().addingTimeInterval(10)
    while !predicate() && Date() < deadline { RunLoop.current.run(until: Date().addingTimeInterval(0.02)) }
    try expect(predicate(), description)
}

func storeTests(client: CliampClient, file: URL) throws {
    _ = try client.call("queue.clear", as: EmptyResult.self)
    for _ in 0..<105 { _ = try client.call("queue", parameters: ["path": file.path], as: EmptyResult.self) }
    let store = PlayerStore()
    store.connect()
    try waitUntil("The first queue page loads") { store.queue.count == 100 }
    store.refreshQueue(loadMore: true)
    store.refreshQueue(loadMore: true)
    try waitUntil("The next queue page loads once") { store.queue.count >= 105 && !store.queueLoading }
    try expect(store.queue.count == 105, "Repeated Load More requests do not duplicate rows")
    let indices = store.queue.enumerated().map { $0.element.index ?? $0.offset }
    try expect(Set(indices).count == 105 && indices.last == 104, "Each queue row retains its real index")
    let displayedRevision = store.queueRevision
    _ = try client.call("queue", parameters: ["path": file.path], as: EmptyResult.self)
    var sawStaleRows = false
    var retainedRevision = false
    store.onChange = {
        if store.snapshot?.playlist_revision != store.queueRevision, !store.queue.isEmpty {
            sawStaleRows = true
            retainedRevision = store.queueRevision == displayedRevision
        }
    }
    store.refresh()
    try waitUntil("The queue refresh reaches the new revision") { store.queueTotal == 106 }
    try expect(sawStaleRows && retainedRevision, "A new player snapshot cannot relabel old rows with a new revision")
    store.onChange = {}
    print("PASS: store paging prevents duplicate rows and retains the displayed queue revision")
}

func integrationTests() throws {
    guard let directory = ProcessInfo.processInfo.environment["CLIAMP_CONFIG_DIR"], directory.contains("cliampbar-test.") else {
        throw CliampError(message: "Integration tests require a disposable CLIAMP_CONFIG_DIR")
    }
    guard let executable = CliampExecutable.find() else { throw CliampError(message: "Install Cliamp to run the integration test") }
    let client = CliampClient(executable: executable)
    let appPath = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
        .appendingPathComponent("build/CliampBar.app/Contents/MacOS/CliampBar")
    let application = Process()
    application.executableURL = appPath
    application.standardOutput = FileHandle.nullDevice
    application.standardError = FileHandle.nullDevice
    try application.run()
    var daemonPID: Int32?
    defer {
        if application.isRunning { application.terminate(); application.waitUntilExit() }
        if let daemonPID { kill(daemonPID, SIGTERM) }
    }
    var connected = false
    for _ in 0..<50 {
        if (try? client.snapshot()) != nil { connected = true; break }
        Thread.sleep(forTimeInterval: 0.1)
    }
    try expect(connected, "The daemon starts without a terminal")
    let pidText = try String(contentsOfFile: directory + "/cliamp.sock.pid", encoding: .utf8)
    daemonPID = Int32(pidText.trimmingCharacters(in: .whitespacesAndNewlines))
    try expect(daemonPID != nil, "The app starts a daemon with a recorded identity")
    let features = try client.capabilities()
    try expect(features.contains("seek.absolute") && features.contains("queue.play"), "The installed player supports the controls")
    let file = URL(fileURLWithPath: directory).appendingPathComponent("Silent track with spaces.wav")
    try silentWAV(at: file, seconds: 12)
    _ = try client.call("queue.clear", as: EmptyResult.self)
    _ = try client.call("queue", parameters: ["path": file.path], as: EmptyResult.self)
    let listing = try client.call("queue.list", as: TrackPage.self)
    try expect(listing.job?.result?.tracks?.count == 1, "A local file enters the queue")
    _ = try client.call("volume", parameters: ["value": -30], as: EmptyResult.self)
    _ = try client.call("play", as: EmptyResult.self)
    Thread.sleep(forTimeInterval: 0.3)
    try expect(try client.snapshot().isPlaying, "The real audio engine starts playback")
    try realSpectrumTests(executable: executable)
    _ = try client.call("pause", as: EmptyResult.self)
    try expect(try client.snapshot().state == "paused", "Pause changes the actual playback state")
    _ = try client.call("seek.absolute", parameters: ["value": 3], as: EmptyResult.self)
    let sought = try client.snapshot()
    try expect(abs((sought.position ?? -1) - 3) < 0.2, "Seeking reaches the requested position")
    try expect(sought.volume == -30, "Volume uses absolute decibels")
    _ = try client.call("shuffle", parameters: ["name": "on"], as: EmptyResult.self)
    _ = try client.call("repeat", parameters: ["name": "one"], as: EmptyResult.self)
    let modes = try client.snapshot()
    try expect(modes.shuffle == true && modes.repeat?.lowercased() == "one", "Playback modes reach Cliamp")
    _ = try client.call("toggle", as: EmptyResult.self)
    try expect(try client.snapshot().isPlaying, "The same toggle operation as the GUI resumes playback")
    _ = try client.call("toggle", as: EmptyResult.self)
    try expect(try client.snapshot().state == "paused", "The GUI toggle pauses playback")
    _ = try client.call("shuffle", as: EmptyResult.self)
    _ = try client.call("repeat", as: EmptyResult.self)
    let toggled = try client.snapshot()
    try expect(toggled.shuffle == false && toggled.repeat?.lowercased() == "off", "Parameter-free mode controls match the GUI")
    let liveRevision = try client.snapshot().playlist_revision
    _ = try client.call("queue.play", parameters: ["index": 0, "if_revision": liveRevision], as: EmptyResult.self)
    try expect(try client.snapshot().isPlaying, "A valid queue row starts playback")
    _ = try client.call("pause", as: EmptyResult.self)
    do {
        _ = try client.call("queue.play", parameters: ["index": 0, "if_revision": 1], as: EmptyResult.self)
        throw CliampError(message: "A stale queue revision must fail")
    } catch let error as CliampError {
        try expect(error.message.contains("conflict"), "Cliamp rejects the stale queue action: \(error.message)")
    }
    let providers = try client.call("provider.list", as: ProviderPage.self)
    try expect(providers.job?.result?.providers.contains { $0.key == "local" } == true, "The library discovers local playlists")
    let local = try client.call("provider.playlists", parameters: ["provider": "local"], as: PlaylistPage.self)
    try expect(local.job?.result?.playlists?.contains { $0.id == "Favorites" } == true, "Local playlists load through the GUI operation")
    try storeTests(client: client, file: file)
    _ = try client.call("play", as: EmptyResult.self)
    application.terminate()
    application.waitUntilExit()
    try expect(application.terminationReason == .exit && application.terminationStatus == 0, "SIGTERM runs normal application termination cleanup")
    try expect(try client.snapshot().isPlaying, "Playback survives the GUI process exiting")
    _ = try client.call("pause", as: EmptyResult.self)
    print("PASS: daemon start, actual playback, pause, seek, volume, modes, stale queue, library")
    print("PASS: the actual app starts a missing daemon and leaves playback running after GUI exit")
}

do {
    if CommandLine.arguments.contains("--integration") { try integrationTests() }
    else { try unitTests() }
} catch {
    fputs("FAIL: \(String(reflecting: error))\n", stderr)
    exit(1)
}
