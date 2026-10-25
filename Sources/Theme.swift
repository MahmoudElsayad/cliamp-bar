import AppKit
import QuartzCore

// Shared palette and typography with VoxtypeOSD.
enum Theme {
    static let surface = NSColor(hex: 0x31302E)
    static let raised = NSColor(hex: 0x3A3935)
    static let border = NSColor(hex: 0x45423C)
    static let text = NSColor(hex: 0xEDE1BB)
    static let secondary = NSColor(hex: 0xCDC1A2)
    static let muted = NSColor(hex: 0xAA9E8A)
    static let accent = NSColor(hex: 0xEC8743)
    static let accentText = NSColor(hex: 0xF3C8A4)
    static let accentSurface = NSColor(hex: 0x4A3A2E)
    static let accentInk = NSColor(hex: 0x1A1814)
    static let errorText = NSColor(hex: 0xF5E9D6)
    static let errorSurface = NSColor(hex: 0x3D2A26)
    static let label = NSFont.systemFont(ofSize: 11, weight: .medium)
    static let body = NSFont.systemFont(ofSize: 13)
    static let data = NSFont.monospacedDigitSystemFont(ofSize: 11, weight: .regular)
}

extension NSColor {
    convenience init(hex: UInt32) {
        self.init(srgbRed: CGFloat((hex >> 16) & 0xFF) / 255,
                  green: CGFloat((hex >> 8) & 0xFF) / 255,
                  blue: CGFloat(hex & 0xFF) / 255, alpha: 1)
    }
}

final class ActionButton: NSButton {
    var onClick: () -> Void = {}
    init(title: String = "", symbol: String? = nil, description: String, action: @escaping () -> Void) {
        super.init(frame: .zero)
        onClick = action
        self.title = title
        isBordered = false
        font = Theme.label
        contentTintColor = Theme.secondary
        if let symbol {
            image = NSImage(systemSymbolName: symbol, accessibilityDescription: description)
            imagePosition = title.isEmpty ? .imageOnly : .imageLeading
            symbolConfiguration = NSImage.SymbolConfiguration(pointSize: 14, weight: .regular)
        }
        toolTip = description
        setAccessibilityLabel(description)
        target = self
        self.action = #selector(clicked)
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }
    @objc private func clicked() { onClick() }

    func setTitle(_ value: String, color: NSColor = Theme.secondary) {
        attributedTitle = NSAttributedString(string: value, attributes: [
            .font: Theme.label, .foregroundColor: color, .kern: 0.7,
        ])
    }
}

final class PlayerSlider: NSSlider {
    var onChange: (Double) -> Void = { _ in }
    var editing = false
    init(description: String, min: Double, max: Double) {
        super.init(frame: .zero)
        cell = WarmSliderCell()
        minValue = min
        maxValue = max
        isContinuous = false
        controlSize = .small
        setAccessibilityLabel(description)
        target = self
        action = #selector(changed)
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }
    override func mouseDown(with event: NSEvent) {
        editing = true
        super.mouseDown(with: event)
        editing = false
    }
    @objc private func changed() { onChange(doubleValue) }
}

private final class WarmSliderCell: NSSliderCell {
    override func drawBar(inside rect: NSRect, flipped: Bool) {
        let track = NSRect(x: rect.minX, y: rect.midY - 2, width: rect.width, height: 4)
        Theme.border.setFill()
        NSBezierPath(roundedRect: track, xRadius: 2, yRadius: 2).fill()
        let fraction = maxValue > minValue ? (doubleValue - minValue) / (maxValue - minValue) : 0
        let filled = NSRect(x: track.minX, y: track.minY, width: track.width * fraction, height: track.height)
        (isEnabled ? Theme.accent : Theme.muted).setFill()
        NSBezierPath(roundedRect: filled, xRadius: 2, yRadius: 2).fill()
    }
    override func drawKnob(_ knobRect: NSRect) {
        (isEnabled ? Theme.text : Theme.muted).setFill()
        let knob = NSRect(x: knobRect.midX - 5, y: knobRect.midY - 5, width: 10, height: 10)
        NSBezierPath(ovalIn: knob).fill()
    }
}

func label(_ text: String, font: NSFont = Theme.body, color: NSColor = Theme.text) -> NSTextField {
    let field = NSTextField(labelWithString: text)
    field.font = font
    field.textColor = color
    field.lineBreakMode = .byTruncatingTail
    return field
}

func sectionLabel(_ text: String) -> NSTextField {
    let field = label(text, font: Theme.label, color: Theme.muted)
    field.attributedStringValue = NSAttributedString(string: text, attributes: [
        .font: Theme.label, .foregroundColor: Theme.muted, .kern: 0.88,
    ])
    return field
}

