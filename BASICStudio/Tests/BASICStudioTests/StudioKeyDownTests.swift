//
//  StudioKeyDownTests.swift
//  BASICStudioTests
//
//  KEYDOWN in Studio: answered from the keys the console saw go down.
//

import Foundation
import Testing
@testable import BASICStudio

@Suite("KEYDOWN in Studio", .serialized)
@MainActor
struct StudioKeyDownTests {
    @Test("Until a key has gone down, Studio cannot say, and KEYDOWN falls back on INKEY$")
    func unknownUntilAKeyIsSeen() {
        let keys = StudioHeldKeys()
        #expect(keys.isDown("LEFT") == nil)
        keys.set("LEFT", down: true)
        #expect(keys.isDown("LEFT") == true)
        #expect(keys.isDown("RIGHT") == false)
        keys.set("LEFT", down: false)
        #expect(keys.isDown("LEFT") == false)
        keys.set("SHIFT", down: true)
        keys.releaseAll()
        #expect(keys.isDown("SHIFT") == false)
    }

    @Test("A program reads the keys the console holds")
    func programReadsHeldKeys() async throws {
        let studio = StudioHarness(program: """
        PRINT KEYDOWN("LEFT"); KEYDOWN("RIGHT"); KEYDOWN("[K")
        """)
        studio.model.heldKeys.set("LEFT", down: true)
        try await studio.run()
        #expect(studio.lastRunOutput.filter { $0 != " " }.contains("101"), "\(studio.lastRunOutput)")
    }

    @Test("A key press names the key KEYDOWN knows it by")
    func keyPressNames() {
        #expect(ConsoleKeyPress(special: .left, charactersIgnoringModifiers: "", modifiers: []).heldKeyName == "LEFT")
        #expect(ConsoleKeyPress(special: .function(5), charactersIgnoringModifiers: "", modifiers: []).heldKeyName == "F5")
        #expect(ConsoleKeyPress(special: nil, charactersIgnoringModifiers: "a", modifiers: [.shift]).heldKeyName == "A")
        #expect(ConsoleKeyPress(special: nil, charactersIgnoringModifiers: " ", modifiers: []).heldKeyName == "SPACE")
    }
}
