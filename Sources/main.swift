import AppKit

final class AppDelegate: NSObject, NSApplicationDelegate {
    private let store = PlayerStore()
    private var panel: PlayerPanel!
    private var media: SystemMediaControls!
    private var terminationSignal: DispatchSourceSignal?

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
        NSApp.appearance = NSAppearance(named: .darkAqua)
        panel = PlayerPanel(store: store)
        media = SystemMediaControls { [weak self] command in
            self?.store.perform(command, queueIfBusy: true) ?? false
        }
        store.onChange = { [weak self] in
            guard let self else { return }
            self.panel.update()
            let connected: Bool
            if case .ready = self.store.connection { connected = true } else { connected = false }
            self.media.update(snapshot: self.store.snapshot, connected: connected, capabilities: self.store.capabilities)
        }
        // A caught signal resets on exec, so Cliamp children keep normal SIGTERM behavior.
        signal(SIGTERM) { _ in }
        let source = DispatchSource.makeSignalSource(signal: SIGTERM, queue: .main)
        source.setEventHandler { NSApp.terminate(nil) }
        source.resume()
        terminationSignal = source
        store.connect()
    }

    func applicationWillTerminate(_ notification: Notification) {
        media.shutdown()
        panel.shutdown()
        store.shutdown()
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        panel.open()
        return true
    }
}

let application = NSApplication.shared
let delegate = AppDelegate()
application.delegate = delegate
application.run()
