import AppKit

func realModalDialogTests() {
    let parent = KeyPanel(contentRect: NSRect(x: -2000, y: -2000, width: 380, height: 640),
                          styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
    parent.isReleasedWhenClosed = false
    parent.level = .popUpMenu
    parent.orderFront(nil)
    defer { parent.close() }
    let dialogs = PanelDialogSession()

    func present(_ window: NSWindow, name: String, action: @escaping () -> Void,
                 runModal: () -> NSApplication.ModalResponse) -> NSApplication.ModalResponse? {
        let original = window.level
        var observed = false
        var correctLevel = false
        var wasKey = false
        var ownedModal = false
        var rejectedReentry = false
        let timer = Timer(timeInterval: 0.5, repeats: false) { _ in
            observed = true
            wasKey = window.isKeyWindow
            ownedModal = NSApp.modalWindow === window && dialogs.isOpen
            let windows = CGWindowListCopyWindowInfo(.optionAll, kCGNullWindowID) as? [[String: Any]] ?? []
            let layer = windows.first { ($0[kCGWindowNumber as String] as? Int) == window.windowNumber }?[kCGWindowLayer as String] as? Int
            correctLevel = window.level.rawValue > parent.level.rawValue && layer == window.level.rawValue
            print("MODAL: \(name) modal=\(ownedModal) key=\(wasKey) appkit=\(window.level.rawValue) windowServer=\(layer ?? -1) parent=\(parent.level.rawValue)")
            rejectedReentry = dialogs.run(window: window, above: parent, runModal: { .OK }) == nil
            action()
        }
        RunLoop.main.add(timer, forMode: .modalPanel)
        let result = dialogs.run(window: window, above: parent, runModal: runModal)
        timer.invalidate()
        window.orderOut(nil)
        expect(observed && ownedModal, "\(name) was sampled inside its actual AppKit modal loop")
        expect(correctLevel, "\(name) stays above the parent in AppKit and WindowServer during presentation")
        expect(wasKey, "\(name) takes keyboard focus")
        expect(rejectedReentry && !dialogs.isOpen, "\(name) rejects reentry and releases modal ownership")
        expect(window.level == original, "\(name) restores its level after presentation")
        window.level = .normal
        NotificationCenter.default.post(name: NSWindow.didBecomeKeyNotification, object: window)
        expect(window.level == .normal, "\(name) removes its level observer after presentation")
        return result
    }

    let alert = NSAlert()
    alert.messageText = "CliampBar modal regression test"
    alert.addButton(withTitle: "Play")
    alert.addButton(withTitle: "Cancel")
    let input = NSTextField(frame: NSRect(x: 0, y: 0, width: 320, height: 24))
    input.stringValue = "https://example.com/test"
    alert.accessoryView = input
    alert.window.initialFirstResponder = input
    let play = present(alert.window, name: "URL Play", action: {
        expect(alert.window.firstResponder === input.currentEditor(), "The URL input receives keyboard focus")
        alert.buttons[0].performClick(nil)
    }, runModal: { alert.runModal() })
    expect(play == .alertFirstButtonReturn, "The actual Play button keeps its response")
    let cancel = present(alert.window, name: "URL Cancel", action: {
        alert.buttons[1].performClick(nil)
    }, runModal: { alert.runModal() })
    expect(cancel == .alertSecondButtonReturn, "The actual Cancel button keeps its response")

    let picker = NSOpenPanel()
    picker.title = "CliampBar file dialog regression test"
    let cancelled = present(picker, name: "File Cancel", action: { picker.cancel(nil) }, runModal: { picker.runModal() })
    expect(cancelled == .cancel, "The actual file picker cancels")
    let stopped = present(alert.window, name: "URL Shutdown", action: { dialogs.shutdown() }, runModal: { alert.runModal() })
    expect(stopped == .abort && dialogs.stopped, "Shutdown aborts the owned modal loop")
    expect(dialogs.run(window: alert.window, above: parent, runModal: { .OK }) == nil, "Shutdown prevents another modal session")
    print("PASS: actual AppKit modal alert Play/Cancel/input focus, file picker Cancel, WindowServer levels, reentry, observer cleanup, shutdown")
}
