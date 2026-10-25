import AppKit
import ServiceManagement
import UniformTypeIdentifiers

final class KeyPanel: NSPanel {
    var onCancel: () -> Void = {}
    override var canBecomeKey: Bool { true }
    override func cancelOperation(_ sender: Any?) { onCancel() }
}

final class PanelDialogSession {
    private(set) var isOpen = false
    private(set) var stopped = false

    func run(window: NSWindow, above panel: NSWindow,
             runModal: () -> NSApplication.ModalResponse) -> NSApplication.ModalResponse? {
        guard !isOpen, !stopped, NSApp.modalWindow == nil else { return nil }
        isOpen = true
        let previousLevel = window.level
        window.level = NSWindow.Level(rawValue: panel.level.rawValue + 1)
        defer {
            window.level = previousLevel
            isOpen = false
            if !stopped, panel.isVisible, NSApp.isActive { panel.makeKeyAndOrderFront(nil) }
        }
        NSApp.activate(ignoringOtherApps: true)
        return runModal()
    }

    func shutdown() {
        stopped = true
        if isOpen { NSApp.abortModal() }
    }
}

final class PlayerPanel: NSObject {
    private let store: PlayerStore
    private let statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
    private let panel = KeyPanel(contentRect: NSRect(x: 0, y: 0, width: 380, height: 640),
                                 styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: true)
    private var card: PlayerCard!
    private var outsideMonitor: Any?
    private let dialogs = PanelDialogSession()
    private var menuOpen = false
    private var dialogOpen: Bool { dialogs.isOpen || menuOpen }
    private let spectrum = SpectrumSession()

