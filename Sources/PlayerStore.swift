import Foundation

final class PlayerStore {
    private(set) var connection = PlayerConnection.connecting
    private(set) var snapshot: PlayerSnapshot?
    private(set) var capabilities = Set<String>()
    private(set) var queue: [Track] = []
    private(set) var queueTotal = 0
    private(set) var queueRevision: Int?
    private(set) var queueLoading = false
    private(set) var providers: [LibraryProvider] = []
    private(set) var playlists: [SavedPlaylist] = []
    private(set) var playlistTotal = 0
    private(set) var selectedProvider = "local"
    private(set) var busy = false
    private(set) var libraryBusy = false
    private(set) var message: String?
    var onChange: () -> Void = {}
    private let worker = DispatchQueue(label: "io.cliampbar.player", qos: .userInitiated)
    private let reader = DispatchQueue(label: "io.cliampbar.reads", qos: .userInitiated, attributes: .concurrent)
    var executable: URL? { client?.executable }
    private var client: CliampClient?
    private var daemon: Process?
    private var refreshing = false
    private var commandGeneration = 0
    private var timer: Timer?
    private var visible = false
    private let runtime: RuntimeStateSession
    private var streamEpoch = 0
    private var streamEstablished = false
    private var observationGeneration = 0
    private var pendingOperations = 0
    static let commandLimit = 16

    init(runtime: RuntimeStateSession = RuntimeStateSession()) { self.runtime = runtime }

    private func observeRuntime() {
        runtime.onEvent = { [weak self] event in
            guard let self else { return }
            if !self.streamEstablished {
                self.streamEstablished = true
                self.recoverStream()
            }
            // Retained positions can predate a fresh state read even at the same revision.
            if !event.retained { self.accept(event.data, allowEqual: false) }
            self.onChange()
        }
        runtime.onDisconnect = { [weak self] in
            guard let self else { return }
            self.streamEpoch += 1
            self.streamEstablished = false
            self.refreshing = false
            self.snapshot = nil
            self.queue = []
            self.queueTotal = 0
            self.queueRevision = nil
            self.queueLoading = false
            self.libraryBusy = false
            self.connection = .unavailable("The player connection closed. Reconnecting…")
            self.onChange()
        }
    }

    private func recoverStream() {
        guard let client else { return }
        let epoch = streamEpoch
        let observation = observationGeneration
        reader.async {
            let result = Result { try client.snapshot() }
            DispatchQueue.main.async {
                guard self.client === client, self.streamEpoch == epoch else { return }
                switch result {
                case .success(let state):
                    self.accept(state, allowEqual: observation == self.observationGeneration)
                    self.connection = .ready
                    if self.visible, self.queueRevision != self.snapshot?.playlist_revision { self.refreshQueue() }
                case .failure:
                    self.runtime.reconnect()
                }
                self.onChange()
            }
        }
    }

    private func accept(_ state: PlayerSnapshot, allowEqual: Bool) {
        if let snapshot {
            guard state.revision > snapshot.revision || (allowEqual && state.revision == snapshot.revision) else { return }
        }
        snapshot = state
        observationGeneration += 1
    }

    func connect() {
        guard !busy else { return }
        runtime.shutdown()
        streamEpoch += 1
        streamEstablished = false
        refreshing = false
        queueLoading = false
        libraryBusy = false
        snapshot = nil
        busy = true
        commandGeneration += 1
        connection = .connecting
        client = nil
        message = nil
        onChange()
        let epoch = streamEpoch
        worker.async { [self] in
            do {
                guard let executable = CliampExecutable.find() else {
                    throw CliampError(message: "Cliamp is missing. Run ./install.sh from the CliampBar repository to install it.")
                }
                let client = CliampClient(executable: executable)
                let state: PlayerSnapshot
                do { state = try client.snapshot() }
                catch {
                    let detail = error.localizedDescription.lowercased()
                    guard detail.contains("no socket") || detail.contains("connection refused") || detail.contains("not running") else { throw error }
                    if daemon?.isRunning != true { daemon = try client.startDaemon() }
                    var ready: PlayerSnapshot?
                    for _ in 0..<40 {
                        if let value = try? client.snapshot() { ready = value; break }
                        Thread.sleep(forTimeInterval: 0.15)
                    }
                    guard let value = ready else {
                        throw CliampError(message: "Cliamp did not start. Read ~/Library/Logs/CliampBar/daemon.log, then click Reconnect.")
                    }
                    state = value
                }
                let capabilities = try client.capabilities()
                DispatchQueue.main.async {
                    guard self.streamEpoch == epoch else { return }
                    self.client = client
                    self.snapshot = state
                    self.observationGeneration += 1
                    self.capabilities = capabilities
                    self.observeRuntime()
                    self.runtime.start(executable: client.executable)
                    self.busy = false
                    self.queueRevision = nil
                    self.queue = []
                    self.queueTotal = 0
                    self.onChange()
                    self.refreshQueue()
                    self.loadProviders()
                }
            } catch {
                DispatchQueue.main.async {
                    guard self.streamEpoch == epoch else { return }
                    self.connection = .unavailable(error.localizedDescription)
                    self.busy = false
                    self.onChange()
                }
            }
        }
    }

