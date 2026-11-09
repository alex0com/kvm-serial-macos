// CH9329 UART-to-USB-HID bridge protocol.
//
// Frame layout:
//   header(2B: 0x57 0xAB) + addr(1B) + cmd(1B) + len(1B) + data + checksum(1B)
//
// Packet builders are byte-for-byte ports of kvm_serial/utils/ch9329.py in
// kvm-serial (https://github.com/sjmf/kvm-serial); the golden-byte tests in
// CH9329Tests were generated from that implementation.

public enum CH9329 {
    public static let header: [UInt8] = [0x57, 0xAB]
    public static let address: UInt8 = 0x00

    /// Absolute mouse coordinates are 12-bit (0..4095).
    public static let absoluteMax = 4095

    public enum Command: UInt8, Sendable {
        case getInfo = 0x01
        case keyboard = 0x02
        case mouseAbsolute = 0x04
        case mouseRelative = 0x05
        case getConfig = 0x08
        case setConfig = 0x09
        case reset = 0x0F
    }

    /// Reply status byte for commands that return a single status.
    public enum Status: UInt8, Sendable {
        case success = 0x00
        case timeout = 0xE1
        case headerError = 0xE2
        case commandError = 0xE3
        case checksumError = 0xE4
        case parameterError = 0xE5
        case operationFailed = 0xE6
    }

    // MARK: - Framing

    public static func frame(_ cmd: Command, _ data: [UInt8] = []) -> [UInt8] {
        frame(cmd: cmd.rawValue, data)
    }

    public static func frame(cmd: UInt8, _ data: [UInt8]) -> [UInt8] {
        precondition(data.count <= 255, "CH9329 payload is at most 255 bytes")
        var packet = header + [address, cmd, UInt8(data.count)] + data
        packet.append(checksum(packet))
        return packet
    }

    static func checksum(_ bytes: [UInt8]) -> UInt8 {
        bytes.reduce(0) { $0 &+ $1 }
    }

    // MARK: - HID reports

    /// 8-byte boot keyboard report: modifiers, reserved, up to 6 key usages.
    public static func keyboard(_ report: [UInt8]) -> [UInt8] {
        precondition(report.count == 8, "keyboard report must be 8 bytes")
        return frame(.keyboard, report)
    }

    /// Absolute mouse report with x, y already in 0..4095.
    public static func mouseAbsolute(buttons: UInt8, x: Int, y: Int, wheel: Int = 0) -> [UInt8] {
        let cx = UInt16(clamping: min(max(x, 0), absoluteMax))
        let cy = UInt16(clamping: min(max(y, 0), absoluteMax))
        let data: [UInt8] = [
            0x02, buttons,
            UInt8(cx & 0xFF), UInt8(cx >> 8),
            UInt8(cy & 0xFF), UInt8(cy >> 8),
            signedByte(wheel),
        ]
        return frame(.mouseAbsolute, data)
    }

    /// Scale a source pixel position into the 0..4095 absolute space, matching
    /// CH9329Comm.send_mouse_absolute (4096 * x // width), clamped to 4095.
    public static func scaleAbsolute(_ value: Int, extent: Int) -> Int {
        min(absoluteMax, max(0, (4096 * value) / max(1, extent)))
    }

    public static func mouseRelative(buttons: UInt8, dx: Int = 0, dy: Int = 0, wheel: Int = 0)
        -> [UInt8]
    {
        frame(.mouseRelative, [0x01, buttons, signedByte(dx), signedByte(dy), signedByte(wheel)])
    }

    static func signedByte(_ value: Int) -> UInt8 {
        UInt8(bitPattern: Int8(min(127, max(-127, value))))
    }

    // MARK: - Configuration

    /// Offset and width of the baud rate field in the 50-byte parameter block
    /// returned by GET_PARA_CFG (big-endian, per the CH9329 datasheet).
    public static let configLength = 50
    static let baudOffset = 3

    public static func baudRate(inConfig config: [UInt8]) -> UInt32? {
        guard config.count == configLength else { return nil }
        return config[baudOffset..<baudOffset + 4].reduce(0) { ($0 << 8) | UInt32($1) }
    }

    public static func config(_ config: [UInt8], withBaudRate baud: UInt32) -> [UInt8] {
        var out = config
        for i in 0..<4 {
            out[baudOffset + i] = UInt8((baud >> (8 * (3 - i))) & 0xFF)
        }
        return out
    }
}

// MARK: - Replies

/// A reply frame from the chip. Replies set bit 7 of the command byte
/// (cmd | 0x80) on success and bits 7+6 (cmd | 0xC0) on error.
public struct CH9329Reply: Equatable, Sendable {
    public let command: UInt8
    public let data: [UInt8]

    public var requestCommand: UInt8 { command & 0x3F }
    public var isError: Bool { command & 0xC0 == 0xC0 }

    /// For single-byte status replies (keyboard, mouse, set config, reset).
    public var status: CH9329.Status? {
        data.count == 1 ? CH9329.Status(rawValue: data[0]) : nil
    }
}

/// GET_INFO reply payload.
public struct CH9329Info: Equatable, Sendable {
    public let version: UInt8
    public let usbConnected: Bool
    public let numLock: Bool
    public let capsLock: Bool
    public let scrollLock: Bool

    public init?(_ reply: CH9329Reply) {
        guard reply.requestCommand == CH9329.Command.getInfo.rawValue, !reply.isError,
            reply.data.count >= 3
        else { return nil }
        version = reply.data[0]
        usbConnected = reply.data[1] != 0
        numLock = reply.data[2] & 0x01 != 0
        capsLock = reply.data[2] & 0x02 != 0
        scrollLock = reply.data[2] & 0x04 != 0
    }

    /// Chip firmware version, e.g. 0x30 -> "1.0".
    public var versionString: String {
        "\((Int(version) >> 4) - 2).\(version & 0x0F)"
    }
}

/// Incremental parser for the reply byte stream. Resynchronises on the
/// 0x57 0xAB header and drops frames with a bad checksum.
public struct CH9329ReplyParser: Sendable {
    private var buffer: [UInt8] = []

    public init() {}

    public mutating func feed(_ bytes: some Sequence<UInt8>) -> [CH9329Reply] {
        buffer.append(contentsOf: bytes)
        var replies: [CH9329Reply] = []
        while true {
            // Discard bytes until a (possibly partial) header is at the front.
            while let first = buffer.first,
                first != 0x57 || (buffer.count >= 2 && buffer[1] != 0xAB)
            {
                buffer.removeFirst()
            }
            guard buffer.count >= 5 else { return replies }
            let len = Int(buffer[4])
            let total = 5 + len + 1
            guard buffer.count >= total else { return replies }
            let frame = Array(buffer[0..<total])
            if CH9329.checksum(Array(frame.dropLast())) == frame.last {
                replies.append(CH9329Reply(command: frame[3], data: Array(frame[5..<5 + len])))
                buffer.removeFirst(total)
            } else {
                // Bad frame: skip this header and resync.
                buffer.removeFirst()
            }
        }
    }
}
