//
//  ConsoleVTGReplyTests.swift
//  BASICStudioTests
//
//  On iOS, while a program reads the mouse, SwiftTerm answers every touch
//  with an xterm mouse report (`ESC [ < 0 ; 51 ; 25 M`) and may answer VTG
//  with an APC string (`ESC _VTG;mouse,…ESC \`), both sent back as terminal
//  input. Studio posts those events itself, so the console drops them: typed,
//  each tap reached the program as twenty-odd keys, an Escape among them
//  (seen in the iPad simulator, 2026-10-10).
//

import Foundation
import SwiftTerm
import Testing
@testable import BASICStudio

@MainActor
@Suite("The console drops the terminal's mouse reports", .serialized)
struct ConsoleVTGReplyTests {
    @Test("Mouse reports and VTG replies, even split across reads, type nothing; a key after them still arrives")
    func repliesAreNotKeys() async throws {
        let studio = StudioHarness(program: """
        PRINT "ready"
        k$ = ""
        WHILE k$ <> "x"
          k$ = INKEY$
          IF k$ <> "" THEN PRINT "key "; k$
        WEND
        """)
        let view = AIBasicTerminalContainerView()
        view.frame = NSRect(x: 0, y: 0, width: 640, height: 400)
        view.attach(to: studio.model)
        studio.model.runEditorProgram()
        try await studio.waitUntil("the program") { studio.model.consoleText.contains("ready\n") }

        let source = TerminalView(frame: .zero)
        let reply = Array("\u{1B}_VTG;mouse,type=down,button=0,x=412,y=300,cellX=52,cellY=19,mods=\u{1B}\\".utf8)
        view.send(source: source, data: reply[0..<20])
        view.send(source: source, data: reply[20...])
        view.send(source: source, data: Array("\u{1B}_VTG;resize,width=960,height=600\u{07}".utf8)[...])
        view.send(source: source, data: Array("\u{1B}[<0;51;25M".utf8)[...])
        view.send(source: source, data: Array("\u{1B}[<0;51;25m\u{1B}[<65;12;3M".utf8)[...])
        view.send(source: source, data: Array("\u{1B}[M !!".utf8)[...])
        view.send(source: source, data: Array("x".utf8)[...])
        try await studio.waitUntilStopped()
        #expect(studio.lastRunOutput.components(separatedBy: studio.model.prompt).first == "ready\nkey x\n",
                "\(studio.lastRunOutput)")
    }
}
