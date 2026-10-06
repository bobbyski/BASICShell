//
//  BASICGraphicsOnStopOptionTests.swift
//  BASICCoreTests
//
//  OPTION GRAPHICS-ON-STOP: what a host does with a program's graphics when
//  the program stops on a break or an error (BASIC-28). BASICShell reads it.
//

import Testing
@testable import BASICCore

@Suite("OPTION GRAPHICS-ON-STOP", .serialized)
struct BASICGraphicsOnStopOptionTests {
    @Test("Hiding is the default, and each value sets it")
    func values() {
        let session = BASICSession(host: TestHost())
        #expect(session.graphicsOnStop == .hide)

        session.submit("OPTION GRAPHICS-ON-STOP CLEAR")
        #expect(session.graphicsOnStop == .clear)
        session.submit("option graphics-on-stop keep")
        #expect(session.graphicsOnStop == .keep)
        session.submit("OPTION GRAPHICS-ON-STOP HIDE")
        #expect(session.graphicsOnStop == .hide)
    }

    @Test("A program can set it too, and it lasts after the run")
    func fromAProgram() throws {
        let session = BASICSession(host: TestHost())
        session.program.loadSource("OPTION GRAPHICS-ON-STOP KEEP\nPRINT 1")
        try session.runProgram()
        #expect(session.graphicsOnStop == .keep)
    }

    @Test("Anything else says what it takes")
    func badValue() {
        let host = TestHost()
        let session = BASICSession(host: host)
        session.submit("OPTION GRAPHICS-ON-STOP MAYBE")
        #expect(host.output.joined(separator: "\n").contains("Expected HIDE, CLEAR, or KEEP after OPTION GRAPHICS-ON-STOP"))
        #expect(session.graphicsOnStop == .hide)
    }
}
