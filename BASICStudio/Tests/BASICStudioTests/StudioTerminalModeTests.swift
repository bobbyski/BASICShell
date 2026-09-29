//
//  StudioTerminalModeTests.swift
//  BASICStudioTests
//
//  The modes a program sets in the console's terminal end with it.
//

import Foundation
import Testing
@testable import BASICStudio

@MainActor
@Suite("Terminal modes end with the program", .serialized)
struct StudioTerminalModeTests {
    @Test("ON MOUSE's reporting is turned off when the program ends, so clicks at the prompt are not typed in")
    func mouseReportingEndsWithTheProgram() async throws {
        let studio = StudioHarness(program: """
        on mouse call Clicked
        print "UP"
        end

        function Clicked(event as variant)
        end function
        """)
        var sent = ""
        studio.model.vtgDataSink = { sent += String(decoding: $0, as: UTF8.self) }
        try await studio.run()
        try await studio.waitUntil("mouse reporting to be turned off") {
            sent.contains("mouseEvents,enabled=0")
        }

        let on = try #require(sent.range(of: "mouseEvents,enabled=1", options: .backwards), "the program turned it on")
        let off = try #require(sent.range(of: "mouseEvents,enabled=0", options: .backwards))
        #expect(on.upperBound <= off.lowerBound, "the last word is off")
        #expect(sent.hasSuffix("resizeEvents,enabled=0\u{1B}\\"))
        #expect(sent.contains("\u{1B}[?1000l") && sent.contains("\u{1B}[?1006l"))
    }
}
