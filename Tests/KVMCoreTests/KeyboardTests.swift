import Testing

@testable import KVMCore

@Suite struct HIDKeymapTests {
    @Test func lettersDigitsAndNavigation() {
        #expect(HIDKeymap.usage(for: 0x00) == 0x04)  // A
        #expect(HIDKeymap.usage(for: 0x06) == 0x1D)  // Z
        #expect(HIDKeymap.usage(for: 0x12) == 0x1E)  // 1
        #expect(HIDKeymap.usage(for: 0x1D) == 0x27)  // 0
        #expect(HIDKeymap.usage(for: 0x24) == 0x28)  // Return
        #expect(HIDKeymap.usage(for: 0x33) == 0x2A)  // Backspace
        #expect(HIDKeymap.usage(for: 0x75) == 0x4C)  // Forward delete
        #expect(HIDKeymap.usage(for: 0x7B) == 0x50)  // Left
        #expect(HIDKeymap.usage(for: 0x7E) == 0x52)  // Up
        #expect(HIDKeymap.usage(for: 0x7A) == 0x3A)  // F1
        #expect(HIDKeymap.usage(for: 0x6F) == 0x45)  // F12
    }

    @Test func modifiersAndUnknownKeysAreUnmapped() {
        for code in HIDKeymap.KeyCode.modifiers {
            #expect(HIDKeymap.usage(for: code) == nil)
        }
        #expect(HIDKeymap.usage(for: 0x200) == nil)
    }

    @Test func isoGraveAndSection() {
        #expect(HIDKeymap.usage(for: HIDKeymap.KeyCode.grave, isISO: false) == 0x35)
        #expect(HIDKeymap.usage(for: HIDKeymap.KeyCode.grave, isISO: true) == 0x64)
        #expect(HIDKeymap.usage(for: HIDKeymap.KeyCode.isoSection, isISO: true) == 0x35)
    }

    @Test func everyMappedUsageIsUnique() {
        // § (ISO) and ` (ANSI) share a physical position, so both map to 0x35.
        let usages = HIDKeymap.table.enumerated()
            .filter { $0.element != 0 && $0.offset != Int(HIDKeymap.KeyCode.isoSection) }
            .map(\.element)
        #expect(Set(usages).count == usages.count)
    }
}

@Suite struct KeyboardStateTests {
    typealias D = KeyboardState.DeviceFlag
    typealias M = HIDKeymap.Modifier

    @Test func overlappingKeysStayHeld() {
        var kb = KeyboardState()
        #expect(kb.keyDown(0x11) == [0, 0, 0x17, 0, 0, 0, 0, 0])  // T
        #expect(kb.keyDown(0x04) == [0, 0, 0x17, 0x0B, 0, 0, 0, 0])  // H
        // Releasing T must keep H held.
        #expect(kb.keyUp(0x11) == [0, 0, 0x0B, 0, 0, 0, 0, 0])
        #expect(kb.keyUp(0x04) == [0, 0, 0, 0, 0, 0, 0, 0])
    }

    @Test func repeatedDownAndUnknownKeysAreIgnored() {
        var kb = KeyboardState()
        #expect(kb.keyDown(0x00) != nil)
        #expect(kb.keyDown(0x00) == nil)
        #expect(kb.keyUp(0x01) == nil)
        #expect(kb.keyDown(0x3F) == nil)  // Fn
    }

    @Test func rolloverLimitedToSixKeys() {
        var kb = KeyboardState()
        for code: UInt16 in [0x00, 0x01, 0x02, 0x03, 0x04, 0x05] {
            #expect(kb.keyDown(code) != nil)
        }
        #expect(kb.keyDown(0x06) == nil)
        #expect(kb.keys.count == 6)
    }

