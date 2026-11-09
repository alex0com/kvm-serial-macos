import AppKit
import KVMCore

/// Shows the video and turns mouse input over it into absolute CH9329
/// positions. Keyboard input is handled by InputController, which sees key
/// events before AppKit's menu shortcuts do.
@MainActor
final class RemoteView: NSView {
    let renderer: VideoRenderer

    /// Where mouse input goes; nil while capture is off or no port is open.
    var link: HIDLink?
    var hideCursor = true {
        didSet { window?.invalidateCursorRects(for: self) }
    }

    private(set) var videoSize = CGSize.zero
    private var buttons: UInt8 = 0
    private var scrollRemainder: CGFloat = 0

    private static let blankCursor = NSCursor(
        image: NSImage(size: NSSize(width: 1, height: 1)), hotSpot: .zero)

    /// Trackpad points per wheel notch.
    private static let pointsPerNotch: CGFloat = 12

    init(renderer: VideoRenderer) {
        self.renderer = renderer
        super.init(frame: .zero)
        wantsLayer = true
        layerContentsRedrawPolicy = .never
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    override func makeBackingLayer() -> CALayer { renderer.layer }
    override var isFlipped: Bool { true }
    override var isOpaque: Bool { true }
    override var acceptsFirstResponder: Bool { true }
    // The first click on an inactive window only activates it.
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { false }

    func setVideoSize(_ size: CGSize) {
        videoSize = size
        window?.invalidateCursorRects(for: self)
    }

    // MARK: - Layout

    override func layout() {
        super.layout()
        updateDrawableSize()
    }

    override func viewDidChangeBackingProperties() {
        super.viewDidChangeBackingProperties()
        renderer.layer.contentsScale = window?.backingScaleFactor ?? 2
        updateDrawableSize()
    }

    private func updateDrawableSize() {
        let scale = window?.backingScaleFactor ?? 2
        renderer.setDrawableSize(
            CGSize(width: bounds.width * scale, height: bounds.height * scale))
    }

    /// The video's on-screen rect in view coordinates; matches the renderer's
    /// viewport.
    var videoRect: CGRect { aspectFit(videoSize, in: bounds.size) }

    override func resetCursorRects() {
        if hideCursor { addCursorRect(videoRect, cursor: Self.blankCursor) }
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreas.forEach(removeTrackingArea)
        addTrackingArea(NSTrackingArea(
            rect: .zero,
            options: [.mouseMoved, .activeInKeyWindow, .inVisibleRect],
            owner: self))
    }

    // MARK: - Mouse

    /// Absolute CH9329 coordinates for an event, or nil outside the video.
    /// While a button is held the position is clamped instead, so drags can
    /// reach the edges.
    private func absolutePosition(_ event: NSEvent) -> (x: Int, y: Int)? {
        let rect = videoRect
        guard rect.width > 0, rect.height > 0 else { return nil }
        let p = convert(event.locationInWindow, from: nil)
        var nx = (p.x - rect.minX) / rect.width
        var ny = (p.y - rect.minY) / rect.height
        if buttons == 0, !(0..<1).contains(nx) || !(0..<1).contains(ny) { return nil }
        nx = min(max(nx, 0), 1)
        ny = min(max(ny, 0), 1)
        return (
            min(CH9329.absoluteMax, Int(nx * 4096)),
            min(CH9329.absoluteMax, Int(ny * 4096))
        )
    }

    private func move(_ event: NSEvent) {
        guard let link, let pos = absolutePosition(event) else { return }
        link.moveTo(x: pos.x, y: pos.y)
    }

    private func button(_ event: NSEvent, down: Bool) {
        guard let link else { return }
        let bit: UInt8
        switch event.buttonNumber {
        case 0: bit = 0x01
        case 1: bit = 0x02
        case 2: bit = 0x04
        default: return
        }
        if down {
            guard let pos = absolutePosition(event) else { return }
            link.moveTo(x: pos.x, y: pos.y)
            buttons |= bit
        } else {
            guard buttons & bit != 0 else { return }
            if let pos = absolutePosition(event) { link.moveTo(x: pos.x, y: pos.y) }
            buttons &= ~bit
        }
        link.setButtons(buttons)
    }

    /// Release any held buttons (e.g. when capture turns off mid-drag).
    func releaseButtons() {
        guard buttons != 0 else { return }
        buttons = 0
        link?.setButtons(0)
    }

    override func mouseMoved(with event: NSEvent) { move(event) }
    override func mouseDragged(with event: NSEvent) { move(event) }
    override func rightMouseDragged(with event: NSEvent) { move(event) }
    override func otherMouseDragged(with event: NSEvent) { move(event) }

    override func mouseDown(with event: NSEvent) {
        window?.makeFirstResponder(self)
        button(event, down: true)
    }
    override func mouseUp(with event: NSEvent) { button(event, down: false) }
    override func rightMouseDown(with event: NSEvent) { button(event, down: true) }
    override func rightMouseUp(with event: NSEvent) { button(event, down: false) }
    override func otherMouseDown(with event: NSEvent) { button(event, down: true) }
    override func otherMouseUp(with event: NSEvent) { button(event, down: false) }

    // Keep right-clicks for the target rather than showing a context menu.
    override func menu(for event: NSEvent) -> NSMenu? { nil }

    override func scrollWheel(with event: NSEvent) {
        guard let link else { return }
        // scrollingDeltaY already follows the user's natural-scrolling
        // setting, and its sign matches the HID wheel (positive = up).
        let delta = event.hasPreciseScrollingDeltas
            ? event.scrollingDeltaY / Self.pointsPerNotch
            : event.scrollingDeltaY
        scrollRemainder += delta
        let notches = Int(scrollRemainder.rounded(.towardZero))
        scrollRemainder -= CGFloat(notches)
        if event.phase == .ended || event.momentumPhase == .ended { scrollRemainder = 0 }
        link.scroll(notches)
    }
}
