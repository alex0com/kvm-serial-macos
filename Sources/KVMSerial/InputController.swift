import AppKit
import ApplicationServices
import Carbon.HIToolbox
import KVMCore

/// Forwards the keyboard to the target while capture is on.
///
/// A local event monitor sees key events before AppKit dispatches them, so
/// Cmd shortcuts reach the target instead of the menu bar, and key-ups that
/// AppKit normally swallows while Cmd is held still arrive. Shortcuts that
/// macOS handles before any app sees them (Cmd-Tab, Cmd-Space, Mission
/// Control) need the optional event tap, which requires the Accessibility
/// permission.
///
/// Ctrl+Option+Esc toggles capture.
@MainActor
final class InputController {
    private enum Kind { case down, up, flags }

    weak var window: NSWindow?
    weak var remoteView: RemoteView?
    var link: HIDLink? {
        didSet { if link == nil { keyboard = KeyboardState(swapCommandControl: swap, isISO: iso) } }
    }

    private(set) var captureEnabled = true
    var onCaptureChange: (() -> Void)?

    private var keyboard: KeyboardState
    private var swallowEscapeUp = false
    private var monitor: Any?
    private var tap: CFMachPort?
    private var tapSource: CFRunLoopSource?

    private var swap: Bool { keyboard.swapCommandControl }
    private var iso: Bool { keyboard.isISO }

    init() {
        keyboard = KeyboardState(
            swapCommandControl: Settings.swapCommandControl, isISO: Self.isISOKeyboard())
    }

    var swapCommandControl: Bool {
        get { keyboard.swapCommandControl }
        set {
            releaseAll()
            keyboard.swapCommandControl = newValue
        }
    }

    /// True when keys should go to the target right now.
    var isActive: Bool {
        captureEnabled && link != nil && NSApp.isActive && window?.isKeyWindow == true
    }

    var systemShortcutsActive: Bool { tap != nil }

