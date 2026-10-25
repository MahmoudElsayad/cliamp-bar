import AppKit
import QuartzCore

func expect(_ condition: @autoclosure () -> Bool, _ message: String) {
    guard condition() else {
        fputs("FAIL: \(message)\n", stderr)
        exit(1)
    }
}

func fixtureWindow() -> NSWindow {
    let window = NSWindow(contentRect: NSRect(x: -2000, y: -2000, width: 320, height: 104),
                          styleMask: [.borderless], backing: .buffered, defer: false)
    window.isReleasedWhenClosed = false
    return window
}

func makeList(pointer: @escaping (NSWindow) -> NSPoint?) -> (LibraryList, [LibraryRow]) {
    let list = LibraryList(frame: NSRect(x: 0, y: 0, width: 320, height: 260))
    list.pointerLocation = pointer
    let rows = (0..<5).map { index -> LibraryRow in
        let row = LibraryRow(title: "Track \(index)", subtitle: "Artist", active: index == 3, width: 320, onSelect: {})
        row.frame.origin.y = CGFloat(index * 52)
        list.addSubview(row)
        return row
    }
    return (list, rows)
}

func hoverTests() {
    let window = fixtureWindow()
    defer { window.close() }
    let scroll = NSScrollView(frame: NSRect(x: 0, y: 0, width: 320, height: 104))
    scroll.drawsBackground = false
    window.contentView = scroll
    var pointer: NSPoint?
    let (list, rows) = makeList { _ in pointer }
    scroll.documentView = list
    window.orderFront(nil)
    scroll.contentView.scroll(to: .zero)
    pointer = rows[0].convert(NSPoint(x: 20, y: 26), to: nil)
    list.synchronizeHover()
    expect(rows[0].layer?.backgroundColor == Theme.raised.cgColor, "The initial row highlights under the pointer")
    expect((rows[0].subviews[1] as? NSTextField)?.textColor == Theme.secondary, "Hovered metadata stays readable")

    scroll.contentView.scroll(to: NSPoint(x: 0, y: 52))
    scroll.reflectScrolledClipView(scroll.contentView)
    expect(rows[1].layer?.backgroundColor == Theme.raised.cgColor,
           "Stationary pointer highlights the row underneath after scrolling")
    expect(rows[0].layer?.backgroundColor == Theme.surface.cgColor,
           "The old hovered row returns to an explicit normal fill")
    expect((rows[0].subviews[1] as? NSTextField)?.textColor == Theme.muted, "The old row restores normal metadata")
    rows[1].updateTrackingAreas()
    expect(rows[1].layer?.backgroundColor == Theme.raised.cgColor, "Tracking-area rebuild preserves the current hover")
    _ = rows[1].becomeFirstResponder()
    expect(rows[1].layer?.borderWidth == 1 && rows[1].layer?.borderColor == Theme.accent.cgColor,
           "Keyboard focus has a distinct border")

    scroll.contentView.scroll(to: NSPoint(x: 0, y: 156))
    expect(rows[1].layer?.backgroundColor == Theme.surface.cgColor && rows[1].layer?.borderWidth == 1,
           "Scroll clears hover without erasing keyboard focus")
    expect(rows[3].layer?.backgroundColor == Theme.accentSurface.cgColor, "The playing row keeps its accent wash under the pointer")
    expect((rows[3].subviews[1] as? NSTextField)?.textColor == Theme.accentText, "Playing metadata keeps its accent color")
    _ = rows[1].resignFirstResponder()

    scroll.contentView.scroll(to: NSPoint(x: 0, y: 78))
    pointer = rows[1].convert(NSPoint(x: 20, y: 10), to: nil)
    list.synchronizeHover()
    expect(rows[1].layer?.backgroundColor == Theme.surface.cgColor, "The clipped portion of a row cannot hover")
    pointer = rows[1].convert(NSPoint(x: 20, y: 40), to: nil)
    list.synchronizeHover()
    expect(rows[1].layer?.backgroundColor == Theme.raised.cgColor, "The visible portion of a clipped row can hover")
    pointer = NSPoint(x: 1000, y: 1000)
    list.synchronizeHover()
    expect(rows[1].layer?.backgroundColor == Theme.surface.cgColor, "Leaving the list clears hover")

    scroll.contentView.scroll(to: .zero)
    pointer = rows[0].convert(NSPoint(x: 20, y: 26), to: nil)
    let (replacement, newRows) = makeList { _ in pointer }
    scroll.documentView = replacement
    scroll.contentView.scroll(to: NSPoint(x: 0, y: 52))
    replacement.synchronizeHover()
    expect(newRows[1].layer?.backgroundColor == Theme.raised.cgColor, "Rebuilt rows use the stationary pointer and restored scroll offset")
    scroll.contentView.scroll(to: NSPoint(x: 0, y: 104))
    expect(newRows[1].layer?.backgroundColor == Theme.surface.cgColor && newRows[2].layer?.backgroundColor == Theme.raised.cgColor,
           "The replacement list observes later clip-view movement")
    scroll.contentView.scroll(to: .zero)
    pointer = newRows[0].convert(NSPoint(x: 20, y: 26), to: nil)
    replacement.synchronizeHover()
    window.orderOut(nil)
    expect(newRows[0].layer?.backgroundColor == Theme.surface.cgColor,
           "Closing the panel clears the hovered row without changing the queue")
    pointer = newRows[1].convert(NSPoint(x: 20, y: 26), to: nil)
    window.orderFront(nil)
    expect(newRows[0].layer?.backgroundColor == Theme.surface.cgColor && newRows[1].layer?.backgroundColor == Theme.raised.cgColor,
           "Reopening an unchanged queue synchronizes the new pointer position")
    pointer = nil
    replacement.synchronizeHover()
    expect(newRows[1].layer?.backgroundColor == Theme.surface.cgColor, "A missing pointer clears hover")
    print("PASS: stationary-pointer scrolling, explicit fills, clipping, active row, focus, row rebuild, reopen")
}

