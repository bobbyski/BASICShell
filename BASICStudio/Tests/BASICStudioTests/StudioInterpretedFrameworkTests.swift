//
//  StudioInterpretedFrameworkTests.swift
//  BASICStudioTests
//
//  BASIC-45, slice 11e: ▶ Run of a program that imports ActiveUI or TUIKit.
//  The interpreter calls the same entries ⚡ does, through the same shims, so
//  each program here runs both ways in one Studio and must print the same —
//  the text MappedRunTests holds a WebAssembly run to.
//

import ActiveUI
import Foundation
import Testing
@testable import BASICStudio

@MainActor
@Suite("BASIC-45 · ▶ Run imports ActiveUI and TUIKit through ⚡'s shims", .serialized)
struct StudioInterpretedFrameworkTests {
    /// What the last run started by `echo` printed, without the prompt it
    /// left.
    private func output(after echo: String, in studio: StudioHarness) -> String {
        let console = studio.model.consoleText
        guard let range = console.range(of: echo + "\n", options: .backwards) else { return console }
        return String(console[range.upperBound...]).components(separatedBy: studio.model.prompt).first ?? ""
    }

    /// `program` run with ▶, then with ⚡ as WebAssembly: what each printed.
    private func bothWays(_ program: String) async throws -> (interpreted: String, compiled: String) {
        let studio = StudioHarness(program: program)
        studio.model.runEditorProgram()
        try await studio.waitUntilStopped(timeout: .seconds(60))
        let interpreted = output(after: "RUN", in: studio)
        studio.model.compiledRunTarget = .webAssembly
        studio.model.jitEditorProgram()
        try await studio.waitUntil("the WebAssembly run", timeout: .seconds(90)) { !studio.model.isJITRunning }
        return (interpreted, output(after: "JIT", in: studio))
    }

    @Test("ActiveUI's own classes: NEW, properties, enums, statics, records, boxes, methods")
    func activeUICatalog() async throws {
        let (interpreted, compiled) = try await bothWays("""
        IMPORT "ActiveUI"
        DIM Caption AS AUILabel
        Caption = NEW AUILabel("Hello from BASIC")
        PRINT "label text: "; Caption.text
        Caption.isBold = TRUE
        PRINT "bold: "; Caption.isBold
        Caption.text = "Changed"
        PRINT "text now: "; Caption.text
        Caption.alignment = AUILabel_Alignment.center
        PRINT "alignment: "; Caption.alignment
        DIM Insets AS AUIEdgeInsets
        Insets.top = 8
        Insets.leading = 16
        Caption.padding = Insets
        DIM Back AS AUIEdgeInsets
        Back = Caption.padding
        PRINT "padding: "; Back.top; " "; Back.leading
        DIM Red AS AUIColor
        Red = NEW AUIColor(1, 0, 0, 1)
        PRINT "red is dark: "; Red.isDark
        DIM Go AS AUIButton
        Go = NEW AUIButton("Press me")
        PRINT "button title: "; Go.title
        DIM Column AS AUIStack
        Column = NEW AUIStack(AUIStack_Axis.vertical, 12, AUIStack_CrossAxisAlignment.leading, AUIStack_LayoutMode.flow)
        Column.addChild(Caption)
        Column.addChild(Go)
        Column.spacing = 20
        PRINT "spacing: "; Column.spacing
        DIM Again AS AUILabel
        Again = Caption
        PRINT "alias: "; Again.text
        """)
        let expected = """
        label text: Hello from BASIC
        bold: TRUE
        text now: Changed
        alignment: center
        padding: 8 16
        red is dark: TRUE
        button title: Press me
        spacing: 20
        alias: Changed

        """
        #expect(interpreted == expected)
        #expect(compiled == interpreted)
    }

