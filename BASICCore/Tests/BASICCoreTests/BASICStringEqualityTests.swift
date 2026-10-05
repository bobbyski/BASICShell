//
//  BASICStringEqualityTests.swift
//  BASICCoreTests
//
//  Strings are equal when their contents are, however each was made: CHR$
//  makes bytes and a literal makes text, and CHR$(65) is "A".
//

import Foundation
import Testing
@testable import BASICCore

@Suite("String equality")
struct BASICStringEqualityTests {
    @Test("Text and bytes with the same contents are the same string")
    func textAndBytes() throws {
        let a = try BASICString.character(code: 65)
        let carriageReturn = try BASICString.character(code: 13)
        let b = try BASICString.character(code: 66)
        #expect(BASICString("A") == a)
        #expect(BASICString("\r") == carriageReturn)
        #expect(BASICString("AB") == BASICString(rawData: Data([65, 66])))
        #expect(BASICString("A") != BASICString(rawData: Data([65, 0])))
        #expect(BASICString("A") != b)
    }

    @Test("CHR$ equals the literal in =, <>, and SELECT CASE")
    func inPrograms() {
        let host = TestHost()
        let session = BASICSession(host: host)
        session.program.loadSource("""
        PRINT (CHR$(65) = "A"); (CHR$(65) <> "A"); ("A" = CHR$(65)); ("A" + CHR$(0) = "A")
        SELECT CASE "Q"
        CASE CHR$(81)
            PRINT "CASE"
        CASE ELSE
            PRINT "ELSE"
        END SELECT
        """)
        session.submit("RUN")
        let text = host.output.joined().filter { $0 != " " }
        #expect(text.contains("1010"), "\(text)")
        #expect(text.contains("CASE"), "\(text)")
    }

    @Test("Return from INKEY$ is CHR$(13), which is how a program asks for it")
    func returnKey() {
        let host = TestHost()
        host.keys = ["\r"]
        let session = BASICSession(host: host)
        session.program.loadSource("""
        k$ = INKEY$
        IF k$ = CHR$(13) THEN PRINT "RETURN" ELSE PRINT "OTHER"; ASC(k$)
        """)
        session.submit("RUN")
        #expect(host.output.joined().contains("RETURN"), "\(host.output)")
    }
}
