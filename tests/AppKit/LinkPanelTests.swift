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

private func panelWait(_ description: String, _ predicate: () -> Bool) throws {
    let deadline = Date().addingTimeInterval(10)
    while !predicate() && Date() < deadline { RunLoop.current.run(until: Date().addingTimeInterval(0.02)) }
    if !predicate() { throw CliampError(message: description) }
}

func linkPanelTests() throws {
    let name = "io.cliampbar.link-panel-tests." + UUID().uuidString
    let defaults = UserDefaults(suiteName: name)!
    let fixture = try FakeRuntimePlayer()
    let previous = ProcessInfo.processInfo.environment["CLIAMP_BINARY"]
    setenv("CLIAMP_BINARY", fixture.executable.path, 1)
    defer {
        defaults.removePersistentDomain(forName: name)
        if let previous { setenv("CLIAMP_BINARY", previous, 1) } else { unsetenv("CLIAMP_BINARY") }
    }
    let seed = LinkHistory(defaults: defaults)
    for index in 0..<14 {
        seed.record(RecentLink(originalURL: "https://example.com/\(index)?token=Original#Part", title: "Saved song \(index)",
                               artist: nil, lastOpenedAt: Date(), trackCount: 1))
    }
    let longURL = "https://Example.com/" + String(repeating: "long-path-", count: 80) + "?token=Exact#Original"
    seed.record(RecentLink(originalURL: longURL, title: "A long saved link", artist: nil, lastOpenedAt: Date(), trackCount: 1))
    let store = PlayerStore(defaults: defaults)
    defer { store.shutdown() }
    let card = PlayerCard(store: store, height: 640, onFiles: {}, onURL: {}, onMenu: {})
    store.onChange = { card.update() }
    let tabs = card.subviews.compactMap { $0 as? ActionButton }
    let links = tabs.first { $0.accessibilityLabel() == "Show links" }!
    let queue = tabs.first { $0.accessibilityLabel() == "Show queue" }!
    let library = tabs.first { $0.accessibilityLabel() == "Show library" }!
    let scroll = card.subviews.compactMap { $0 as? NSScrollView }.first!
    func rows() -> [RecentLinkRow] { scroll.documentView!.subviews.compactMap { $0 as? RecentLinkRow } }
    links.performClick(nil)
    expect(rows().count == 15 && scroll.documentView!.frame.height == 15 * 52, "Links use the same 52-point scrollable rows")
    expect([queue, library, links].allSatisfy { $0.frame.maxX < 240 && $0.attributedTitle.size().width < $0.frame.width },
           "All three tabs fit before the count in the 380-point panel")
    let long = rows()[0]
    expect(long.replay.toolTip == longURL && long.replay.accessibilityValue() as? String == longURL
           && long.replay.accessibilityLabel()?.contains(longURL) == true, "The full original URL stays available through tooltip and accessibility")
    expect(!long.replay.isEnabled && long.remove.isEnabled && !long.replay.accessibilityPerformPress(),
           "Offline links stay readable and removable while replay is disabled")
    expect(!long.replay.frame.intersects(long.remove.frame) && long.remove.frame.maxX <= 378,
           "The Remove control cannot overlap the replay target or escape a long URL row")
    let subtitle = long.replay.subviews[1] as! NSTextField
    expect(subtitle.stringValue == longURL && subtitle.lineBreakMode == .byTruncatingTail && subtitle.frame.maxX < long.remove.frame.minX,
           "Long URLs truncate within the row and keep their complete value")
    long.remove.performClick(nil)
    expect(rows().count == 14 && !store.recentLinks.contains { $0.originalURL == longURL }, "Remove updates the offline list and its persisted history")
    expect(!LinkHistory(defaults: defaults).entries.contains { $0.originalURL == longURL }, "Offline removal survives relaunch")
    scroll.contentView.scroll(to: NSPoint(x: 0, y: 312))
    queue.performClick(nil)
    links.performClick(nil)
    expect(scroll.contentView.bounds.origin.y == 0, "Switching sections resets the list to the top")

    var replayed = 0
    var removed = 0
    let isolated = RecentLinkRow(link: seed.entries[0], width: 378, canReplay: true,
                                 onReplay: { replayed += 1 }, onRemove: { removed += 1 })
    isolated.remove.performClick(nil)
    expect(removed == 1 && replayed == 0, "Remove dispatches only its own action")
    expect(isolated.replay.accessibilityPerformPress() && replayed == 1, "A row reopens with one accessible press")

    try fixture.write("url-reply.json", ["ok": true, "job": ["state": "succeeded",
        "result": ["tracks": [["title": "Newest returned title", "path": "resolved-audio"]], "total": 1],
        "snapshot": ["revision": 2, "playlist_revision": 2, "state": "playing", "track": ["path": "resolved-audio"]]]])
    try fixture.write("command-delay.json", 0.3)
    store.connect()
    try panelWait("The panel connects to its fake process") { if case .ready = store.connection { return !store.busy }; return false }
    expect(rows().allSatisfy { $0.replay.isEnabled }, "Available URL support enables reopening")
    let target = store.recentLinks.last!.originalURL
    let count = store.recentLinks.count
    expect(rows().last!.replay.accessibilityPerformPress(), "One row press admits the original URL")
    expect(rows().allSatisfy { !$0.replay.isEnabled && $0.remove.isEnabled }, "Busy playback disables reopening while keeping Remove available")
    try panelWait("Replay completes and refreshes the same-count list") { !store.busy && store.recentLinks.first?.originalURL == target }
    expect(store.recentLinks.count == count && (rows()[0].replay.subviews[0] as? NSTextField)?.stringValue == "Newest returned title",
           "A successful same-count replay refreshes row metadata and MRU order")
    expect(fixture.urlCalls(target).count == 1, "Replay sends the exact original URL once rather than its resolved audio path")
    let beforeRemove = fixture.urlCalls(target).count
    rows()[0].remove.performClick(nil)
    expect(fixture.urlCalls(target).count == beforeRemove && !store.recentLinks.contains { $0.originalURL == target },
           "The live Remove control does not replay its entry")

    try fixture.write("capabilities.json", ["play", "queue.list"])
    store.connect()
    try panelWait("The player reconnects without URL support") { if case .ready = store.connection { return !store.busy }; return false }
    expect(rows().allSatisfy { !$0.replay.isEnabled && $0.remove.isEnabled }, "Unsupported players disable reopening without hiding history")
    store.shutdown()
    card.update()
    expect(rows().allSatisfy { !$0.replay.isEnabled && $0.remove.isEnabled }, "Disconnect preserves readable removable history")
    for row in rows() {
        let name = row.replay.subviews[0] as! NSTextField
        expect(name.textColor == Theme.text && row.replay.subviews[1].frame.maxX <= row.replay.bounds.maxX,
               "Disabled rows preserve readable themed text and contain their labels")
    }
    print("PASS: LINKS layout, long URLs, full accessibility, offline removal, scroll reset, single replay, busy/unsupported states, same-count MRU refresh")
}

