import Foundation
import Testing

@testable import KVMCore

/// Records packets; `send` blocks while the gate is closed, standing in for a
/// slow serial line.
private final class GatedSink: PacketSink, @unchecked Sendable {
    private let condition = NSCondition()
    private var open = false
    private var packets: [[UInt8]] = []
    private let firstSend = DispatchSemaphore(value: 0)
    private var sawFirst = false

    func send(_ bytes: [UInt8]) throws {
        condition.lock()
        packets.append(bytes)
        if !sawFirst {
            sawFirst = true
            firstSend.signal()
        }
        while !open { condition.wait() }
        condition.unlock()
    }

    func waitForFirstSend() { firstSend.wait() }

    func release() {
        condition.lock()
        open = true
        condition.broadcast()
        condition.unlock()
    }

    var sent: [[UInt8]] {
        condition.lock()
        defer { condition.unlock() }
        return packets
    }
}

private func waitUntil(_ predicate: () -> Bool) {
    let deadline = Date().addingTimeInterval(2)
    while !predicate() && Date() < deadline { usleep(1000) }
}

@Suite struct HIDLinkTests {
    @Test func movesCoalesceWhileLineIsBusyAndDiscreteEventsKeepOrder() {
        let sink = GatedSink()
        let link = HIDLink(sink: sink)
        link.start()
        defer { link.stop() }

        // Occupy the line with a key press, then flood it.
        link.sendKeyboard([0, 0, 0x04, 0, 0, 0, 0, 0])
        sink.waitForFirstSend()
        for i in 0..<1000 { link.moveTo(x: i, y: i) }
        link.setButtons(0x01)
        for i in 1000..<2000 { link.moveTo(x: i % 4096, y: 7) }
        link.setButtons(0x00)
        link.sendKeyboard([0, 0, 0, 0, 0, 0, 0, 0])
        link.moveTo(x: 4000, y: 4000)
        sink.release()

        waitUntil { sink.sent.count >= 5 }
        usleep(20_000)
        let sent = sink.sent

        #expect(sent == [
            CH9329.keyboard([0, 0, 0x04, 0, 0, 0, 0, 0]),
            CH9329.mouseAbsolute(buttons: 0x01, x: 999, y: 999),
            CH9329.mouseAbsolute(buttons: 0x00, x: 1999, y: 7),
            CH9329.keyboard([0, 0, 0, 0, 0, 0, 0, 0]),
            CH9329.mouseAbsolute(buttons: 0x00, x: 4000, y: 4000),
        ])
        let stats = link.currentStats
        #expect(stats.movesSent == 1)
        #expect(stats.movesCoalesced == 2000)
        #expect(stats.packetsSent == 5)
    }

    @Test func scrollsMergeAndSplitAtByteLimit() {
        let sink = GatedSink()
        let link = HIDLink(sink: sink)
        link.start()
        defer { link.stop() }

        link.sendKeyboard([0, 0, 0, 0, 0, 0, 0, 0])
        sink.waitForFirstSend()
        for _ in 0..<100 { link.scroll(2) }
        sink.release()

        waitUntil { sink.sent.count >= 3 }
        usleep(20_000)
        #expect(Array(sink.sent.dropFirst()) == [
            CH9329.mouseRelative(buttons: 0, wheel: 127),
            CH9329.mouseRelative(buttons: 0, wheel: 73),
        ])
    }

    @Test func relativeDragForMacTargets() {
        let sink = GatedSink()
        let link = HIDLink(sink: sink)
        // 1 absolute unit = 0.5 target pixels.
        link.relativeDragScale = (0.5, 0.5)
        link.start()
        defer { link.stop() }

        link.sendKeyboard([0, 0, 0, 0, 0, 0, 0, 0])
        sink.waitForFirstSend()
        link.moveTo(x: 1000, y: 1000)  // hover: absolute, superseded by the press
        link.setButtons(0x01)  // press: absolute
        for i in 1...10 { link.moveTo(x: 1000 + i * 100, y: 1000 - i * 10) }  // +500, -50 px
        link.setButtons(0x00)  // release: relative, then absolute
        sink.release()

        waitUntil { sink.sent.count >= 7 }
        usleep(20_000)
        #expect(Array(sink.sent.dropFirst()) == [
            CH9329.mouseAbsolute(buttons: 0x01, x: 1000, y: 1000),
            CH9329.mouseRelative(buttons: 0x01, dx: 127, dy: -50),
            CH9329.mouseRelative(buttons: 0x01, dx: 127),
            CH9329.mouseRelative(buttons: 0x01, dx: 127),
            CH9329.mouseRelative(buttons: 0x01, dx: 119),
            CH9329.mouseRelative(buttons: 0x00),
            CH9329.mouseAbsolute(buttons: 0x00, x: 2000, y: 900),
        ])
    }

    @Test func hoverStaysAbsoluteInRelativeDragMode() {
        let sink = GatedSink()
        let link = HIDLink(sink: sink)
        link.relativeDragScale = (0.5, 0.5)
        link.start()
        defer { link.stop() }
        link.moveTo(x: 10, y: 20)
        sink.release()
        waitUntil { sink.sent.count >= 1 }
        #expect(sink.sent == [CH9329.mouseAbsolute(buttons: 0, x: 10, y: 20)])
    }
}
