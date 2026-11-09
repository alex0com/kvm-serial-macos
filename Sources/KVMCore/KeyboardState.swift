// Tracks held keys and modifiers and produces full 8-byte boot keyboard
// reports. Every state change yields a complete report, so releasing one key
// while another is still held keeps the other key held on the target.

public struct KeyboardState: Sendable {
    /// Device-dependent modifier bits carried in NSEvent.modifierFlags and
    /// CGEventFlags (IOKit NX_DEVICE*KEYMASK). These tell left and right apart.
    public enum DeviceFlag {
        public static let leftControl: UInt64 = 0x0000_0001
        public static let leftShift: UInt64 = 0x0000_0002
        public static let rightShift: UInt64 = 0x0000_0004
        public static let leftCommand: UInt64 = 0x0000_0008
        public static let rightCommand: UInt64 = 0x0000_0010
        public static let leftOption: UInt64 = 0x0000_0020
        public static let rightOption: UInt64 = 0x0000_0040
        public static let rightControl: UInt64 = 0x0000_2000
    }

    /// Device-independent modifier masks (NSEvent.ModifierFlags / CGEventFlags).
    enum GenericFlag {
        static let shift: UInt64 = 0x0002_0000
        static let control: UInt64 = 0x0004_0000
        static let option: UInt64 = 0x0008_0000
        static let command: UInt64 = 0x0010_0000
    }

    public static let maxKeys = 6

    /// Map Mac Command to HID Control and Mac Control to HID GUI, so that
    /// e.g. Cmd+C copies on a Windows or Linux target. Off by default: Ctrl
    /// is sent as Ctrl and Command as GUI (Windows key), as in kvm-serial.
    public var swapCommandControl: Bool
    public var isISO: Bool

    public private(set) var modifiers: UInt8 = 0
    public private(set) var keys: [UInt8] = []

    public init(swapCommandControl: Bool = false, isISO: Bool = false) {
        self.swapCommandControl = swapCommandControl
        self.isISO = isISO
    }

    public var report: [UInt8] {
        var r: [UInt8] = [modifiers, 0, 0, 0, 0, 0, 0, 0]
        for (i, key) in keys.prefix(Self.maxKeys).enumerated() {
            r[2 + i] = key
        }
        return r
    }

    /// Returns the new report, or nil if nothing changed (unmapped key,
    /// already held, or rollover full).
    public mutating func keyDown(_ keyCode: UInt16) -> [UInt8]? {
        guard let usage = HIDKeymap.usage(for: keyCode, isISO: isISO),
            !keys.contains(usage), keys.count < Self.maxKeys
        else { return nil }
        keys.append(usage)
        return report
    }

    public mutating func keyUp(_ keyCode: UInt16) -> [UInt8]? {
        guard let usage = HIDKeymap.usage(for: keyCode, isISO: isISO),
            let index = keys.firstIndex(of: usage)
        else { return nil }
        keys.remove(at: index)
        return report
    }

    /// Handle a flagsChanged event. Returns the reports to send, in order.
    ///
    /// The modifier byte is recomputed from the full flag word each time
    /// rather than toggled per event, so a missed event cannot leave a
    /// modifier stuck. Caps Lock is a toggle on macOS: every change is sent to
    /// the target as a press followed by a release.
    public mutating func flagsChanged(keyCode: UInt16, flags: UInt64) -> [[UInt8]] {
        if keyCode == HIDKeymap.KeyCode.capsLock {
            guard !keys.contains(HIDKeymap.capsLockUsage), keys.count < Self.maxKeys else {
                return []
            }
            keys.append(HIDKeymap.capsLockUsage)
            let down = report
            keys.removeAll { $0 == HIDKeymap.capsLockUsage }
            return [down, report]
        }
        let newModifiers = Self.hidModifiers(flags: flags, swapCommandControl: swapCommandControl)
        guard newModifiers != modifiers else { return [] }
        modifiers = newModifiers
        return [report]
    }

    /// Release everything (e.g. when the window loses focus). Returns nil if
    /// nothing was held.
    public mutating func releaseAll() -> [UInt8]? {
        guard modifiers != 0 || !keys.isEmpty else { return nil }
        modifiers = 0
        keys.removeAll()
        return report
    }

    static func hidModifiers(flags: UInt64, swapCommandControl: Bool) -> UInt8 {
        typealias M = HIDKeymap.Modifier
        typealias D = DeviceFlag
        typealias G = GenericFlag

        var leftCtrl = flags & D.leftControl != 0
        var rightCtrl = flags & D.rightControl != 0
        var leftShift = flags & D.leftShift != 0
        let rightShift = flags & D.rightShift != 0
        var leftAlt = flags & D.leftOption != 0
        let rightAlt = flags & D.rightOption != 0
        var leftCmd = flags & D.leftCommand != 0
        var rightCmd = flags & D.rightCommand != 0

        // Synthetic events may carry only the generic flag; treat as left.
        if flags & G.control != 0, !leftCtrl, !rightCtrl { leftCtrl = true }
        if flags & G.shift != 0, !leftShift, !rightShift { leftShift = true }
        if flags & G.option != 0, !leftAlt, !rightAlt { leftAlt = true }
        if flags & G.command != 0, !leftCmd, !rightCmd { leftCmd = true }

        if swapCommandControl {
            (leftCtrl, leftCmd) = (leftCmd, leftCtrl)
            (rightCtrl, rightCmd) = (rightCmd, rightCtrl)
        }

        var m: UInt8 = 0
        if leftCtrl { m |= M.leftControl }
        if leftShift { m |= M.leftShift }
        if leftAlt { m |= M.leftAlt }
        if leftCmd { m |= M.leftGUI }
        if rightCtrl { m |= M.rightControl }
        if rightShift { m |= M.rightShift }
        if rightAlt { m |= M.rightAlt }
        if rightCmd { m |= M.rightGUI }
        return m
    }
}
