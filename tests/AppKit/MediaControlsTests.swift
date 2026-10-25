import AppKit
import MediaPlayer

private final class FakeMediaSurface: SystemMediaSurface {
    var handlers: [SystemMediaAction: (Double?) -> MPRemoteCommandHandlerStatus] = [:]
    var tokens: [SystemMediaAction: NSObject] = [:]
    var enabled = Set<SystemMediaAction>()
    var registrations = 0
    var removals = 0
    var info: [String: Any]?
    var infoWrites = 0
    var state = MPNowPlayingPlaybackState.stopped
    var stateWrites = 0

    func addTarget(for action: SystemMediaAction, handler: @escaping (Double?) -> MPRemoteCommandHandlerStatus) -> Any {
        registrations += 1
        handlers[action] = handler
        let token = NSObject()
        tokens[action] = token
        return token
    }

    func removeTarget(_ target: Any, for action: SystemMediaAction) {
        expect((target as? NSObject) === tokens[action], "Shutdown removes each exact registration token")
        tokens[action] = nil
        removals += 1
    }

    func setEnabled(_ enabled: Bool, for action: SystemMediaAction) {
        if enabled { self.enabled.insert(action) } else { self.enabled.remove(action) }
    }
    func setNowPlaying(_ info: [String: Any]?) { self.info = info; infoWrites += 1 }
    func setPlaybackState(_ state: MPNowPlayingPlaybackState) { self.state = state; stateWrites += 1 }
}

func mediaControlsTests() throws {
    let surface = FakeMediaSurface()
    var received: [PlayerCommand] = []
    var accepting = true
    var callbackOnMain = true
    var controls: SystemMediaControls? = SystemMediaControls(surface: surface) {
        received.append($0)
        callbackOnMain = callbackOnMain && Thread.isMainThread
        return accepting
    }
    defer { controls?.shutdown() }
    let capabilities: Set<String> = ["play", "pause", "toggle", "next", "prev", "seek.absolute"]
    func state(_ state: String = "playing", position: Double = 12, speed: Double = 1.5,
               track: String = "\"title\":\"Song\",\"artist\":\"Artist\",\"album\":\"Album\",\"path\":\"/song.wav\",\"duration\":120",
               duration: Double = 120, seekable: Bool = true) throws -> PlayerSnapshot {
        let json = """
        {"revision":8,"playlist_revision":2,"state":"\(state)","position":\(position),"speed":\(speed),"duration":\(duration),"seekable":\(seekable),"track":{\(track)}}
        """
        return try JSONDecoder().decode(PlayerSnapshot.self, from: Data(json.utf8))
    }
    func update(_ snapshot: PlayerSnapshot?, connected: Bool = true, supported: Set<String>? = nil) {
        controls?.update(snapshot: snapshot, connected: connected, capabilities: supported ?? capabilities)
    }
    expect(surface.registrations == 6 && surface.enabled.isEmpty, "Handlers register once and start disabled")
    expect(surface.handlers[.play]?(nil) == .commandFailed && received.isEmpty, "Unavailable commands never report success")
    let playing = try state()
    update(playing)
    expect(surface.state == .playing && surface.enabled.count == 6, "Finite playback enables supported commands and native playing state")
    expect(surface.info?[MPMediaItemPropertyTitle] as? String == "Song"
           && surface.info?[MPMediaItemPropertyArtist] as? String == "Artist"
           && surface.info?[MPMediaItemPropertyAlbumTitle] as? String == "Album", "Now Playing publishes track metadata")
    expect(surface.info?[MPMediaItemPropertyPlaybackDuration] as? Double == 120
           && surface.info?[MPNowPlayingInfoPropertyElapsedPlaybackTime] as? Double == 12
           && surface.info?[MPNowPlayingInfoPropertyPlaybackRate] as? Double == 1.5,
           "Now Playing publishes duration, accurate elapsed time, and actual playback speed")
    let writes = surface.infoWrites
    let stateWrites = surface.stateWrites
    for _ in 0..<5 { update(playing) }
    expect(surface.infoWrites == writes && surface.stateWrites == stateWrites && surface.registrations == 6,
           "Identical snapshots cannot reset active ownership or duplicate handlers")
    update(try state(position: 13))
    expect(surface.infoWrites == writes + 1 && surface.stateWrites == stateWrites,
           "Position updates retain playing state without resetting the active owner")
    for action in [SystemMediaAction.play, .play, .pause, .pause, .toggle, .next, .previous] {
        expect(surface.handlers[action]?(nil) == .success, "An accepted media action returns success")
    }
    expect(received.map(\.operation) == ["play", "play", "pause", "pause", "toggle", "next", "prev"],
           "Each event dispatches exactly once and play or pause never becomes toggle")
    expect(surface.handlers[.seek]?(42) == .success && received.last?.parameters["value"] as? Double == 42,
           "A seek event dispatches its absolute position")
    let count = received.count
    for value in [Double.nan, -Double.infinity, -1] {
        expect(surface.handlers[.seek]?(value) == .commandFailed, "Invalid seek positions fail at the boundary")
    }
    expect(surface.handlers[.seek]?(nil) == .commandFailed && received.count == count, "A malformed seek dispatches nothing")
    accepting = false
    expect(surface.handlers[.toggle]?(nil) == .commandFailed && received.count == count + 1,
           "Busy admission failure returns commandFailed after exactly one attempt")
    accepting = true
    update(try state("paused"))
    expect(surface.state == .paused && surface.info?[MPNowPlayingInfoPropertyPlaybackRate] as? Double == 0
           && surface.enabled.contains(.play), "Paused playback retains metadata and usable resume controls")
    update(try state(track: "\"title\":\"Live radio\",\"realtime\":true,\"stream\":true", duration: 0, seekable: false))
    expect(surface.info?[MPNowPlayingInfoPropertyIsLiveStream] as? Bool == true
           && surface.info?[MPMediaItemPropertyPlaybackDuration] == nil && !surface.enabled.contains(.seek),
           "Live radio publishes its live flag without inventing a duration or a seek capability")
    expect(surface.handlers[.seek]?(10) == .commandFailed, "A disabled native command cannot dispatch")
    update(playing, supported: ["pause"])
    expect(surface.enabled == [.pause], "Capabilities restrict native commands")
    update(playing, connected: false)
    expect(surface.info == nil && surface.state == .stopped && surface.enabled.isEmpty,
           "Disconnect clears metadata and disables handlers")
    update(playing)
    update(try state("stopped"))
    expect(surface.info == nil && surface.enabled.isEmpty, "A stopped logical track cannot remain Now Playing")
    update(playing)
    update(try JSONDecoder().decode(PlayerSnapshot.self, from: Data("{\"revision\":9,\"playlist_revision\":2,\"state\":\"playing\"}".utf8)))
    expect(surface.info == nil && surface.enabled.isEmpty, "A missing track clears native state")
    update(playing)
    let late = surface.handlers[.toggle]!
    controls?.shutdown()
    controls?.shutdown()
    expect(surface.removals == 6 && surface.tokens.isEmpty && surface.info == nil && surface.enabled.isEmpty,
           "Shutdown removes exact tokens once and clears native state")
    let afterShutdown = received.count
    expect(late(nil) == .commandFailed && received.count == afterShutdown, "Late callbacks cannot dispatch after shutdown")
    controls = nil
    expect(callbackOnMain, "Media command admission stays on the main thread")
    print("PASS: MediaPlayer command mappings, single dispatch, admission failures, metadata, speed, paused/live state, capabilities, exact teardown")
}