func snapshot(state: String = "playing", duration: Double = 0, track: String = "\"stream\":true,\"realtime\":true",
              seekable: Bool = false) throws -> PlayerSnapshot {
    let json = """
    {"revision":1,"playlist_revision":1,"state":"\(state)","duration":\(duration),"seekable":\(seekable),"track":{\(track)}}
    """
    return try JSONDecoder().decode(PlayerSnapshot.self, from: Data(json.utf8))
}

func durationTests() throws {
    let window = fixtureWindow()
    let container = NSView(frame: NSRect(x: 0, y: 0, width: 320, height: 104))
    let duration = DurationLabel(frame: NSRect(x: 0, y: 0, width: 160, height: 14))
    container.addSubview(duration)
    window.contentView = container
    let textLayer = duration.layer!.sublayers!.first as! CATextLayer
    func pulse() -> CAAnimation? { textLayer.animation(forKey: "livePulse") }
    func update(_ state: PlayerSnapshot?, connected: Bool = true, visible: Bool = true, reduceMotion: Bool = false) {
        duration.update(snapshot: state, connected: connected, visible: visible, reduceMotion: reduceMotion)
    }
    let live = try snapshot()
    expect(live.currentTrack?.realtime == true, "Realtime metadata decodes from a player snapshot")
    update(live)
    expect(pulse() == nil, "A hidden native window never starts a pulse")
    window.orderFront(nil)
    update(live)
    expect(duration.stringValue == "LIVE" && pulse()?.duration == 3, "Visible live playback starts a slow native pulse")
    let firstStart = pulse()!.beginTime
    update(live)
    expect(pulse()?.beginTime == firstStart, "Repeated state updates do not restart the pulse")
    let colors = (pulse() as? CAKeyframeAnimation)?.values as? [CGColor]
    expect(colors == [Theme.accent.cgColor, Theme.accentText.cgColor, Theme.accent.cgColor],
           "The foreground pulses between opaque, legible theme colors")
    expect(textLayer.opacity == 1, "The LIVE word never fades out")
    update(live, reduceMotion: true)
    expect(pulse() == nil && textLayer.foregroundColor == Theme.accent.cgColor, "Reduce Motion keeps LIVE static in accent orange")
    update(try snapshot(state: "paused"))
    expect(pulse() == nil && duration.stringValue == "LIVE", "Paused live audio stops and resets the pulse")
    update(live, connected: false)
    expect(pulse() == nil, "A disconnected snapshot cannot animate")
    update(live, visible: false)
    expect(pulse() == nil, "Closing the panel stops the pulse")
    update(try snapshot(duration: 123))
    expect(duration.stringValue == "2:03" && pulse() == nil && textLayer.foregroundColor == Theme.muted.cgColor,
           "Finite audio restores a static duration")
    update(try snapshot(track: "\"duration\":65,\"realtime\":true"))
    expect(duration.stringValue == "1:05" && pulse() == nil, "A known track duration prevents a false LIVE label")
    for track in ["\"path\":\"/music.wav\"", "\"stream\":true", "\"stream\":true,\"realtime\":false"] {
        update(try snapshot(track: track))
        expect(duration.stringValue == "--:--" && pulse() == nil, "Unknown or nonlive audio cannot claim LIVE")
    }
    update(try snapshot(seekable: true))
    expect(duration.stringValue == "--:--" && pulse() == nil, "Seekable audio cannot claim a realtime broadcast")
    update(nil)
    expect(duration.stringValue == "0:00" && pulse() == nil, "An empty player restores the empty duration")
    update(live)
    container.isHidden = true
    expect(pulse() == nil, "Hiding an ancestor stops the pulse")
    container.isHidden = false
    expect(pulse() != nil, "Showing an eligible view resumes the pulse")
    window.orderOut(nil)
    RunLoop.current.run(until: Date().addingTimeInterval(0.1))
    expect(pulse() == nil, "Ordering the native window out stops the pulse")
    window.orderFront(nil)
    update(live)
    duration.stop()
    expect(pulse() == nil, "Explicit panel shutdown removes the native animation")
    update(live)
    window.close()
    expect(pulse() == nil, "Closing the native window removes the animation")
    print("PASS: native LIVE colors, eligibility, pause, visibility, Reduce Motion, idempotence, window cleanup")
}

let app = NSApplication.shared
app.setActivationPolicy(.prohibited)
hoverTests()
do {
    dialogTests()
    try spectrumRenderingTests()
    try durationTests()
    try mediaControlsTests()
} catch {
    fputs("FAIL: \(error)\n", stderr)
    exit(1)
}
