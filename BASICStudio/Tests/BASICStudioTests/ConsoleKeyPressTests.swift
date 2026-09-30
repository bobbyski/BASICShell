//
//  ConsoleKeyPressTests.swift
//  BASICStudioTests
//
//  The sequences a hardware key sends to a BASIC program. The Mac's NSEvent
//  path and the iPad's UIKey path both turn a press into a ConsoleKeyPress
//  and read its sequence here, so INKEY$ sees the same key on both.
//

import BASICCore
import Foundation
import Testing
@testable import BASICStudio

@Suite("Console key sequences")
struct ConsoleKeyPressTests {
    private func press(
        _ special: ConsoleSpecialKey?,
        _ characters: String = "",
        _ modifiers: ConsoleKeyModifiers = []
    ) -> ConsoleKeyPress {
        ConsoleKeyPress(special: special, charactersIgnoringModifiers: characters, modifiers: modifiers)
    }

    @Test("Arrows and editing keys are CSI sequences, plain and modified")
    func navigationKeys() {
        #expect(press(.up).rawSequence == "\u{1B}[A")
        #expect(press(.left, "", .shift).rawSequence == "\u{1B}[1;2D")
        #expect(press(.home, "", .option).rawSequence == "\u{1B}[1;3H")
        #expect(press(.end, "", [.shift, .option]).rawSequence == "\u{1B}[1;4F")
        #expect(press(.down, "", .command).rawSequence == "\u{1B}[1;9B")
        #expect(press(.right, "", [.shift, .option, .command]).rawSequence == "\u{1B}[1;12C")
        #expect(press(.pageUp).rawSequence == "\u{1B}[5~")
        #expect(press(.pageDown, "", .shift).rawSequence == "\u{1B}[6;2~")
        #expect(press(.insert).rawSequence == "\u{1B}[2~")
        #expect(press(.forwardDelete, "", .command).rawSequence == "\u{1B}[3;9~")
    }

    @Test("F1–F4 are SS3 unmodified and CSI modified; the rest skip as the VT220's did")
    func functionKeys() {
        #expect(press(.function(1)).rawSequence == "\u{1B}OP")
        #expect(press(.function(4), "", .shift).rawSequence == "\u{1B}[1;2S")
        #expect(press(.function(5)).rawSequence == "\u{1B}[15~")
        #expect(press(.function(11)).rawSequence == "\u{1B}[23~")
        #expect(press(.function(12), "", .option).rawSequence == "\u{1B}[24;3~")
        #expect(press(.function(22)).rawSequence == "\u{1B}[36~")
        #expect(press(.function(23)).rawSequence == nil)
    }

    @Test("Control changes no special key's sequence")
    func controlIsNotAModifierParameter() {
        #expect(press(.up, "", .control).rawSequence == "\u{1B}[A")
    }

    @Test("Shift+Return and Option with a character are the console's own sequences")
    func consoleOwnSequences() {
        #expect(press(.returnKey, "\r", .shift).rawSequence == "\u{1B}[!M")
        #expect(press(.returnKey, "\r").rawSequence == nil)
        #expect(press(nil, "a", .option).rawSequence == "\u{1B}[#a")
        #expect(press(nil, "A", [.shift, .option]).rawSequence == "\u{1B}[!#A")
    }

    @Test("Ordinary typing is left to the terminal's bytes")
    func plainTypingIsNotTaken() {
        #expect(press(nil, "a").rawSequence == nil)
        #expect(press(nil, "a", .shift).rawSequence == nil)
        #expect(press(nil, "a", .command).rawSequence == nil)
        #expect(press(nil, "\u{1B}").rawSequence == nil)
    }

    @Test("^C and ^I are recognised whatever the case")
    func controlKeys() {
        #expect(press(nil, "c", .control).isInterrupt)
        #expect(press(nil, "C", [.control, .shift]).isInterrupt)
        #expect(!press(nil, "c").isInterrupt)
        #expect(press(nil, "i", .control).isOverwriteToggle)
        #expect(!press(nil, "i", .option).isOverwriteToggle)
    }

    /// What this is for: a modifier held with a special key reaches INKEY$ as a
    /// different key. SwiftTerm's iOS bytes carry none of these, so on an iPad
    /// they all read as the plain key.
    @Test("INKEY$ tells a modified key from the plain one")
    func inkeyDistinguishesModifiers() throws {
        let plainUp = BASICKeyNormalizer.normalize(try #require(press(.up).rawSequence))
        let shiftUp = BASICKeyNormalizer.normalize(try #require(press(.up, "", .shift).rawSequence))
        let commandUp = BASICKeyNormalizer.normalize(try #require(press(.up, "", .command).rawSequence))
        #expect(plainUp != shiftUp)
        #expect(plainUp != commandUp)
        #expect(shiftUp != commandUp)

        let plainF5 = BASICKeyNormalizer.normalize(try #require(press(.function(5)).rawSequence))
        let optionF5 = BASICKeyNormalizer.normalize(try #require(press(.function(5), "", .option).rawSequence))
        #expect(plainF5 != optionF5)

        // Page Up is a key a program can read, not the terminal scrolling.
        let pageUp = BASICKeyNormalizer.normalize(try #require(press(.pageUp).rawSequence))
        #expect(pageUp != BASICKeyNormalizer.normalize("\u{1B}"))
    }
}
