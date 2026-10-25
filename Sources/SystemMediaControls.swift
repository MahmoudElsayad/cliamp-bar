import Foundation
import MediaPlayer

enum SystemMediaAction: CaseIterable, Hashable {
    case play, pause, toggle, next, previous, seek

    func command(position: Double?) -> PlayerCommand? {
        switch self {
        case .play: return .play
        case .pause: return .pause
        case .toggle: return .toggle
        case .next: return .next
        case .previous: return .previous
        case .seek:
            guard let position, position.isFinite, position >= 0 else { return nil }
            return .seek(position)
        }
    }
}

protocol SystemMediaSurface: AnyObject {
    func addTarget(for action: SystemMediaAction, handler: @escaping (Double?) -> MPRemoteCommandHandlerStatus) -> Any
    func removeTarget(_ target: Any, for action: SystemMediaAction)
    func setEnabled(_ enabled: Bool, for action: SystemMediaAction)
    func setNowPlaying(_ info: [String: Any]?)
    func setPlaybackState(_ state: MPNowPlayingPlaybackState)
}

private final class NativeSystemMediaSurface: SystemMediaSurface {
    private let commands = MPRemoteCommandCenter.shared()
    private let info = MPNowPlayingInfoCenter.default()

    private func command(_ action: SystemMediaAction) -> MPRemoteCommand {
        switch action {
        case .play: return commands.playCommand
        case .pause: return commands.pauseCommand
        case .toggle: return commands.togglePlayPauseCommand
        case .next: return commands.nextTrackCommand
        case .previous: return commands.previousTrackCommand
        case .seek: return commands.changePlaybackPositionCommand
        }
    }

    func addTarget(for action: SystemMediaAction, handler: @escaping (Double?) -> MPRemoteCommandHandlerStatus) -> Any {
        command(action).addTarget { event in
            let position = (event as? MPChangePlaybackPositionCommandEvent)?.positionTime
            return handler(position)
        }
    }

    func removeTarget(_ target: Any, for action: SystemMediaAction) { command(action).removeTarget(target) }
    func setEnabled(_ enabled: Bool, for action: SystemMediaAction) { command(action).isEnabled = enabled }
    func setNowPlaying(_ info: [String: Any]?) { self.info.nowPlayingInfo = info }
    func setPlaybackState(_ state: MPNowPlayingPlaybackState) { info.playbackState = state }
}

private struct NowPlayingContent: Equatable {
    let title: String
    let artist: String?
    let album: String?
    let path: String?
    let duration: Double?
    let elapsed: Double
    let rate: Double
    let live: Bool
    let playing: Bool

    init(snapshot: PlayerSnapshot, track: Track) {
        title = track.displayTitle
        artist = track.artist
        album = track.album
        path = track.path
        duration = [snapshot.duration, track.duration].compactMap { $0 }.first { $0.isFinite && $0 > 0 }
        elapsed = max(0, snapshot.position ?? 0)
        let speed = snapshot.speed ?? 1
        rate = snapshot.isPlaying ? (speed.isFinite && speed > 0 ? speed : 1) : 0
        live = duration == nil && track.realtime == true && snapshot.seekable != true
        playing = snapshot.isPlaying
    }

    var info: [String: Any] {
        var result: [String: Any] = [
            MPMediaItemPropertyTitle: title,
            MPNowPlayingInfoPropertyElapsedPlaybackTime: elapsed,
            MPNowPlayingInfoPropertyPlaybackRate: rate,
            MPNowPlayingInfoPropertyIsLiveStream: live,
            MPNowPlayingInfoPropertyMediaType: MPNowPlayingInfoMediaType.audio.rawValue
        ]
        result[MPMediaItemPropertyArtist] = artist
        result[MPMediaItemPropertyAlbumTitle] = album
        result[MPMediaItemPropertyPlaybackDuration] = duration
        result[MPNowPlayingInfoPropertyExternalContentIdentifier] = path
        return result
    }
}

// The app main loop owns the shared MediaPlayer centers and all target lifetimes.
final class SystemMediaControls {
    private let surface: SystemMediaSurface
    private let perform: (PlayerCommand) -> Bool
    private var targets: [(SystemMediaAction, Any)] = []
    private var enabled = Set<SystemMediaAction>()
    private var content: NowPlayingContent?
    private var playbackState = MPNowPlayingPlaybackState.stopped
    private var stopped = false

    init(surface: SystemMediaSurface? = nil, perform: @escaping (PlayerCommand) -> Bool) {
        precondition(Thread.isMainThread)
        self.surface = surface ?? NativeSystemMediaSurface()
        self.perform = perform
        for action in SystemMediaAction.allCases {
            self.surface.setEnabled(false, for: action)
            let target = self.surface.addTarget(for: action) { [weak self] position in
                let accept = {
                    guard let self, !self.stopped, self.enabled.contains(action),
                          let command = action.command(position: position), self.perform(command) else {
                        return MPRemoteCommandHandlerStatus.commandFailed
                    }
                    return MPRemoteCommandHandlerStatus.success
                }
                return Thread.isMainThread ? accept() : DispatchQueue.main.sync(execute: accept)
            }
            targets.append((action, target))
        }
    }

    func update(snapshot: PlayerSnapshot?, connected: Bool, capabilities: Set<String>) {
        precondition(Thread.isMainThread)
        guard !stopped else { return }
        let next: NowPlayingContent?
        if connected, let snapshot, ["playing", "paused"].contains(snapshot.state), let track = snapshot.currentTrack {
            next = NowPlayingContent(snapshot: snapshot, track: track)
        } else { next = nil }
        var available = Set<SystemMediaAction>()
        if next != nil {
            for action in SystemMediaAction.allCases {
                guard let command = action.command(position: 0), capabilities.contains(command.operation) else { continue }
                if action == .seek, snapshot?.seekable != true { continue }
                available.insert(action)
            }
        }
        for action in enabled.symmetricDifference(available) { surface.setEnabled(available.contains(action), for: action) }
        enabled = available
        if content != next {
            content = next
            surface.setNowPlaying(next?.info)
        }
        let state: MPNowPlayingPlaybackState = next.map { $0.playing ? .playing : .paused } ?? .stopped
        if playbackState != state {
            playbackState = state
            surface.setPlaybackState(state)
        }
    }

    func shutdown() {
        precondition(Thread.isMainThread)
        guard !stopped else { return }
        stopped = true
        for (action, target) in targets {
            surface.setEnabled(false, for: action)
            surface.removeTarget(target, for: action)
        }
        targets.removeAll()
        enabled.removeAll()
        if content != nil { surface.setNowPlaying(nil) }
        if playbackState != .stopped { surface.setPlaybackState(.stopped) }
        content = nil
        playbackState = .stopped
    }

    deinit { shutdown() }
}
