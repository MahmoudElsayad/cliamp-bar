import AppKit

final class AppDelegate: NSObject, NSApplicationDelegate {
    private let store = PlayerStore()
    private var panel: PlayerPanel!

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
        NSApp.appearance = NSAppearance(named: .darkAqua)
        panel = PlayerPanel(store: store)
        store.connect()
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