    init(store: PlayerStore) {
        self.store = store
        super.init()
        statusItem.button?.image = NSImage(systemSymbolName: "hifispeaker", accessibilityDescription: "CliampBar")
        statusItem.button?.image?.isTemplate = true
        statusItem.button?.toolTip = "CliampBar"
        statusItem.button?.setAccessibilityLabel("CliampBar")
        statusItem.button?.target = self
        statusItem.button?.action = #selector(toggle)
        statusItem.button?.sendAction(on: [.leftMouseUp, .rightMouseUp])
        panel.level = .popUpMenu
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.title = "CliampBar"
        panel.onCancel = { [weak self] in self?.close() }
        card = PlayerCard(store: store, height: 640, onFiles: { [weak self] in self?.openFiles() },
                          onURL: { [weak self] in self?.openURL() }, onMenu: { [weak self] in self?.showMenu() })
        panel.contentView = card
        spectrum.onFrame = { [weak self] bands in self?.card.spectrum.bands = bands }
        NSWorkspace.shared.notificationCenter.addObserver(self, selector: #selector(accessibilityChanged),
            name: NSWorkspace.accessibilityDisplayOptionsDidChangeNotification, object: nil)
        NotificationCenter.default.addObserver(self, selector: #selector(resigned), name: NSWindow.didResignKeyNotification, object: panel)
    }

    func update() {
        let state = store.snapshot
        statusItem.button?.toolTip = state?.currentTrack.map { "\($0.displayTitle) - CliampBar" } ?? "CliampBar"
        if panel.isVisible { card.update() }
        updateSpectrum()
    }

    @objc private func toggle() {
        guard !dialogOpen, !dialogs.stopped else { return }
        if NSApp.currentEvent?.type == .rightMouseUp { showMenu(); return }
        panel.isVisible ? close() : open()
    }

    func open() {
        guard !dialogOpen, !dialogs.stopped, NSApp.modalWindow == nil else { return }
        if panel.isVisible { panel.makeKeyAndOrderFront(nil); return }
        guard let button = statusItem.button, let window = button.window else { return }
        let anchor = window.convertToScreen(button.convert(button.bounds, to: nil))
        let screen = window.screen?.visibleFrame ?? NSScreen.main!.visibleFrame
        let height = min(640, screen.height - 24)
        card.frame.size = NSSize(width: 380, height: height)
        panel.setContentSize(card.frame.size)
        panel.setFrameTopLeftPoint(NSPoint(x: max(screen.minX + 8, min(anchor.midX - 190, screen.maxX - 388)), y: anchor.minY - 6))
        panel.makeKeyAndOrderFront(nil)
        card.update()
        outsideMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { [weak self] _ in
            guard self?.dialogOpen == false else { return }
            self?.close()
        }
        store.setVisible(true)
        updateSpectrum()
    }

    func close() {
        panel.orderOut(nil)
        card.stopAnimations()
        if let outsideMonitor { NSEvent.removeMonitor(outsideMonitor); self.outsideMonitor = nil }
        store.setVisible(false)
        updateSpectrum()
    }

    private func updateSpectrum() {
        let connected: Bool
        if case .ready = store.connection { connected = true } else { connected = false }
        spectrum.update(visible: panel.isVisible, connected: connected, playing: store.snapshot?.isPlaying == true,
                        reduceMotion: NSWorkspace.shared.accessibilityDisplayShouldReduceMotion, executable: store.executable)
    }

    @objc private func accessibilityChanged() {
        if panel.isVisible { card.update() }
        updateSpectrum()
    }

    func shutdown() { dialogs.shutdown(); close(); spectrum.shutdown() }

    deinit {
        spectrum.shutdown()
        NotificationCenter.default.removeObserver(self)
        NSWorkspace.shared.notificationCenter.removeObserver(self)
        if let outsideMonitor { NSEvent.removeMonitor(outsideMonitor) }
    }

    @objc private func resigned() {
        if !dialogOpen { close() }
    }

    private func openFiles() {
        guard !dialogOpen, !dialogs.stopped else { return }
        let picker = NSOpenPanel()
        picker.title = "Add audio to Cliamp"
        picker.prompt = "Add to Queue"
        picker.allowsMultipleSelection = true
        picker.canChooseDirectories = false
        picker.allowedContentTypes = [.audio, .movie]
        if dialogs.run(window: picker, above: panel, runModal: { picker.runModal() }) == .OK {
            store.addFiles(picker.urls.map(\.path))
        }
    }

    private func openURL() {
        guard !dialogOpen, !dialogs.stopped else { return }
        let alert = NSAlert()
        alert.messageText = "Open a stream or music URL"
        alert.informativeText = "Cliamp supports direct audio streams and supported music links. Some services need yt-dlp or account setup."
        alert.addButton(withTitle: "Play")
        alert.addButton(withTitle: "Cancel")
        let input = NSTextField(frame: NSRect(x: 0, y: 0, width: 320, height: 24))
        input.placeholderString = "https://"
        input.setAccessibilityLabel("Music URL")
        alert.accessoryView = input
        alert.window.initialFirstResponder = input
        if dialogs.run(window: alert.window, above: panel, runModal: { alert.runModal() }) == .alertFirstButtonReturn {
            let text = input.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
            if let url = URL(string: text), ["https", "http"].contains(url.scheme?.lowercased() ?? ""), url.host != nil {
                store.perform(.openURL(text))
            } else { store.showMessage("Enter a complete http:// or https:// music URL.") }
        }
    }

    private func showMenu() {
        guard !dialogOpen, !dialogs.stopped, NSApp.modalWindow == nil else { return }
        menuOpen = true
        defer { menuOpen = false }
        let menu = NSMenu()
        let login = menu.addItem(withTitle: "Launch at Login", action: #selector(toggleLogin), keyEquivalent: "")
        login.target = self
        login.state = SMAppService.mainApp.status == .enabled ? .on : .off
        let reconnect = menu.addItem(withTitle: "Reconnect to Cliamp", action: #selector(reconnect), keyEquivalent: "")
        reconnect.target = self
        let configuration = menu.addItem(withTitle: "Open Cliamp Configuration Folder", action: #selector(openConfiguration), keyEquivalent: "")
        configuration.target = self
        let repository = menu.addItem(withTitle: "CliampBar on GitHub", action: #selector(openRepository), keyEquivalent: "")
        repository.target = self
        menu.addItem(.separator())
        menu.addItem(withTitle: "Quit CliampBar (keep music playing)", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        if panel.isVisible {
            menu.popUp(positioning: nil, at: NSPoint(x: 344, y: card.frame.height - 36), in: card)
        } else {
            statusItem.menu = menu
            statusItem.button?.performClick(nil)
            statusItem.menu = nil
        }
    }

    @objc private func reconnect() { store.connect() }
    @objc private func openRepository() { NSWorkspace.shared.open(URL(string: "https://github.com/MahmoudElsayad/cliamp-bar")!) }
    @objc private func openConfiguration() {
        let path = ProcessInfo.processInfo.environment["CLIAMP_CONFIG_DIR"] ?? NSHomeDirectory() + "/.config/cliamp"
        NSWorkspace.shared.open(URL(fileURLWithPath: path, isDirectory: true))
    }
    @objc private func toggleLogin() {
        do {
            if SMAppService.mainApp.status == .enabled { try SMAppService.mainApp.unregister() }
            else {
                try SMAppService.mainApp.register()
                if SMAppService.mainApp.status == .requiresApproval { SMAppService.openSystemSettingsLoginItems() }
            }
        } catch { store.showMessage("macOS could not change Launch at Login: \(error.localizedDescription)") }
    }
}

enum PlayerSection: String {
    case queue, library, links
}

final class PlayerCard: FlippedView {
    private let store: PlayerStore
    private let status = sectionLabel("CONNECTING")
    private let title = label("CliampBar", font: .systemFont(ofSize: 20, weight: .semibold))
    let spectrum = SpectrumView()
    private let artist = label("Your music, in the menu bar.", color: Theme.muted)
    private let elapsed = label("0:00", font: Theme.data, color: Theme.muted)
    private let duration = DurationLabel(frame: .zero)
    private let seek = PlayerSlider(description: "Playback position", min: 0, max: 1)
    private let errorBox = FlippedView()
    private let errorLabel = NSTextField(wrappingLabelWithString: "")
    private let scroll = NSScrollView()
    private let source = NSPopUpButton(frame: .zero, pullsDown: false)
    private let count = label("", font: Theme.data, color: Theme.muted)
    private var section = PlayerSection.queue
    private var listIdentity = ""
    private var play: ActionButton!
    private var previous: ActionButton!
    private var next: ActionButton!
    private var shuffle: ActionButton!
    private var repeatButton: ActionButton!
    private var queueTab: ActionButton!
    private var libraryTab: ActionButton!
    private var linksTab: ActionButton!
    private var addFiles: ActionButton!
    private var addURL: ActionButton!
    private var menuButton: ActionButton!
    private var footerLine: NSView!
    private var listLine: NSView!
    private let reconnect: ActionButton

    init(store: PlayerStore, height: CGFloat, onFiles: @escaping () -> Void, onURL: @escaping () -> Void, onMenu: @escaping () -> Void) {
        self.store = store
        reconnect = ActionButton(symbol: "arrow.clockwise", description: "Reconnect to Cliamp", action: { store.connect() })
        super.init(frame: NSRect(x: 0, y: 0, width: 380, height: height))
        wantsLayer = true
        layer?.backgroundColor = Theme.surface.cgColor
        layer?.borderColor = Theme.border.cgColor
        layer?.borderWidth = 1
        layer?.cornerRadius = 8
        layer?.masksToBounds = true
        appearance = NSAppearance(named: .darkAqua)
        let heading = sectionLabel("CLIAMP")
        put(heading, 16, 16, 190, 16)
        let local = label("LOCAL PLAYER", font: Theme.data, color: Theme.muted)
        put(local, 220, 16, 110, 16)
        put(reconnect, 340, 10, 28, 28)
        _ = line(y: 48)
        put(status, 16, 64, 348, 16)
        title.maximumNumberOfLines = 2
        title.lineBreakMode = .byTruncatingTail
        put(title, 16, 88, 348, 48)
        put(artist, 16, 140, 348, 18)
        put(spectrum, 16, 168, 348, 32)
        put(seek, 14, 214, 352, 20)
        put(elapsed, 16, 238, 170, 14)
        put(duration, 204, 238, 160, 14)
        seek.onChange = { store.perform(.seek($0)) }

        previous = ActionButton(symbol: "backward.end.fill", description: "Previous track", action: { store.perform(.previous) })
        play = ActionButton(symbol: "play.fill", description: "Play", action: { store.perform(.toggle) })
        next = ActionButton(symbol: "forward.end.fill", description: "Next track", action: { store.perform(.next) })
        shuffle = ActionButton(symbol: "shuffle", description: "Toggle shuffle", action: { store.perform(.shuffle) })
        repeatButton = ActionButton(symbol: "repeat", description: "Cycle repeat mode", action: { store.perform(.repeatMode) })
        put(shuffle, 16, 270, 32, 32)
        put(previous, 112, 268, 36, 36)
        put(play, 168, 264, 44, 44)
        play.wantsLayer = true
        play.layer?.backgroundColor = Theme.accent.cgColor
        play.layer?.cornerRadius = 4
        play.contentTintColor = Theme.accentInk
        put(next, 232, 268, 36, 36)
        put(repeatButton, 332, 270, 32, 32)
        listLine = line(y: 324)

        errorBox.wantsLayer = true
        errorBox.layer?.backgroundColor = Theme.errorSurface.cgColor
        errorBox.layer?.cornerRadius = 4
        errorLabel.font = Theme.captionFont
        errorLabel.textColor = Theme.errorText
        errorLabel.maximumNumberOfLines = 2
        errorLabel.lineBreakMode = .byTruncatingTail
        errorBox.addSubview(errorLabel)
        addSubview(errorBox)
        queueTab = ActionButton(title: "QUEUE", description: "Show queue", action: { [weak self] in self?.selectSection(.queue) })
        libraryTab = ActionButton(title: "LIBRARY", description: "Show library", action: { [weak self] in self?.selectSection(.library) })
        addSubview(queueTab)
        addSubview(libraryTab)
        linksTab = ActionButton(title: "LINKS", description: "Show links", action: { [weak self] in self?.selectSection(.links) })
        addSubview(linksTab)
        addSubview(count)
        source.target = self
        source.action = #selector(providerChanged)
        source.font = Theme.body
        source.contentTintColor = Theme.text
        source.setAccessibilityLabel("Music source")
        addSubview(source)
        scroll.drawsBackground = false
        scroll.hasVerticalScroller = true
        scroll.scrollerStyle = .overlay
        scroll.horizontalScrollElasticity = .none
        addSubview(scroll)
        footerLine = line(y: height - 48)
        addFiles = ActionButton(title: " FILES", symbol: "plus", description: "Add audio files", action: onFiles)
        addURL = ActionButton(title: " URL", symbol: "link", description: "Open music URL", action: onURL)
        menuButton = ActionButton(symbol: "gearshape", description: "Settings", action: onMenu)
        addSubview(addFiles)
        addSubview(addURL)
        addSubview(menuButton)
        update()
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    func stopAnimations() { duration.stop() }

    private func put(_ view: NSView, _ x: CGFloat, _ y: CGFloat, _ width: CGFloat, _ height: CGFloat) {
        view.frame = NSRect(x: x, y: y, width: width, height: height)
        addSubview(view)
    }

    private func line(y: CGFloat) -> NSView {
        let view = NSView(frame: NSRect(x: 0, y: y, width: 380, height: 1))
        view.wantsLayer = true
        view.layer?.backgroundColor = Theme.border.cgColor
        addSubview(view)
        return view
    }

    private func selectSection(_ value: PlayerSection) {
        guard section != value else { return }
        section = value
        listIdentity = ""
        scroll.contentView.scroll(to: .zero)
        if value == .library { store.loadPlaylists(provider: store.selectedProvider) }
        update()
    }

    @objc private func providerChanged() {
        guard let key = source.selectedItem?.representedObject as? String else { return }
        store.loadPlaylists(provider: key)
    }

    func update() {
        let state = store.snapshot
        let ready: Bool
        let connectionError: String?
        switch store.connection {
        case .connecting:
            ready = false
            connectionError = nil
            status.stringValue = "CONNECTING TO CLIAMP"
        case .ready:
            ready = true
            connectionError = nil
            status.stringValue = store.busy ? "WORKING" : (state?.state.uppercased() ?? "READY")
        case .unavailable(let error):
            ready = false
            connectionError = error
            status.stringValue = "PLAYER UNAVAILABLE"
        }
        status.attributedStringValue = NSAttributedString(string: status.stringValue, attributes: [
            .font: Theme.label, .foregroundColor: Theme.muted, .kern: 0.88,
        ])
        title.stringValue = state?.currentTrack?.displayTitle ?? "Nothing playing"
        title.toolTip = title.stringValue
        let track = state?.currentTrack
        let fallback = track == nil ? "Choose a track or open your library." : (track?.stream == true ? "Live stream" : "Local audio")
        artist.stringValue = track?.artist ?? track?.album ?? (ready ? fallback : "Your music, in the menu bar.")
        let seconds = state?.position ?? 0
        let length = state?.duration ?? 0
        elapsed.stringValue = formatTime(seconds)
        duration.update(snapshot: state, connected: ready, visible: window?.isVisible == true,
                        reduceMotion: NSWorkspace.shared.accessibilityDisplayShouldReduceMotion)
        if !seek.editing {
            seek.maxValue = max(1, length)
            seek.doubleValue = length > 0 ? min(seconds, length) : 0
        }
        seek.isEnabled = ready && !store.busy && state?.seekable == true && length > 0 && store.capabilities.contains("seek.absolute")
        play.image = NSImage(systemSymbolName: state?.isPlaying == true ? "pause.fill" : "play.fill", accessibilityDescription: state?.isPlaying == true ? "Pause" : "Play")
        play.setAccessibilityLabel(state?.isPlaying == true ? "Pause" : "Play")
        play.toolTip = state?.isPlaying == true ? "Pause" : "Play"
        for (button, operation) in [(play!, "toggle"), (previous!, "prev"), (next!, "next"), (shuffle!, "shuffle"), (repeatButton!, "repeat")] {
            button.isEnabled = ready && !store.busy && store.capabilities.contains(operation)
        }
        shuffle.contentTintColor = state?.shuffle == true ? Theme.accent : Theme.secondary
        shuffle.setAccessibilityValue(state?.shuffle == true ? "On" : "Off")
        let repeating = (state?.repeat ?? "off").lowercased()
        repeatButton.image = NSImage(systemSymbolName: repeating == "one" ? "repeat.1" : "repeat", accessibilityDescription: "Repeat \(repeating)")
        repeatButton.contentTintColor = repeating == "off" ? Theme.secondary : Theme.accent
        repeatButton.toolTip = "Repeat: \(repeating)"
        repeatButton.setAccessibilityValue(repeating)
        reconnect.isEnabled = !store.busy
        addFiles.isEnabled = ready && !store.busy && store.capabilities.contains("queue")
        addURL.isEnabled = ready && !store.busy && store.capabilities.contains("url.load")
        addFiles.setTitle(" FILES")
        addURL.setTitle(" URL")

        let error = connectionError ?? store.message ?? state?.stream_error
        errorBox.isHidden = error == nil || error == ""
        let errorHeight: CGFloat = errorBox.isHidden ? 0 : 56
        errorBox.frame = NSRect(x: 12, y: 332, width: 356, height: 48)
        errorLabel.frame = NSRect(x: 8, y: 7, width: 340, height: 34)
        errorLabel.stringValue = error ?? ""
        errorLabel.toolTip = error
        let top = 336 + errorHeight
        queueTab.frame = NSRect(x: 12, y: top, width: 68, height: 28)
        libraryTab.frame = NSRect(x: 84, y: top, width: 80, height: 28)
        linksTab.frame = NSRect(x: 168, y: top, width: 64, height: 28)
        queueTab.setTitle("QUEUE", color: section == .queue ? Theme.accentText : Theme.muted)
        libraryTab.setTitle("LIBRARY", color: section == .library ? Theme.accentText : Theme.muted)
        linksTab.setTitle("LINKS", color: section == .links ? Theme.accentText : Theme.muted)
        count.frame = NSRect(x: 240, y: top + 7, width: 124, height: 16)
        count.alignment = .right
        switch section {
        case .library:
            count.stringValue = store.libraryBusy ? "LOADING" : "\(store.playlistTotal) \(store.playlistTotal == 1 ? "PLAYLIST" : "PLAYLISTS")"
        case .queue:
            count.stringValue = "\(store.queueTotal) \(store.queueTotal == 1 ? "TRACK" : "TRACKS")"
        case .links:
            count.stringValue = "\(store.recentLinks.count) \(store.recentLinks.count == 1 ? "LINK" : "LINKS")"
        }
        source.isHidden = section != .library
        source.isEnabled = ready && !store.libraryBusy
        source.frame = NSRect(x: 12, y: top + 36, width: 356, height: 28)
        let providerKeys = store.providers.map(\.key)
        let currentKeys = source.itemArray.compactMap { $0.representedObject as? String }
        if providerKeys != currentKeys {
            source.removeAllItems()
            for provider in store.providers {
                source.addItem(withTitle: provider.name)
                source.lastItem?.representedObject = provider.key
            }
        }
        if let index = providerKeys.firstIndex(of: store.selectedProvider) { source.selectItem(at: index) }
        let listTop = top + (section == .library ? 76 : 36)
        scroll.frame = NSRect(x: 1, y: listTop, width: 378, height: max(36, frame.height - 48 - listTop))
        footerLine.frame.origin.y = frame.height - 48
        addFiles.frame = NSRect(x: 12, y: frame.height - 38, width: 88, height: 28)
        addURL.frame = NSRect(x: 112, y: frame.height - 38, width: 80, height: 28)
        menuButton.frame = NSRect(x: 336, y: frame.height - 38, width: 28, height: 28)
        updateList(ready: ready)
    }

    private func updateList(ready: Bool) {
        let identity = "\(section)-\(store.recentLinksRevision)-\(store.capabilities.contains("url.load"))-\(ready)-\(store.busy)-\(store.libraryBusy)-\(store.queueLoading)-\(store.queueRevision ?? -1)-\(store.snapshot?.index ?? -1)-\(store.queue.count)-\(store.selectedProvider)-\(store.playlists.map(\.id))-\(scroll.frame.height)"
        guard identity != listIdentity else { return }
        listIdentity = identity
        let oldPosition = scroll.contentView.bounds.origin
        let list = LibraryList()
        var y: CGFloat = 0
        switch section {
        case .links:
            for link in store.recentLinks {
                let row = RecentLinkRow(link: link, width: 378,
                                        canReplay: ready && !store.busy && store.capabilities.contains("url.load"),
                                        onReplay: { [weak store] in store?.perform(.openURL(link.originalURL)) },
                                        onRemove: { [weak store] in store?.removeRecentLink(link.originalURL) })
                row.frame.origin.y = y
                list.addSubview(row)
                y += row.frame.height
            }
        case .library:
            for playlist in store.playlists {
                let subtitle = playlist.track_count.map { $0 == 1 ? "1 track" : "\($0) tracks" } ?? "Playlist"
                let row = LibraryRow(title: playlist.name, subtitle: subtitle, active: false, width: 378) { [weak store] in
                    store?.perform(.load(provider: store?.selectedProvider ?? "local", playlist: playlist.id))
                }
                row.frame.origin.y = y
                list.addSubview(row)
                y += row.frame.height
            }
        case .queue:
            let revision = store.queueRevision ?? 0
            for (offset, track) in store.queue.enumerated() {
                let index = track.index ?? offset
                let row = LibraryRow(title: track.displayTitle, subtitle: track.artist ?? "Track \(index + 1)",
                                     active: index == (store.snapshot?.index ?? 0), width: 378) { [weak store] in
                    store?.perform(.playQueue(index: index, revision: revision))
                }
                row.frame.origin.y = y
                list.addSubview(row)
                y += row.frame.height
            }
        }
        let more = section == .library ? store.playlists.count < store.playlistTotal
            : section == .queue && store.queue.count < store.queueTotal
        if more {
            let button = ActionButton(title: "LOAD MORE", description: "Load more rows") { [weak self] in
                guard let self else { return }
                if self.section == .library { self.store.loadPlaylists(provider: self.store.selectedProvider, loadMore: true) }
                else { self.store.refreshQueue(loadMore: true) }
            }
            button.setTitle("LOAD MORE")
            button.isEnabled = section == .library ? !store.libraryBusy : !store.queueLoading
            button.frame = NSRect(x: 16, y: y + 8, width: 344, height: 28)
            list.addSubview(button)
            y += 44
        }
        if y == 0 {
            let text = section == .links ? "URLs appear here after successful playback."
                : ready ? (section == .library ? "No playlists in this source." : "Add files or open the library.")
                : "Connect to Cliamp to see your music."
            let empty = label(text, color: Theme.muted)
            empty.frame = NSRect(x: 16, y: 16, width: 344, height: 36)
            list.addSubview(empty)
            y = 68
        }
        list.frame = NSRect(x: 0, y: 0, width: 378, height: max(y, scroll.frame.height))
        scroll.documentView = list
        scroll.contentView.scroll(to: NSPoint(x: 0, y: min(oldPosition.y, max(0, y - scroll.frame.height))))
        scroll.reflectScrolledClipView(scroll.contentView)
        list.synchronizeHover()
    }
}

func formatTime(_ seconds: Double) -> String {
    guard seconds.isFinite, seconds >= 0, seconds < Double(Int.max) else { return "0:00" }
    let value = Int(seconds)
    if value >= 3600 { return String(format: "%d:%02d:%02d", value / 3600, (value / 60) % 60, value % 60) }
    return String(format: "%d:%02d", value / 60, value % 60)
}

private extension Theme {
    static let captionFont = NSFont.systemFont(ofSize: 11)
}

final class SpectrumView: NSView {
    override var isOpaque: Bool { true }
    var bands: [Double] = [] { didSet { needsDisplay = true } }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        setAccessibilityElement(false)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    override func draw(_ dirtyRect: NSRect) {
        Theme.surface.setFill()
        bounds.fill()
        let gap: CGFloat = 5
        let width = (bounds.width - gap * 9) / 10
        let scale = abs(NSGraphicsContext.current?.cgContext.convertToDeviceSpace(CGSize(width: 0, height: 1)).height ?? 1)
        for index in 0..<10 {
            let level = bands.indices.contains(index) ? bands[index] : 0
            let height = (CGFloat(level) * bounds.height * scale).rounded(.down) / scale
            (height == 0 ? Theme.border : Theme.text).setFill()
            NSRect(x: CGFloat(index) * (width + gap), y: 0,
                   width: width, height: height == 0 ? 2 : height).fill()
        }
    }
}
