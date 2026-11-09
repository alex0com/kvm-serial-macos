import Foundation

/// Anything that can transmit a packet. `send` must block until the packet
/// has been transmitted: that back-pressure is what keeps mouse moves from
/// queueing up behind a slow serial line.
public protocol PacketSink: AnyObject, Sendable {
    func send(_ bytes: [UInt8]) throws
}

/// Drives a CH9329 from a dedicated sender thread.
///
/// Keyboard reports, button changes, scrolls and raw commands go through one
/// ordered queue and are never dropped. Mouse moves are not queued: only the
/// latest position is kept, and it is sent whenever the line is free. However
/// fast the input arrives, at most one move is ever waiting, so the cursor
/// on the target never lags behind a backlog.
///
/// macOS targets only drag windows on relative motion: absolute moves with a
/// button held move the pointer but not the window. With `relativeDragScale`
/// set, presses still go out as absolute reports (macOS ignores presses on
/// the relative report), but motion while a button is held is sent as
/// relative deltas, and the release snaps the pointer back to the absolute
/// position.
public final class HIDLink: @unchecked Sendable {
    public struct Stats: Sendable {
        public var packetsSent = 0
        public var bytesSent = 0
        public var movesSent = 0
        public var movesCoalesced = 0
        public var errors = 0

        public init() {}
    }

    private enum Event {
        case keyboard([UInt8])
        case button(UInt8, x: Int, y: Int)
        case relative(dx: Int, dy: Int, buttons: UInt8)
        case scroll(Int)
        case raw([UInt8])
    }

    private let sink: PacketSink
    private let condition = NSCondition()
    private var queue: [Event] = []
    private var pendingMove: (x: Int, y: Int)?
    /// Unsent relative drag motion, in target pixels.
    private var pendingDelta = (x: 0.0, y: 0.0)
    private var dragScale: (x: Double, y: Double)?
    private var buttons: UInt8 = 0
    private var position = (x: 0, y: 0)
    private var stopped = false
    private var stats = Stats()
    private var thread: Thread?

    /// Called on the sender thread when a write fails.
    public var onError: (@Sendable (Error) -> Void)?

    public init(sink: PacketSink) {
        self.sink = sink
    }

    public func start() {
        let thread = Thread { [self] in run() }
        thread.name = "HIDLink sender"
        thread.qualityOfService = .userInteractive
        self.thread = thread
        thread.start()
    }

    public func stop() {
        condition.lock()
        stopped = true
        condition.broadcast()
        condition.unlock()
    }

    public var currentStats: Stats {
        condition.lock()
        defer { condition.unlock() }
        return stats
    }

    /// Target pixels per absolute unit (video size / 4096) to send drags as
    /// relative motion, or nil to drag with absolute moves.
    public var relativeDragScale: (x: Double, y: Double)? {
        get {
            condition.lock()
            defer { condition.unlock() }
            return dragScale
        }
        set {
            condition.lock()
            dragScale = newValue
            condition.unlock()
        }
    }

    // MARK: - Input API (any thread)

    public func sendKeyboard(_ report: [UInt8]) {
        enqueue(.keyboard(report))
    }

    /// Move to an absolute position in CH9329 space (0..4095).
    public func moveTo(x: Int, y: Int) {
        condition.lock()
        if buttons != 0, let scale = dragScale {
            pendingDelta.x += Double(x - position.x) * scale.x
            pendingDelta.y += Double(y - position.y) * scale.y
        } else {
            if pendingMove != nil { stats.movesCoalesced += 1 }
            pendingMove = (x, y)
        }
        position = (x, y)
        condition.signal()
        condition.unlock()
    }

    /// Set the held-button bitmask (left 0x1, right 0x2, middle 0x4). The
    /// change is sent at the current position so clicks land where the
    /// pointer is.
    public func setButtons(_ newButtons: UInt8) {
        condition.lock()
        if buttons != 0, dragScale != nil {
            // Finish the relative drag: send the remaining motion, then update
            // the relative report's buttons so it doesn't stay held.
            while let step = takeDeltaStep() {
                queue.append(.relative(dx: step.dx, dy: step.dy, buttons: buttons))
            }
            pendingDelta = (0, 0)
            queue.append(.relative(dx: 0, dy: 0, buttons: newButtons))
        }
        buttons = newButtons
        // The button packet carries the latest position, so any pending move
        // is superseded by it.
        if pendingMove != nil { stats.movesCoalesced += 1 }
        pendingMove = nil
        queue.append(.button(newButtons, x: position.x, y: position.y))
        condition.signal()
        condition.unlock()
    }

    /// Scroll by whole wheel notches (positive = up). Adjacent scrolls in the
    /// queue are merged.
    public func scroll(_ notches: Int) {
        guard notches != 0 else { return }
        condition.lock()
        if case .scroll(let n) = queue.last {
            queue[queue.count - 1] = .scroll(n + notches)
        } else {
            queue.append(.scroll(notches))
        }
        condition.signal()
        condition.unlock()
    }

    /// Send a pre-framed packet in order with other events.
    public func sendRaw(_ packet: [UInt8]) {
        enqueue(.raw(packet))
    }

    private var hasDeltaStep: Bool {
        abs(pendingDelta.x) >= 1 || abs(pendingDelta.y) >= 1
    }

    /// Whole-pixel part of the pending drag motion, at most one report's
    /// worth (±127). Call with the lock held.
    private func takeDeltaStep() -> (dx: Int, dy: Int)? {
        let dx = max(-127, min(127, Int(pendingDelta.x.rounded(.towardZero))))
        let dy = max(-127, min(127, Int(pendingDelta.y.rounded(.towardZero))))
        guard dx != 0 || dy != 0 else { return nil }
        pendingDelta.x -= Double(dx)
        pendingDelta.y -= Double(dy)
        return (dx, dy)
    }

    private func enqueue(_ event: Event) {
        condition.lock()
        queue.append(event)
        condition.signal()
        condition.unlock()
    }

    // MARK: - Sender thread

    private func nextPacket() -> (packet: [UInt8], isMove: Bool)? {
        condition.lock()
        defer { condition.unlock() }
        while queue.isEmpty && pendingMove == nil && !hasDeltaStep && !stopped {
            condition.wait()
        }
        if stopped { return nil }

        if !queue.isEmpty {
            switch queue.removeFirst() {
            case .keyboard(let report):
                return (CH9329.keyboard(report), false)
            case .button(let b, let x, let y):
                return (CH9329.mouseAbsolute(buttons: b, x: x, y: y), false)
            case .relative(let dx, let dy, let b):
                return (CH9329.mouseRelative(buttons: b, dx: dx, dy: dy), false)
            case .scroll(let n):
                let step = max(-127, min(127, n))
                if step != n { queue.insert(.scroll(n - step), at: 0) }
                return (CH9329.mouseRelative(buttons: buttons, wheel: step), false)
            case .raw(let packet):
                return (packet, false)
            }
        }
        if let step = takeDeltaStep() {
            return (CH9329.mouseRelative(buttons: buttons, dx: step.dx, dy: step.dy), true)
        }
        let move = pendingMove!
        pendingMove = nil
        return (CH9329.mouseAbsolute(buttons: buttons, x: move.x, y: move.y), true)
    }

    private func run() {
        while let (packet, isMove) = nextPacket() {
            do {
                try sink.send(packet)
                condition.lock()
                stats.packetsSent += 1
                stats.bytesSent += packet.count
                if isMove { stats.movesSent += 1 }
                condition.unlock()
            } catch {
                condition.lock()
                stats.errors += 1
                condition.unlock()
                onError?(error)
            }
        }
    }
}
