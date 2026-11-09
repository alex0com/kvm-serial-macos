import Foundation

public struct CH9329Error: Error, CustomStringConvertible {
    public let description: String
    public init(_ description: String) { self.description = description }
}

/// An open CH9329: serial port, sender thread, and reply handling.
public final class CH9329Device: @unchecked Sendable {
    public let port: SerialPort
    public let link: HIDLink

    private let lock = NSLock()
    private var parser = CH9329ReplyParser()
    private var waiters: [UInt8: (CH9329Reply) -> Void] = [:]
    private var failedReplies = 0

    /// Called (on the serial read queue) for every reply that reports an
    /// error status, e.g. a checksum error.
    public var onFailedReply: (@Sendable (CH9329Reply) -> Void)?

    public init(path: String, baudRate: Int) throws {
        let readQueue = DispatchQueue(label: "CH9329 read", qos: .userInteractive)
        let receiver = Receiver()
        port = try SerialPort(path: path, baudRate: baudRate, queue: readQueue) { bytes in
            receiver.device?.received(bytes)
        }
        link = HIDLink(sink: port)
        receiver.device = self
        link.start()
    }

    deinit { close() }

    /// Breaks the reference cycle between the port's read handler and self.
    private final class Receiver: @unchecked Sendable {
        weak var device: CH9329Device?
    }

    public func close() {
        link.stop()
        port.close()
    }

    public var failedReplyCount: Int {
        lock.lock()
        defer { lock.unlock() }
        return failedReplies
    }

    private func received(_ bytes: [UInt8]) {
        lock.lock()
        let replies = parser.feed(bytes)
        var callbacks: [() -> Void] = []
        var failed: [CH9329Reply] = []
        for reply in replies {
            if reply.isError || (reply.status.map { $0 != .success } ?? false) {
                failedReplies += 1
                failed.append(reply)
            }
            if let waiter = waiters.removeValue(forKey: reply.requestCommand) {
                callbacks.append { waiter(reply) }
            }
        }
        lock.unlock()

        failed.forEach { onFailedReply?($0) }
        callbacks.forEach { $0() }
    }

    /// Send a command and block until the chip replies or `timeout` passes.
    /// Do not call on the main thread.
    public func request(
        _ command: CH9329.Command, data: [UInt8] = [], timeout: TimeInterval = 0.5
    ) -> CH9329Reply? {
        let done = DispatchSemaphore(value: 0)
        nonisolated(unsafe) var result: CH9329Reply?
        lock.lock()
        waiters[command.rawValue] = { reply in
            result = reply
            done.signal()
        }
        lock.unlock()

        link.sendRaw(CH9329.frame(command, data))
        if done.wait(timeout: .now() + timeout) == .timedOut {
            lock.lock()
            waiters.removeValue(forKey: command.rawValue)
            lock.unlock()
            return nil
        }
        return result
    }

    public func getInfo(timeout: TimeInterval = 0.5) -> CH9329Info? {
        request(.getInfo, timeout: timeout).flatMap(CH9329Info.init)
    }

    /// Permanently change the chip's baud rate and confirm it at the new
    /// rate. The current device is closed. Blocks; do not call on the main
    /// thread.
    ///
    /// Refuses to write anything unless the chip answers at `currentBaud` and
    /// its stored configuration reports that same rate, so a misread config
    /// can never be written back.
    public static func changeBaudRate(
        path: String, from currentBaud: Int, to newBaud: Int
    ) throws -> CH9329Info {
        let device = try CH9329Device(path: path, baudRate: currentBaud)
        defer { device.close() }

        guard device.getInfo() != nil else {
            throw CH9329Error("The chip did not respond at \(currentBaud) baud.")
        }
        guard let cfg = device.request(.getConfig), !cfg.isError,
            let stored = CH9329.baudRate(inConfig: cfg.data)
        else {
            throw CH9329Error("Could not read the chip configuration.")
        }
        guard stored == UInt32(currentBaud) else {
            throw CH9329Error(
                "The chip reports a stored baud rate of \(stored), not \(currentBaud). "
                    + "Nothing was changed.")
        }

        let newConfig = CH9329.config(cfg.data, withBaudRate: UInt32(newBaud))
        guard device.request(.setConfig, data: newConfig)?.status == .success else {
            throw CH9329Error("The chip rejected the new configuration. Nothing was changed.")
        }
        // The reset reply arrives at the old rate, before the chip reboots.
        _ = device.request(.reset)
        device.close()

        // Give the chip time to reboot, then confirm at the new rate.
        for _ in 0..<10 {
            Thread.sleep(forTimeInterval: 0.3)
            if let probe = try? CH9329Device(path: path, baudRate: newBaud) {
                defer { probe.close() }
                if let info = probe.getInfo() { return info }
            }
        }
        throw CH9329Error(
            "The chip did not respond at \(newBaud) baud after the change. "
                + "Try reconnecting at \(newBaud) or \(currentBaud).")
    }
}
