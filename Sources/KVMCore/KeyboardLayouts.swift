// Character-to-HID tables used to type pasted text on the target. Ported
// from kvm_serial/utils/keyboard_layouts.py in kvm-serial
// (https://github.com/sjmf/kvm-serial): a base en_GB (ISO) layout plus
// per-layout overrides. Here the target's layout matters, because we are
// producing characters rather than forwarding physical keys.

public enum KeyboardLayouts {
    public static let available = ["en_GB", "en_US", "pl_PL"]

    /// Characters typed without Shift. Everything else in a layout needs Shift.
    /// Mirrors the non-shift rule in kvm-serial's ascii_to_scancode.
    static let unshiftedSymbols: Set<Character> = Set("\n\t\u{8} -=[];',./\\`")

    static let base: [Character: UInt8] = [
        "a": 0x04, "b": 0x05, "c": 0x06, "d": 0x07, "e": 0x08, "f": 0x09, "g": 0x0A, "h": 0x0B,
        "i": 0x0C, "j": 0x0D, "k": 0x0E, "l": 0x0F, "m": 0x10, "n": 0x11, "o": 0x12, "p": 0x13,
        "q": 0x14, "r": 0x15, "s": 0x16, "t": 0x17, "u": 0x18, "v": 0x19, "w": 0x1A, "x": 0x1B,
        "y": 0x1C, "z": 0x1D,
        "1": 0x1E, "2": 0x1F, "3": 0x20, "4": 0x21, "5": 0x22, "6": 0x23, "7": 0x24, "8": 0x25,
        "9": 0x26, "0": 0x27,
        "-": 0x2D, "=": 0x2E, "[": 0x2F, "]": 0x30, "#": 0x32, ";": 0x33, "'": 0x34, "`": 0x35,
        ",": 0x36, ".": 0x37, "/": 0x38, "\\": 0x64,
        "\n": 0x28, "\t": 0x2B, "\u{8}": 0x2A, " ": 0x2C,
        "A": 0x04, "B": 0x05, "C": 0x06, "D": 0x07, "E": 0x08, "F": 0x09, "G": 0x0A, "H": 0x0B,
        "I": 0x0C, "J": 0x0D, "K": 0x0E, "L": 0x0F, "M": 0x10, "N": 0x11, "O": 0x12, "P": 0x13,
        "Q": 0x14, "R": 0x15, "S": 0x16, "T": 0x17, "U": 0x18, "V": 0x19, "W": 0x1A, "X": 0x1B,
        "Y": 0x1C, "Z": 0x1D,
        "!": 0x1E, "\"": 0x1F, "£": 0x20, "$": 0x21, "%": 0x22, "^": 0x23, "&": 0x24, "*": 0x25,
        "(": 0x26, ")": 0x27, "_": 0x2D, "+": 0x2E, "{": 0x2F, "}": 0x30, "~": 0x32, ":": 0x33,
        "@": 0x34, "¬": 0x35, "<": 0x36, ">": 0x37, "?": 0x38, "|": 0x64,
    ]

    /// nil removes the character from the layout.
    static let overrides: [String: [Character: UInt8?]] = [
        "en_GB": [:],
        "en_US": [
            "\"": 0x34, "@": 0x1F, "#": 0x20, "£": nil, "¬": nil,
        ],
        "pl_PL": [
            "ą": 0x04, "Ą": 0x04, "ć": 0x06, "Ć": 0x06, "ę": 0x08, "Ę": 0x08,
            "ł": 0x0F, "Ł": 0x0F, "ń": 0x11, "Ń": 0x11, "ó": 0x12, "Ó": 0x12,
            "ś": 0x16, "Ś": 0x16, "ź": 0x1D, "Ź": 0x1D, "ż": 0x1D, "Ż": 0x1D,
            ";": 0x33, ":": 0x33, "/": 0x38, "?": 0x38, "\"": 0x1F, "'": 0x34,
        ],
    ]

    public static func layout(_ name: String) -> [Character: UInt8] {
        var map = base
        for (char, usage) in overrides[name] ?? [:] {
            map[char] = usage
        }
        return map
    }

    /// Key-down report for typing `char`, or nil if the layout can't type it.
    public static func report(for char: Character, layout: [Character: UInt8]) -> [UInt8]? {
        // Treat CRLF as a single Return.
        let char: Character = char == "\r\n" || char == "\r" ? "\n" : char
        guard let usage = layout[char] else { return nil }
        let needsShift = !(char.isLowercase || char.isNumber || unshiftedSymbols.contains(char))
        return [needsShift ? HIDKeymap.Modifier.leftShift : 0, 0, usage, 0, 0, 0, 0, 0]
    }
}