    @Test("A BASIC class inheriting AUIView: own fields, the base's properties, an override ActiveUI calls")
    func inheritAUIView() async throws {
        let (interpreted, compiled) = try await bothWays("""
        IMPORT "ActiveUI"
        GLOBAL refreshed = 0
        CLASS Badge
          INHERITS AUIView
          PUBLIC count AS DOUBLE
          PUBLIC caption AS STRING
          OVERRIDES FUNCTION refreshSelf() AS VOID
            refreshed = refreshed + 1
            ME.count = ME.count + 1
          END FUNCTION
          FUNCTION describe() AS STRING
            RETURN ME.caption + " at " + STR$(ME.count)
          END FUNCTION
        END CLASS
        DIM B AS Badge
        B = NEW Badge()
        B.caption = "badge"
        B.isHidden = TRUE
        PRINT "hidden "; B.isHidden
        DIM Column AS AUIStack
        Column = NEW AUIStack(AUIStack_Axis.vertical, 12, AUIStack_CrossAxisAlignment.leading, AUIStack_LayoutMode.flow)
        Column.addChild(B)
        Column.refresh()
        Column.refresh()
        PRINT "refreshed "; refreshed; ", count "; B.count
        PRINT B.describe()
        B.refreshSelf()
        PRINT "called from BASIC: "; B.count
        """)
        let expected = """
        hidden TRUE
        refreshed 2, count 2
        badge at  2
        called from BASIC: 3

        """
        #expect(interpreted == expected)
        #expect(compiled == interpreted)
    }

    @Test("Handlers that answer: a toggle's, a label's and a progress bar's providers get BASIC's value")
    func providers() async throws {
        let (interpreted, compiled) = try await bothWays("""
        IMPORT "ActiveUI"
        GLOBAL asked = 0
        FUNCTION Lights() AS BOOLEAN
          asked = asked + 1
          RETURN TRUE
        END FUNCTION
        DIM T AS AUIToggle
        T = NEW AUIToggle("Lights", FALSE)
        T.isOnProvider = FUNCTION() AS BOOLEAN = Lights()
        T.refresh()
        PRINT "toggle on: "; T.isOn; ", asked "; asked
        DIM L AS AUILabel
        L = NEW AUILabel("before")
        L.textProvider = FUNCTION() AS STRING = "from " + "BASIC"
        L.refresh()
        PRINT "label: "; L.text
        DIM P AS AUIProgressBar
        P = NEW AUIProgressBar(0, 1)
        P.valueProvider = FUNCTION() AS DOUBLE = 0.25
        P.refresh()
        PRINT "progress: "; P.value
        """)
        #expect(interpreted == "toggle on: TRUE, asked 1\nlabel: from BASIC\nprogress: 0.25\n")
        #expect(compiled == interpreted)
    }

    @Test("A BASIC class inheriting TUIView: TUIKit calls its layoutSubviews")
    func inheritTUIView() async throws {
        let (interpreted, compiled) = try await bothWays("""
        IMPORT "TUIKit"
        GLOBAL laid = 0
        CLASS Meter
          INHERITS TUIView
          PUBLIC level AS DOUBLE
          OVERRIDES FUNCTION layoutSubviews() AS VOID
            laid = laid + 1
            ME.level = ME.level + 10
          END FUNCTION
        END CLASS
        DIM M AS Meter
        M = NEW Meter(0, 0, 20, 4)
        M.setNeedsLayout()
        M.layoutIfNeeded()
        PRINT "laid out "; laid; " level "; M.level
        """)
        #expect(interpreted == "laid out 1 level 10\n")
        #expect(compiled == interpreted)
    }

    @Test("TUIKit's App runs, calls BASIC back inside run, and stops")
    func tuiKitExhibit() async throws {
        let (interpreted, compiled) = try await bothWays("""
        IMPORT "TUIKit"
        DIM D AS HeadlessDriver
        D = NEW HeadlessDriver(40, 8, FALSE)
        DIM A AS App
        A = NEW App(D, NULL)
        DIM W AS Window
        W = NEW Window(0, 0, 40, 8)
        FUNCTION Finish() AS DOUBLE
          W.showTooltip("Hello from BASIC", 2, 2)
          A.stop()
          RETURN 0
        END FUNCTION
        A.schedule(50, FUNCTION() AS DOUBLE = Finish())
        A.run(W)
        DIM Lines AS VARIANT
        Lines = D.snapshotText()
        PRINT "TUIKit drew"; LEN(Lines); " lines"
        DIM Found AS BOOLEAN
        FOR I = 0 TO LEN(Lines) - 1
          IF INSTR(Lines(I), "Hello from BASIC") > 0 THEN Found = TRUE
        NEXT I
        PRINT "tooltip shown: "; Found
        """)
        #expect(interpreted == "TUIKit drew8 lines\ntooltip shown: TRUE\n")
        #expect(compiled == interpreted)
    }