    func install() {
        monitor = NSEvent.addLocalMonitorForEvents(matching: [.keyDown, .keyUp, .flagsChanged]) {
            [weak self] event in
            guard let self else { return event }
            let kind: Kind = switch event.type {
            case .keyDown: .down
            case .keyUp: .up
            default: .flags
            }
            let consumed = handle(
                kind: kind, keyCode: event.keyCode,
                flags: UInt64(event.modifierFlags.rawValue),
                isRepeat: kind != .flags && event.isARepeat,
                window: event.window)
            return consumed ? nil : event
        }
        NotificationCenter.default.addObserver(
            forName: NSWindow.didResignKeyNotification, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.releaseAll() }
        }
    }

    func setCaptureEnabled(_ enabled: Bool) {
        guard enabled != captureEnabled else { return }
        if !enabled { releaseAll() }
        captureEnabled = enabled
        onCaptureChange?()
    }

    /// Release all keys and buttons on the target.
    func releaseAll() {
        if let report = keyboard.releaseAll() { link?.sendKeyboard(report) }
        remoteView?.releaseButtons()
    }

    /// Send a fixed sequence of reports, e.g. Ctrl+Alt+Del.
    func send(reports: [[UInt8]]) {
        guard let link else { return }
        releaseAll()
        reports.forEach(link.sendKeyboard)
    }

    // MARK: - Event handling

    /// Returns true if the event was consumed (forwarded or used as hotkey).
    private func handle(
        kind: Kind, keyCode: UInt16, flags: UInt64, isRepeat: Bool, window eventWindow: NSWindow?
    ) -> Bool {
        guard let window, eventWindow == nil || eventWindow === window, window.isKeyWindow else {
            return false
        }

        // Ctrl+Option+Esc toggles capture, whether or not capture is on.
        let ctrlOpt = NSEvent.ModifierFlags.control.rawValue | NSEvent.ModifierFlags.option.rawValue
        if keyCode == HIDKeymap.KeyCode.escape {
            if kind == .down, UInt64(ctrlOpt) & flags == UInt64(ctrlOpt) {
                if !isRepeat { setCaptureEnabled(!captureEnabled) }
                swallowEscapeUp = true
                return true
            }
            if kind == .up, swallowEscapeUp {
                swallowEscapeUp = false
                return true
            }
        }

        guard isActive, let link else { return false }
        switch kind {
        case .down:
            if !isRepeat, let report = keyboard.keyDown(keyCode) { link.sendKeyboard(report) }
        case .up:
            if let report = keyboard.keyUp(keyCode) { link.sendKeyboard(report) }
        case .flags:
            keyboard.flagsChanged(keyCode: keyCode, flags: flags).forEach(link.sendKeyboard)
        }
        return true
    }

    // MARK: - System shortcuts (event tap)

    static var hasAccessibility: Bool { AXIsProcessTrusted() }

    /// Show the system prompt for the Accessibility permission.
    static func requestAccessibility() {
        let key = "AXTrustedCheckOptionPrompt"
        _ = AXIsProcessTrustedWithOptions([key: true] as CFDictionary)
    }

    /// Install or remove the event tap. Returns false if the tap could not be
    /// created (usually: Accessibility permission not granted).
    @discardableResult
    func setSystemShortcutsEnabled(_ enabled: Bool) -> Bool {
        if !enabled {
            if let tap { CGEvent.tapEnable(tap: tap, enable: false) }
            if let tapSource { CFRunLoopRemoveSource(CFRunLoopGetMain(), tapSource, .commonModes) }
            tap = nil
            tapSource = nil
            return true
        }
        guard tap == nil else { return true }
        guard Self.hasAccessibility else { return false }

        let mask = (1 << CGEventType.keyDown.rawValue) | (1 << CGEventType.keyUp.rawValue)
            | (1 << CGEventType.flagsChanged.rawValue)
        let callback: CGEventTapCallBack = { _, type, event, refcon in
            let controller = Unmanaged<InputController>.fromOpaque(refcon!).takeUnretainedValue()
            let keyCode = UInt16(event.getIntegerValueField(.keyboardEventKeycode))
            let flags = event.flags.rawValue
            let isRepeat = event.getIntegerValueField(.keyboardEventAutorepeat) != 0
            // The tap's run loop source is on the main run loop.
            let consumed = MainActor.assumeIsolated {
                controller.handleTap(type: type, keyCode: keyCode, flags: flags, isRepeat: isRepeat)
            }
            return consumed ? nil : Unmanaged.passUnretained(event)
        }
        guard let tap = CGEvent.tapCreate(
            tap: .cgSessionEventTap, place: .headInsertEventTap, options: .defaultTap,
            eventsOfInterest: CGEventMask(mask), callback: callback,
            userInfo: Unmanaged.passUnretained(self).toOpaque())
        else { return false }

        let source = CFMachPortCreateRunLoopSource(nil, tap, 0)
        CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
        CGEvent.tapEnable(tap: tap, enable: true)
        self.tap = tap
        tapSource = source
        return true
    }

    /// Returns true if the event should be swallowed.
    private func handleTap(type: CGEventType, keyCode: UInt16, flags: UInt64, isRepeat: Bool) -> Bool {
        if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
            if let tap { CGEvent.tapEnable(tap: tap, enable: true) }
            return false
        }
        // Only take events while our window is the key window of the active app.
        guard NSApp.isActive, let window, window.isKeyWindow else { return false }
        let kind: Kind = switch type {
        case .keyDown: .down
        case .keyUp: .up
        default: .flags
        }
        return handle(kind: kind, keyCode: keyCode, flags: flags, isRepeat: isRepeat, window: nil)
    }

    // MARK: - Keyboard type

    private static func isISOKeyboard() -> Bool {
        KBGetLayoutType(Int16(LMGetKbdType())) == kKeyboardISO
    }
}
