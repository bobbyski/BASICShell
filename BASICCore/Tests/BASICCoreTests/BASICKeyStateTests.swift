//
//  BASICKeyStateTests.swift
//  BASICCoreTests
//
//  KEYDOWN: whether a key is held, from the host or from what INKEY$ sees.
//

import Foundation
import Testing
@testable import BASICCore

/// A host that sees keys go down and come up, as Studio's console does.
private final class KeyStateTestHost: BASICHost, BASICKeyStateHost {
    var output: [String] = []
    var held: Set<String> = []

    func print(_ text: String, terminator: String) { output.append(text) }
    func printLine(_ text: String) { output.append(text) }
    func readLine(prompt: String) -> String? { nil }
    func isKeyDown(_ name: String) -> Bool? { held.contains(name) }
}

@Suite("KEYDOWN and key names")
struct BASICKeyStateTests {
    @Test("Every spelling of a key comes down to one name")
    func names() {
        #expect(BASICKeyName.canonical("LEFT") == "LEFT")
        #expect(BASICKeyName.canonical("left") == "LEFT")
        #expect(BASICKeyName.canonical("[K") == "LEFT")
        #expect(BASICKeyName.canonical("[!K") == "LEFT")
        #expect(BASICKeyName.canonical("\u{0}K") == "LEFT")
        #expect(BASICKeyName.canonical("\u{1B}[D") == "LEFT")
        #expect(BASICKeyName.canonical("[H") == "UP")
        #expect(BASICKeyName.canonical("[F5") == "F5")
        #expect(BASICKeyName.canonical("\u{0};") == "F1")
        #expect(BASICKeyName.canonical("a") == "A")
        #expect(BASICKeyName.canonical(",") == ",")
        #expect(BASICKeyName.canonical(" ") == "SPACE")
        #expect(BASICKeyName.canonical("\r") == "ENTER")
        #expect(BASICKeyName.canonical("Return") == "ENTER")
        #expect(BASICKeyName.canonical("ctrl") == "CONTROL")
        #expect(BASICKeyName.canonical("page up") == "PAGEUP")
        #expect(BASICKeyName.canonical("NOSUCHKEY") == nil)
        #expect(BASICKeyName.canonical("") == nil)
    }

    @Test("A key INKEY$ saw once counts as held long enough to bridge the repeat delay")
    func estimateOnePress() {
        var estimate = BASICHeldKeyEstimate()
        estimate.saw("LEFT", at: 10)
        #expect(estimate.isDown("LEFT", at: 10.4))
        #expect(!estimate.isDown("LEFT", at: 10.6))
        #expect(!estimate.isDown("RIGHT", at: 10.1))
    }

    @Test("A repeating key stops counting soon after its repeats stop")
    func estimateRepeats() {
        var estimate = BASICHeldKeyEstimate()
        estimate.saw("LEFT", at: 10)
        estimate.saw("LEFT", at: 10.45)
        estimate.saw("LEFT", at: 10.5)
        #expect(estimate.isDown("LEFT", at: 10.6))
        #expect(!estimate.isDown("LEFT", at: 10.7))
    }

    @Test("KEYDOWN asks a host that knows")
    func fromTheHost() {
        let host = KeyStateTestHost()
        host.held = ["LEFT", "A"]
        let session = BASICSession(host: host)
        session.program.loadSource("""
        PRINT KEYDOWN("LEFT"); KEYDOWN("[K"); KEYDOWN("a"); KEYDOWN("RIGHT")
        IF KEYDOWN("LEFT") AND NOT KEYDOWN("UP") THEN PRINT "TURNING"
        """)
        session.submit("RUN")
        let text = host.output.joined().filter { $0 != " " }
        #expect(text.contains("1110"), "\(text)")
        #expect(text.contains("TURNING"))
    }

    @Test("Without one, KEYDOWN counts what INKEY$ has just seen")
    func fromINKEY() {
        let host = TestHost()
        host.keys = ["\u{1B}[D"]
        let session = BASICSession(host: host)
        session.program.loadSource("""
        PRINT KEYDOWN("LEFT")
        K$ = INKEY$
        PRINT KEYDOWN("LEFT"); KEYDOWN("RIGHT")
        """)
        session.submit("RUN")
        #expect(host.output.joined(separator: "|").contains("0"))
        let lines = host.output.filter { !$0.isEmpty }
        #expect(lines.first?.trimmingCharacters(in: .whitespaces) == "0", "\(lines)")
        #expect(lines.last?.replacingOccurrences(of: " ", with: "") == "10", "\(lines)")
    }

    @Test("A key KEYDOWN does not know is an error")
    func unknownKey() {
        let host = TestHost()
        let session = BASICSession(host: host)
        session.program.loadSource("PRINT KEYDOWN(\"NOSUCHKEY\")")
        session.submit("RUN")
        #expect(host.output.joined().contains("KEYDOWN does not know the key"))
    }
}