    @Test("AUIApplication.run opens a window of Studio's; a BASIC handler runs while it waits")
    func applicationWindow() async throws {
        let studio = StudioHarness(program: """
        IMPORT "ActiveUI"
        GLOBAL clicks = 0
        DIM Caption AS AUILabel
        Caption = NEW AUILabel("Ready")
        DIM Go AS AUIButton
        Go = NEW AUIButton("Count")
        FUNCTION Clicked() AS DOUBLE
          clicks = clicks + 1
          Caption.text = "clicked"
          RETURN 0
        END FUNCTION
        Go.onClick = FUNCTION() AS DOUBLE = Clicked()
        DIM Column AS AUIStack
        Column = NEW AUIStack(AUIStack_Axis.vertical, 12, AUIStack_CrossAxisAlignment.leading, AUIStack_LayoutMode.flow)
        Column.addChild(Caption)
        Column.addChild(Go)
        PRINT "label "; Caption.text
        AUIApplication.run(Column, AUIRootPlacement.centered)
        PRINT "closed with "; clicks; " clicks, label "; Caption.text
        """)
        let bridge = studio.model.auiBridge
        bridge.showsWindows = false
        studio.model.runEditorProgram()
        try await studio.waitUntil("the app's window", timeout: .seconds(60)) { bridge.appWindows.count == 1 }
        let app = try #require(bridge.appWindows.first)
        let button = try #require(app.root.children.compactMap { $0 as? AUIButton }.first)
        let label = try #require(app.root.children.compactMap { $0 as? AUILabel }.first)
        #expect(studio.model.consoleText.contains("label Ready"), "\(studio.model.consoleText.suffix(300))")
        button.onClick?()
        button.onClick?()
        try await studio.waitUntil("the handler") { label.text == "clicked" }
        bridge.closeAppWindow(app.window)
        try await studio.waitUntilStopped(timeout: .seconds(20))
        #expect(output(after: "RUN", in: studio) == "label Ready\nclosed with 2 clicks, label clicked\n")
        #expect(bridge.appWindows.isEmpty)
    }

    @Test("Stop ends a program waiting in AUIApplication.run")
    func stopWhileWaiting() async throws {
        let studio = StudioHarness(program: """
        IMPORT "ActiveUI"
        DIM Caption AS AUILabel
        Caption = NEW AUILabel("Waiting")
        AUIApplication.run(Caption, AUIRootPlacement.centered)
        PRINT "not reached"
        """)
        let bridge = studio.model.auiBridge
        bridge.showsWindows = false
        studio.model.runEditorProgram()
        try await studio.waitUntil("the app's window", timeout: .seconds(60)) { bridge.appWindows.count == 1 }
        studio.model.stopProgram()
        try await studio.waitUntilStopped(timeout: .seconds(20))
        #expect(!studio.model.consoleText.contains("not reached"))
        try await studio.waitUntil("the window to close") { bridge.appWindows.isEmpty }
    }

    @Test("A framework's error is a BASIC error: reported as the interpreter's are, and ON ERROR catches it")
    func frameworkError() async throws {
        let studio = StudioHarness(program: """
        IMPORT "ActiveUI"
        DIM Caption AS AUILabel
        Caption = NEW AUILabel("x")
        Caption.noSuchThing = 1
        PRINT "not reached"
        """)
        try await studio.run(timeout: .seconds(60))
        let reported = output(after: "RUN", in: studio)
        #expect(reported.contains("noSuchThing") && !reported.contains("not reached"), "\(reported)")

        studio.model.programText = """
        IMPORT "ActiveUI"
        DIM Caption AS AUILabel
        Caption = NEW AUILabel("x")
        ON ERROR GOTO Caught
        Caption.noSuchThing = 1
        PRINT "not reached"
        END
        Caught:
        PRINT "caught at"; ERL
        """
        try await studio.run(timeout: .seconds(60))
        let caught = output(after: "RUN", in: studio)
        #expect(caught.filter { $0 != " " } == "caughtat5\n", "\(caught)")
    }

    @Test("The editor knows an imported framework's classes: INHERITS AUIView is no error, an unknown base still is")
    func editorChecks() {
        let studio = StudioHarness(program: """
        IMPORT "ActiveUI"
        CLASS Badge
          INHERITS AUIView
          OVERRIDES FUNCTION refreshSelf() AS VOID
          END FUNCTION
        END CLASS
        """)
        studio.model.rebuildProgramFromEditor()
        #expect(studio.model.editorDiagnostics.isEmpty, "\(studio.model.editorDiagnostics)")
        studio.model.programText = studio.model.programText.replacingOccurrences(of: "AUIView", with: "AUINoSuchView")
        studio.model.rebuildProgramFromEditor()
        #expect(!studio.model.editorDiagnostics.isEmpty)
    }
}
