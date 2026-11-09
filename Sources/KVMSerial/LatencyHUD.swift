import AppKit

/// Small translucent overlay with live video and serial timing.
final class LatencyHUD: NSTextField {
    init() {
        super.init(frame: .zero)
        isEditable = false
        isSelectable = false
        isBezeled = false
        drawsBackground = true
        backgroundColor = NSColor.black.withAlphaComponent(0.6)
        textColor = .white
        font = .monospacedSystemFont(ofSize: 11, weight: .regular)
        maximumNumberOfLines = 0
        lineBreakMode = .byClipping
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    // Let clicks fall through to the video.
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
}
