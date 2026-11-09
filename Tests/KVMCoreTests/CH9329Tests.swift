import Testing

@testable import KVMCore

private func hex(_ bytes: [UInt8]) -> String {
    bytes.map { String(format: "%02x", $0) }.joined()
}

// Golden packets generated from kvm-serial's kvm_serial/utils/ch9329.py
// (CH9329Comm with a mock port), so the Swift framing stays byte-identical to
// the original implementation.
@Suite struct CH9329FramingTests {
    @Test func keyboardShiftA() {
        #expect(hex(CH9329.keyboard([0x02, 0, 0x04, 0, 0, 0, 0, 0])) == "57ab000208020004000000000012")
    }

    @Test func keyboardRelease() {
        #expect(hex(CH9329.keyboard([UInt8](repeating: 0, count: 8))) == "57ab00020800000000000000000c")
    }

    @Test func absoluteCenterLeftButton() {
        let x = CH9329.scaleAbsolute(960, extent: 1920)
        let y = CH9329.scaleAbsolute(540, extent: 1080)
        #expect(hex(CH9329.mouseAbsolute(buttons: 1, x: x, y: y)) == "57ab0004070201000800080020")
    }

    @Test func absoluteOrigin() {
        #expect(hex(CH9329.mouseAbsolute(buttons: 0, x: 0, y: 0)) == "57ab000407020000000000000f")
    }

    @Test func absoluteMaxWithWheel() {
        let x = CH9329.scaleAbsolute(1919, extent: 1920)
        let y = CH9329.scaleAbsolute(1079, extent: 1080)
        #expect(hex(CH9329.mouseAbsolute(buttons: 0, x: x, y: y, wheel: -3)) == "57ab0004070200fd0ffc0ffd23")
    }

    @Test func absoluteClampsTo4095() {
        #expect(CH9329.scaleAbsolute(1920, extent: 1920) == 4095)
        #expect(CH9329.scaleAbsolute(-5, extent: 1920) == 0)
    }

    @Test func relativeWheelUp() {
        #expect(hex(CH9329.mouseRelative(buttons: 0, wheel: 5)) == "57ab000505010000000512")
    }

    @Test func relativeClamped() {
        #expect(hex(CH9329.mouseRelative(buttons: 2, dx: -10, dy: 200, wheel: -200)) == "57ab0005050102f67f8105")
    }
}

@Suite struct CH9329ReplyTests {
    @Test func parsesInfoReplyAcrossChunksAndGarbage() {
        // GET_INFO reply: version 0x30, USB connected, Caps Lock on.
        let frame = CH9329.frame(cmd: 0x81, [0x30, 0x01, 0x02, 0, 0, 0, 0, 0])
        var parser = CH9329ReplyParser()
        #expect(parser.feed([0x00, 0xFF] + frame.prefix(4)).isEmpty)
        let replies = parser.feed(frame.dropFirst(4))
        #expect(replies.count == 1)

        let info = CH9329Info(replies[0])
        #expect(info?.versionString == "1.0")
        #expect(info?.usbConnected == true)
        #expect(info?.capsLock == true)
        #expect(info?.numLock == false)
    }

    @Test func dropsBadChecksumAndResyncs() {
        var bad = CH9329.frame(cmd: 0x82, [0x00])
        bad[bad.count - 1] &+= 1
        let good = CH9329.frame(cmd: 0x84, [0x00])
        var parser = CH9329ReplyParser()
        let replies = parser.feed(bad + good)
        #expect(replies == [CH9329Reply(command: 0x84, data: [0x00])])
        #expect(replies[0].status == .success)
    }

    @Test func errorReply() {
        let reply = CH9329Reply(command: 0xC2, data: [0xE4])
        #expect(reply.isError)
        #expect(reply.requestCommand == 0x02)
        #expect(reply.status == .checksumError)
    }

    @Test func configBaudRoundTrip() {
        var cfg = [UInt8](repeating: 0, count: CH9329.configLength)
        cfg[3...6] = [0x00, 0x00, 0x25, 0x80]
        #expect(CH9329.baudRate(inConfig: cfg) == 9600)
        let updated = CH9329.config(cfg, withBaudRate: 115200)
        #expect(Array(updated[3...6]) == [0x00, 0x01, 0xC2, 0x00])
        #expect(CH9329.baudRate(inConfig: updated) == 115200)
        #expect(CH9329.baudRate(inConfig: [0x00]) == nil)
    }
}
