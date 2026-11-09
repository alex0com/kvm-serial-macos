import Darwin
import Foundation

public struct SerialPortError: Error, CustomStringConvertible {
    public let description: String

    init(_ what: String, errno code: Int32 = errno) {
        description = "\(what): \(String(cString: strerror(code)))"
    }
}

/// Raw 8N1 serial port using POSIX termios.
///
/// Writes block until the bytes have left the UART (`tcdrain`), so callers
/// get real back-pressure instead of filling the driver's buffer. Reads are
/// delivered on a dispatch queue as they arrive.
public final class SerialPort: PacketSink, @unchecked Sendable {
    public let path: String
    public let baudRate: Int

    private let fd: Int32
    private let readSource: DispatchSourceRead
    private let closeLock = NSLock()
    private var closed = false

    // IOKit/serial/ioss.h; _IOW macros are not imported into Swift.
    private static let IOSSDATALAT: UInt = 0x8008_5400  // _IOW('T', 0, unsigned long)

    public init(
        path: String, baudRate: Int, queue: DispatchQueue,
        onBytes: @escaping @Sendable ([UInt8]) -> Void
    ) throws {
        self.path = path
        self.baudRate = baudRate

        let fd = open(path, O_RDWR | O_NOCTTY | O_NONBLOCK)
        guard fd >= 0 else { throw SerialPortError("open \(path)") }

        do {
            // Exclusive access: refuse a second opener.
            guard ioctl(fd, TIOCEXCL) == 0 else { throw SerialPortError("TIOCEXCL") }

            var t = termios()
            guard tcgetattr(fd, &t) == 0 else { throw SerialPortError("tcgetattr") }
            cfmakeraw(&t)
            t.c_cflag |= tcflag_t(CLOCAL | CREAD)
            t.c_cflag &= ~tcflag_t(CSTOPB | PARENB | CRTSCTS)
            // VMIN=0/VTIME=0: read() returns whatever is buffered without waiting.
            withUnsafeMutableBytes(of: &t.c_cc) { cc in
                cc[Int(VMIN)] = 0
                cc[Int(VTIME)] = 0
            }
            guard cfsetspeed(&t, speed_t(baudRate)) == 0 else {
                throw SerialPortError("unsupported baud rate \(baudRate)")
            }
            guard tcsetattr(fd, TCSANOW, &t) == 0 else { throw SerialPortError("tcsetattr") }

            // Deliver received bytes after 1 µs instead of the driver default.
            var latency: UInt = 1
            _ = ioctl(fd, Self.IOSSDATALAT, &latency)

            // Blocking writes; reads stay non-blocking via VMIN/VTIME.
            guard fcntl(fd, F_SETFL, 0) == 0 else { throw SerialPortError("fcntl") }
            tcflush(fd, TCIOFLUSH)
        } catch {
            Darwin.close(fd)
            throw error
        }

        self.fd = fd
        let source = DispatchSource.makeReadSource(fileDescriptor: fd, queue: queue)
        source.setEventHandler {
            var buf = [UInt8](repeating: 0, count: 256)
            let n = read(fd, &buf, buf.count)
            if n > 0 { onBytes(Array(buf[0..<n])) }
        }
        source.setCancelHandler { Darwin.close(fd) }
        readSource = source
        source.resume()
    }

    deinit { close() }

    /// Write all bytes and wait until they have been transmitted.
    public func send(_ bytes: [UInt8]) throws {
        var offset = 0
        while offset < bytes.count {
            let n = bytes[offset...].withUnsafeBytes { write(fd, $0.baseAddress, $0.count) }
            if n < 0 {
                if errno == EINTR { continue }
                throw SerialPortError("write \(path)")
            }
            offset += n
        }
        guard tcdrain(fd) == 0 else { throw SerialPortError("tcdrain \(path)") }
    }

    public func close() {
        closeLock.lock()
        defer { closeLock.unlock() }
        guard !closed else { return }
        closed = true
        readSource.cancel()
    }

    /// Candidate serial ports, USB adapters first.
    public static func availablePorts() -> [String] {
        let ignored: Set<String> = ["cu.Bluetooth-Incoming-Port", "cu.debug-console"]
        let names = (try? FileManager.default.contentsOfDirectory(atPath: "/dev")) ?? []
        return names
            .filter { $0.hasPrefix("cu.") && !ignored.contains($0) }
            .sorted { lhs, rhs in
                let l = lhs.contains("usbserial"), r = rhs.contains("usbserial")
                return l != r ? l : lhs < rhs
            }
            .map { "/dev/" + $0 }
    }
}