    @Test func leftAndRightModifiersWithoutSwap() {
        var kb = KeyboardState(swapCommandControl: false)
        #expect(kb.flagsChanged(keyCode: 0x38, flags: D.leftShift) == [[M.leftShift, 0, 0, 0, 0, 0, 0, 0]])
        #expect(kb.flagsChanged(keyCode: 0x3D, flags: D.leftShift | D.rightOption).first?[0] == M.leftShift | M.rightAlt)
        #expect(kb.flagsChanged(keyCode: 0x36, flags: D.rightCommand).first?[0] == M.rightGUI)
        #expect(kb.flagsChanged(keyCode: 0x3E, flags: D.rightControl).first?[0] == M.rightControl)
        #expect(kb.flagsChanged(keyCode: 0x3E, flags: D.rightControl).isEmpty)  // no change
    }

    @Test func swapMapsCommandToControl() {
        var kb = KeyboardState(swapCommandControl: true)
        #expect(kb.flagsChanged(keyCode: 0x37, flags: D.leftCommand).first?[0] == M.leftControl)
        #expect(kb.flagsChanged(keyCode: 0x3B, flags: D.leftControl).first?[0] == M.leftGUI)
        #expect(kb.flagsChanged(keyCode: 0x36, flags: D.rightCommand).first?[0] == M.rightControl)
    }

    @Test func genericFlagFallsBackToLeft() {
        var kb = KeyboardState(swapCommandControl: false)
        #expect(kb.flagsChanged(keyCode: 0x38, flags: 0x0002_0000).first?[0] == M.leftShift)
    }

    @Test func modifiersCombineWithKeys() {
        var kb = KeyboardState(swapCommandControl: true)
        _ = kb.flagsChanged(keyCode: 0x37, flags: D.leftCommand)
        #expect(kb.keyDown(0x08) == [M.leftControl, 0, 0x06, 0, 0, 0, 0, 0])  // Cmd+C -> Ctrl+C
    }

    @Test func capsLockIsPressAndRelease() {
        var kb = KeyboardState()
        let reports = kb.flagsChanged(keyCode: HIDKeymap.KeyCode.capsLock, flags: 0x0001_0000)
        #expect(reports == [[0, 0, 0x39, 0, 0, 0, 0, 0], [0, 0, 0, 0, 0, 0, 0, 0]])
        #expect(kb.keys.isEmpty)
    }

    @Test func releaseAll() {
        var kb = KeyboardState(swapCommandControl: false)
        #expect(kb.releaseAll() == nil)
        _ = kb.flagsChanged(keyCode: 0x38, flags: D.leftShift)
        _ = kb.keyDown(0x00)
        #expect(kb.releaseAll() == [0, 0, 0, 0, 0, 0, 0, 0])
        #expect(kb.releaseAll() == nil)
    }
}

@Suite struct KeyboardLayoutTests {
    @Test func shiftRules() {
        let gb = KeyboardLayouts.layout("en_GB")
        #expect(KeyboardLayouts.report(for: "a", layout: gb) == [0, 0, 0x04, 0, 0, 0, 0, 0])
        #expect(KeyboardLayouts.report(for: "A", layout: gb) == [0x02, 0, 0x04, 0, 0, 0, 0, 0])
        #expect(KeyboardLayouts.report(for: "7", layout: gb) == [0, 0, 0x24, 0, 0, 0, 0, 0])
        #expect(KeyboardLayouts.report(for: "@", layout: gb) == [0x02, 0, 0x34, 0, 0, 0, 0, 0])
        #expect(KeyboardLayouts.report(for: "\r\n", layout: gb)?[2] == 0x28)
        #expect(KeyboardLayouts.report(for: "é", layout: gb) == nil)
    }

    @Test func usOverrides() {
        let us = KeyboardLayouts.layout("en_US")
        #expect(KeyboardLayouts.report(for: "@", layout: us) == [0x02, 0, 0x1F, 0, 0, 0, 0, 0])
        #expect(KeyboardLayouts.report(for: "\"", layout: us) == [0x02, 0, 0x34, 0, 0, 0, 0, 0])
        #expect(KeyboardLayouts.report(for: "£", layout: us) == nil)
    }
}