class FlippedView: NSView {
    override var isFlipped: Bool { true }
}

final class LibraryList: FlippedView {
    var pointerLocation: (NSWindow) -> NSPoint? = { $0.mouseLocationOutsideOfEventStream }
    private var clipObserver: NSObjectProtocol?
    private var visibilityObserver: NSKeyValueObservation?

    override func viewDidMoveToSuperview() {
        super.viewDidMoveToSuperview()
        if let clipObserver { NotificationCenter.default.removeObserver(clipObserver) }
        clipObserver = nil
        if let clip = enclosingScrollView?.contentView {
            clip.postsBoundsChangedNotifications = true
            clipObserver = NotificationCenter.default.addObserver(
                forName: NSView.boundsDidChangeNotification, object: clip, queue: nil
            ) { [weak self] _ in self?.synchronizeHover() }
        }
        synchronizeHover()
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        visibilityObserver = window?.observe(\.isVisible, options: [.new]) { [weak self] _, _ in
            self?.synchronizeHover()
        }
        synchronizeHover()
    }

    fileprivate var currentPointer: NSPoint? {
        guard let window, window.isVisible else { return nil }
        return pointerLocation(window)
    }

    func synchronizeHover() {
        let point = currentPointer
        for case let row as LibraryRow in subviews { row.synchronizeHover(at: point) }
    }

    deinit {
        if let clipObserver { NotificationCenter.default.removeObserver(clipObserver) }
    }
}

final class LibraryRow: NSView {
    override var isFlipped: Bool { true }
    override var acceptsFirstResponder: Bool { true }
    private var tracking: NSTrackingArea?
    private let detail: NSTextField
    private let onSelect: () -> Void
    private let active: Bool

    init(title: String, subtitle: String, active: Bool, width: CGFloat, onSelect: @escaping () -> Void) {
        self.active = active
        self.onSelect = onSelect
        detail = label(subtitle, font: Theme.data, color: active ? Theme.accentText : Theme.muted)
        super.init(frame: NSRect(x: 0, y: 0, width: width, height: 52))
        wantsLayer = true
        setAccessibilityElement(true)
        setAccessibilityRole(.button)
        setAccessibilityLabel("\(title), \(subtitle)")
        let name = label(title, color: active ? Theme.accentText : Theme.text)
        name.frame = NSRect(x: 16, y: 8, width: width - 52, height: 18)
        detail.frame = NSRect(x: 16, y: 29, width: width - 48, height: 14)
        addSubview(name)
        addSubview(detail)
        let mark = label(active ? "▶" : "", font: Theme.data, color: Theme.accentText)
        mark.frame = NSRect(x: width - 30, y: 18, width: 16, height: 16)
        addSubview(mark)
        let divider = NSView(frame: NSRect(x: 16, y: 51, width: width - 32, height: 1))
        divider.wantsLayer = true
        divider.layer?.backgroundColor = Theme.raised.cgColor
        addSubview(divider)
        layer?.backgroundColor = active ? Theme.accentSurface.cgColor : Theme.surface.cgColor
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }
    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let tracking { removeTrackingArea(tracking) }
        let area = NSTrackingArea(rect: .zero, options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect], owner: self)
        tracking = area
        addTrackingArea(area)
        synchronizeHover(at: (superview as? LibraryList)?.currentPointer)
    }
    override func mouseEntered(with event: NSEvent) {
        synchronizeHover(at: (superview as? LibraryList)?.currentPointer)
    }
    override func mouseExited(with event: NSEvent) {
        synchronizeHover(at: (superview as? LibraryList)?.currentPointer)
    }
    fileprivate func synchronizeHover(at windowPoint: NSPoint?) {
        let hovered = windowPoint.map {
            let point = convert($0, from: nil)
            return !isHiddenOrHasHiddenAncestor && bounds.contains(point) && visibleRect.contains(point)
        } ?? false
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        layer?.backgroundColor = (active ? Theme.accentSurface : (hovered ? Theme.raised : Theme.surface)).cgColor
        detail.textColor = active ? Theme.accentText : (hovered ? Theme.secondary : Theme.muted)
        CATransaction.commit()
    }
    override func mouseUp(with event: NSEvent) { onSelect() }
    override func keyDown(with event: NSEvent) {
        if event.keyCode == 36 || event.keyCode == 49 { onSelect() }
        else { super.keyDown(with: event) }
    }
    override func accessibilityPerformPress() -> Bool { onSelect(); return true }
    override func becomeFirstResponder() -> Bool {
        layer?.borderColor = Theme.accent.cgColor
        layer?.borderWidth = 1
        return true
    }
    override func resignFirstResponder() -> Bool {
        layer?.borderWidth = 0
        return true
    }
}
