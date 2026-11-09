import Foundation
import KVMCore

/// Persisted preferences (UserDefaults, domain com.alex0com.kvm-serial-macos).
@MainActor
struct Settings {
    private static let defaults = UserDefaults.standard

    static let baudRates = [9600, 19200, 38400, 57600, 115200]

    static var serialPort: String? {
        get { defaults.string(forKey: "serialPort") }
        set { defaults.set(newValue, forKey: "serialPort") }
    }

    /// The CH9329 ships at 9600; after "Change Chip Baud Rate…" this follows
    /// the chip.
    static var baudRate: Int {
        get { (defaults.object(forKey: "baudRate") as? Int) ?? 9600 }
        set { defaults.set(newValue, forKey: "baudRate") }
    }

    static var cameraID: String? {
        get { defaults.string(forKey: "cameraID") }
        set { defaults.set(newValue, forKey: "cameraID") }
    }

    /// VideoFormatChoice.key of the chosen format, or nil for automatic.
    static var videoFormat: String? {
        get { defaults.string(forKey: "videoFormat") }
        set { defaults.set(newValue, forKey: "videoFormat") }
    }

    static var swapCommandControl: Bool {
        get { defaults.bool(forKey: "swapCommandControl") }
        set { defaults.set(newValue, forKey: "swapCommandControl") }
    }

    /// macOS targets only drag windows on relative motion; see HIDLink.
    static var targetIsMac: Bool {
        get { defaults.bool(forKey: "targetIsMac") }
        set { defaults.set(newValue, forKey: "targetIsMac") }
    }

    static var hideCursor: Bool {
        get { (defaults.object(forKey: "hideCursor") as? Bool) ?? true }
        set { defaults.set(newValue, forKey: "hideCursor") }
    }

    static var showHUD: Bool {
        get { defaults.bool(forKey: "showHUD") }
        set { defaults.set(newValue, forKey: "showHUD") }
    }

    static var captureSystemShortcuts: Bool {
        get { defaults.bool(forKey: "captureSystemShortcuts") }
        set { defaults.set(newValue, forKey: "captureSystemShortcuts") }
    }

    static var pasteLayout: String {
        get {
            if let saved = defaults.string(forKey: "pasteLayout") { return saved }
            let locale = Locale.current.identifier
            return KeyboardLayouts.available.first { locale.hasPrefix($0) } ?? "en_US"
        }
        set { defaults.set(newValue, forKey: "pasteLayout") }
    }
}