    func setVisible(_ value: Bool) {
        visible = value
        timer?.invalidate()
        timer = nil
        if value {
            refresh()
            timer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in self?.refresh() }
        }
    }

    func refresh() {
        guard !refreshing, !busy, case .ready = connection, let client else { return }
        refreshing = true
        let generation = commandGeneration
        let observation = observationGeneration
        let epoch = streamEpoch
        reader.async {
            let result = Result { try client.snapshot() }
            DispatchQueue.main.async {
                guard self.client === client, self.streamEpoch == epoch else { return }
                self.refreshing = false
                guard generation == self.commandGeneration else { self.refresh(); return }
                switch result {
                case .success(let state):
                    self.accept(state, allowEqual: observation == self.observationGeneration)
                    if self.visible, self.snapshot?.playlist_revision != self.queueRevision { self.refreshQueue() }
                case .failure:
                    self.runtime.reconnect()
                }
                self.onChange()
            }
        }
    }

    @discardableResult
    func perform(_ command: PlayerCommand, queueIfBusy: Bool = false) -> Bool {
        guard (!busy || queueIfBusy), pendingOperations < Self.commandLimit,
              case .ready = connection, let client else { return false }
        guard capabilities.contains(command.operation) else {
            showMessage("This Cliamp version does not support \(command.operation).")
            return false
        }
        pendingOperations += 1
        busy = true
        commandGeneration += 1
        let epoch = streamEpoch
        message = nil
        onChange()
        worker.async {
            let result = Result { try client.call(command.operation, parameters: command.parameters, as: EmptyResult.self) }
            DispatchQueue.main.async {
                guard self.client === client else { return }
                self.pendingOperations -= 1
                self.busy = self.pendingOperations > 0
                switch result {
                case .success(let reply):
                    if self.streamEpoch == epoch, let state = reply.job?.snapshot { self.accept(state, allowEqual: false) }
                case .failure(let error): self.message = error.localizedDescription
                }
                self.onChange()
                self.refresh()
            }
        }
        return true
    }

    func addFiles(_ paths: [String]) {
        guard !paths.isEmpty, !busy, case .ready = connection, let client else { return }
        pendingOperations += 1
        busy = true
        commandGeneration += 1
        message = nil
        onChange()
        worker.async {
            let result = Result { () -> Void in
                for path in paths { _ = try client.call("queue", parameters: ["path": path], as: EmptyResult.self) }
            }
            DispatchQueue.main.async {
                guard self.client === client else { return }
                self.pendingOperations -= 1
                self.busy = self.pendingOperations > 0
                if case .failure(let error) = result { self.message = error.localizedDescription }
                self.refresh()
                self.onChange()
            }
        }
    }

    func refreshQueue(loadMore: Bool = false) {
        guard let client, capabilities.contains("queue.list"), !queueLoading else { return }
        if loadMore, queueRevision != snapshot?.playlist_revision { return }
        queueLoading = true
        let offset = loadMore ? queue.count : 0
        let revision = snapshot?.playlist_revision
        let epoch = streamEpoch
        reader.async {
            let result = Result { try client.call("queue.list", parameters: ["offset": offset, "limit": 100], as: TrackPage.self) }
            DispatchQueue.main.async {
                guard self.client === client, self.streamEpoch == epoch else { return }
                self.queueLoading = false
                switch result {
                case .success(let reply):
                    guard reply.job?.snapshot?.playlist_revision == self.snapshot?.playlist_revision,
                          !loadMore || revision == self.queueRevision else { self.onChange(); return }
                    let tracks = reply.job?.result?.tracks ?? []
                    self.queue = loadMore ? self.queue + tracks : tracks
                    self.queueTotal = reply.job?.result?.total ?? self.queue.count
                    self.queueRevision = reply.job?.snapshot?.playlist_revision
                case .failure(let error): self.message = error.localizedDescription
                }
                self.onChange()
            }
        }
    }

    private func loadProviders() {
        guard let client, capabilities.contains("provider.list") else { return }
        let epoch = streamEpoch
        reader.async {
            let result = Result { try client.call("provider.list", as: ProviderPage.self) }
            DispatchQueue.main.async {
                guard self.client === client, self.streamEpoch == epoch else { return }
                switch result {
                case .success(let reply):
                    self.providers = reply.job?.result?.providers ?? []
                    if !self.providers.contains(where: { $0.key == self.selectedProvider }) {
                        self.selectedProvider = self.providers.first?.key ?? "local"
                    }
                    self.loadPlaylists(provider: self.selectedProvider)
                case .failure(let error): self.message = error.localizedDescription
                }
                self.onChange()
            }
        }
    }

    func loadPlaylists(provider: String, loadMore: Bool = false) {
        guard let client, capabilities.contains("provider.playlists"), !libraryBusy else { return }
        selectedProvider = provider
        let offset = loadMore ? playlists.count : 0
        if !loadMore { playlists = []; playlistTotal = 0 }
        libraryBusy = true
        onChange()
        let epoch = streamEpoch
        reader.async {
            let result = Result { try client.call("provider.playlists", parameters: ["provider": provider, "offset": offset, "limit": 100], as: PlaylistPage.self) }
            DispatchQueue.main.async {
                guard self.client === client, self.streamEpoch == epoch else { return }
                self.libraryBusy = false
                switch result {
                case .success(let reply):
                    let values = reply.job?.result?.playlists ?? []
                    self.playlists = loadMore ? self.playlists + values : values
                    self.playlistTotal = reply.job?.result?.total ?? self.playlists.count
                case .failure(let error): self.message = error.localizedDescription
                }
                self.onChange()
            }
        }
    }

    func showMessage(_ value: String?) { message = value; onChange() }

    func shutdown() {
        timer?.invalidate()
        timer = nil
        runtime.shutdown()
        streamEpoch += 1
        client = nil
        snapshot = nil
        connection = .unavailable("CliampBar stopped.")
        onChange = {}
    }

    deinit { runtime.shutdown(); timer?.invalidate() }
}
