import AppKit
import QuartzCore

final class DurationLabel: NSView {
    private enum Display: Equatable {
        case time(String), live
    }

    private let textLayer = CATextLayer()
    private var display: Display = .time("0:00")
    private var playbackActive = false
    private var panelVisible = false
    private var reduceMotion = false
    private var closeObserver: NSObjectProtocol?
    private var visibilityObserver: NSKeyValueObservation?

    var stringValue: String { textLayer.string as? String ?? "" }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        textLayer.font = Theme.data
        textLayer.fontSize = Theme.data.pointSize
        textLayer.alignmentMode = .right
        textLayer.truncationMode = .end
        layer?.addSublayer(textLayer)
        setAccessibilityElement(true)
        setAccessibilityRole(.staticText)
        refresh()
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    func update(snapshot: PlayerSnapshot?, connected: Bool, visible: Bool, reduceMotion: Bool) {
        let snapshotLength = snapshot?.duration ?? 0
        let length = snapshotLength > 0 ? snapshotLength : (snapshot?.currentTrack?.duration ?? 0)
        if length > 0 {
            display = .time(formatTime(length))
        } else if snapshot?.currentTrack?.realtime == true && snapshot?.seekable != true {
            display = .live
        } else {
            display = .time(snapshot?.currentTrack == nil ? "0:00" : "--:--")
        }
        playbackActive = connected && snapshot?.isPlaying == true
        panelVisible = visible
        self.reduceMotion = reduceMotion
        refresh()
    }

    func stop() {
        panelVisible = false
        refresh()
    }

    override func layout() {
        super.layout()
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        textLayer.frame = bounds
        CATransaction.commit()
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if let closeObserver { NotificationCenter.default.removeObserver(closeObserver) }
        closeObserver = nil
        visibilityObserver = window?.observe(\.isVisible, options: [.new]) { [weak self] _, _ in self?.refresh() }
        if let window {
            closeObserver = NotificationCenter.default.addObserver(
                forName: NSWindow.willCloseNotification, object: window, queue: nil
            ) { [weak self] _ in self?.stop() }
        }
        refresh()
    }

    override func viewDidChangeBackingProperties() {
        super.viewDidChangeBackingProperties()
        refresh()
    }

    override func viewDidHide() { super.viewDidHide(); refresh() }
    override func viewDidUnhide() { super.viewDidUnhide(); refresh() }

    private func refresh() {
        let live = display == .live
        let text: String
        switch display {
        case .time(let value): text = value
        case .live: text = "LIVE"
        }
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        textLayer.string = text
        textLayer.foregroundColor = (live ? Theme.accent : Theme.muted).cgColor
        textLayer.contentsScale = window?.backingScaleFactor ?? 2
        CATransaction.commit()
        setAccessibilityValue(text)
        let animate = live && playbackActive && panelVisible && !reduceMotion
            && window?.isVisible == true && !isHiddenOrHasHiddenAncestor
        if animate {
            guard textLayer.animation(forKey: "livePulse") == nil else { return }
            let pulse = CAKeyframeAnimation(keyPath: "foregroundColor")
            pulse.values = [Theme.accent.cgColor, Theme.accentText.cgColor, Theme.accent.cgColor]
            pulse.keyTimes = [0, 0.5, 1]
            pulse.timingFunctions = [CAMediaTimingFunction(name: .easeInEaseOut), CAMediaTimingFunction(name: .easeInEaseOut)]
            pulse.duration = 3
            pulse.repeatCount = .infinity
            pulse.beginTime = CACurrentMediaTime()
            textLayer.add(pulse, forKey: "livePulse")
        } else {
            textLayer.removeAnimation(forKey: "livePulse")
        }
    }

    deinit {
        if let closeObserver { NotificationCenter.default.removeObserver(closeObserver) }
    }
}
