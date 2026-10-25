import AppKit

func dialogTests() {
    let parent = fixtureWindow()
    parent.level = .popUpMenu
    let dialogs = PanelDialogSession()
    let alert = NSAlert()
    let original = alert.window.level
    let result = dialogs.run(window: alert.window, above: parent) {
        expect(dialogs.isOpen, "Modal ownership begins before the dialog opens")
        expect(alert.window.level.rawValue == parent.level.rawValue + 1, "The URL alert is above the menu panel")
        expect(parent.level == .popUpMenu, "The parent stays above ordinary apps")
        expect(dialogs.run(window: alert.window, above: parent, runModal: { .OK }) == nil,
               "Reentrant dialog requests are rejected")
        return .cancel
    }
    expect(result == .cancel && !dialogs.isOpen, "Cancellation releases modal ownership")
    expect(alert.window.level == original && !parent.isVisible, "Cleanup restores the dialog level without revealing a hidden parent")
    let picker = NSOpenPanel()
    _ = dialogs.run(window: picker, above: parent) {
        expect(picker.level.rawValue == parent.level.rawValue + 1, "The file picker uses the same dialog ordering")
        return .OK
    }
    dialogs.shutdown()
    expect(dialogs.run(window: alert.window, above: parent, runModal: { .OK }) == nil,
           "Shutdown rejects later dialogs")
    parent.close()
    print("PASS: URL and file dialog levels, modal ownership, reentry, hidden parent, shutdown")
}
