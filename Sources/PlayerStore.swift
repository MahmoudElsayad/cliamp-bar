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

    func connect() {
        guard !busy else { return }
        busy = true
        commandGeneration += 1
        connection = .connecting
        client = nil
        message = nil
        onChange()
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
                    self.client = client
                    self.snapshot = state
                    self.capabilities = capabilities
                    self.connection = .ready
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
                    self.connection = .unavailable(error.localizedDescription)
                    self.busy = false
                    self.onChange()
                }
            }
        }
    }

    func setVisible(_ value: Bool) {
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
        reader.async {
            let result = Result { try client.snapshot() }
            DispatchQueue.main.async {
                self.refreshing = false
                guard self.client === client else { return }
                guard generation == self.commandGeneration else { self.refresh(); return }
                switch result {
                case .success(let state):
                    self.snapshot = state
                    if state.playlist_revision != self.queueRevision { self.refreshQueue() }
                case .failure(let error):
                    self.connection = .unavailable(error.localizedDescription)
                }
                self.onChange()
            }
        }
    }

    func perform(_ command: PlayerCommand) {
        guard !busy, case .ready = connection, let client else { return }
        guard capabilities.contains(command.operation) else {
            showMessage("This Cliamp version does not support \(command.operation).")
            return
        }
        busy = true
        commandGeneration += 1
        message = nil
        onChange()
        worker.async {
            let result = Result { try client.call(command.operation, parameters: command.parameters, as: EmptyResult.self) }
            DispatchQueue.main.async {
                self.busy = false
                switch result {
                case .success(let reply): self.snapshot = reply.job?.snapshot ?? self.snapshot
                case .failure(let error): self.message = error.localizedDescription
                }
                self.onChange()
                self.refresh()
            }
        }
    }

    func addFiles(_ paths: [String]) {
        guard !paths.isEmpty, !busy, case .ready = connection, let client else { return }
        busy = true
        commandGeneration += 1
        message = nil
        onChange()
        worker.async {
            let result = Result { () -> Void in
                for path in paths { _ = try client.call("queue", parameters: ["path": path], as: EmptyResult.self) }
            }
            DispatchQueue.main.async {
                self.busy = false
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
        reader.async {
            let result = Result { try client.call("queue.list", parameters: ["offset": offset, "limit": 100], as: TrackPage.self) }
            DispatchQueue.main.async {
                self.queueLoading = false
                guard self.client === client else { return }
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
        reader.async {
            let result = Result { try client.call("provider.list", as: ProviderPage.self) }
            DispatchQueue.main.async {
                guard self.client === client else { return }
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
        reader.async {
            let result = Result { try client.call("provider.playlists", parameters: ["provider": provider, "offset": offset, "limit": 100], as: PlaylistPage.self) }
            DispatchQueue.main.async {
                self.libraryBusy = false
                guard self.client === client else { return }
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
}