func linkHoverTests() {
    let window = fixtureWindow()
    defer { window.close() }
    let scroll = NSScrollView(frame: NSRect(x: 0, y: 0, width: 378, height: 104))
    window.contentView = scroll
    let list = LibraryList(frame: NSRect(x: 0, y: 0, width: 378, height: 260))
    var pointer: NSPoint?
    list.pointerLocation = { _ in pointer }
    let rows = (0..<5).map { index -> RecentLinkRow in
        let link = RecentLink(originalURL: "https://example.com/\(index)", title: "Link \(index)",
                              artist: nil, lastOpenedAt: Date(), trackCount: 1)
        let row = RecentLinkRow(link: link, width: 378, canReplay: index != 2, onReplay: {}, onRemove: {})
        row.frame.origin.y = CGFloat(index * 52)
        list.addSubview(row)
        return row
    }
    scroll.documentView = list
    window.orderFront(nil)
    scroll.contentView.scroll(to: .zero)
    pointer = rows[0].replay.convert(NSPoint(x: 20, y: 26), to: nil)
    list.synchronizeHover()
    expect(rows[0].replay.layer?.backgroundColor == Theme.raised.cgColor, "A nested enabled link highlights under the pointer")
    scroll.contentView.scroll(to: NSPoint(x: 0, y: 52))
    expect(rows[0].replay.layer?.backgroundColor == Theme.surface.cgColor
           && rows[1].replay.layer?.backgroundColor == Theme.raised.cgColor,
           "Scrolling nested links transfers hover under a stationary pointer")
    rows[1].replay.isEnabled = false
    expect(rows[1].replay.layer?.backgroundColor == Theme.surface.cgColor,
           "Disabling a hovered link immediately removes its hover")
    rows[1].replay.updateTrackingAreas()
    expect(rows[1].replay.layer?.backgroundColor == Theme.surface.cgColor, "Tracking updates cannot highlight a disabled link")
    scroll.contentView.scroll(to: NSPoint(x: 0, y: 104))
    expect(rows[2].replay.layer?.backgroundColor == Theme.surface.cgColor,
           "Scrolling an offline link under a stationary pointer cannot highlight it")
    expect(!rows[2].replay.isAccessibilityEnabled() && !rows[2].replay.accessibilityPerformPress(),
           "Disabled nested links expose their disabled accessibility state")
    expect((rows[2].replay.subviews[0] as? NSTextField)?.textColor == Theme.text
           && (rows[2].replay.subviews[1] as? NSTextField)?.textColor == Theme.muted,
           "Disabled nested links preserve readable text")
    rows[2].replay.isEnabled = true
    expect(rows[2].replay.layer?.backgroundColor == Theme.raised.cgColor,
           "Enabling a link synchronizes the stationary pointer")
    print("PASS: nested link stationary-pointer scrolling, disabled hover, readable text, disabled accessibility, re-enable")
}
