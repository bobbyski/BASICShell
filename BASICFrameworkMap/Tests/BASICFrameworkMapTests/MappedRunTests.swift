#if canImport(JavaScriptCore)
import BASICCompilerKit
import BASICDialectSwift
import BASICFrameworkMap
import BASICWasm
import BASICWasmRunner
import Foundation
import Testing

/// Programs that `IMPORT` ActiveUI and TUIKit, compiled by the Swift
/// dialect's mapped mode and run as WebAssembly, the map's entries answering
/// every member (BASIC-45, slice 11) — what Studio does on an iPad, with no
/// swiftc and no framework build.
@Suite("Mapped imports run as WebAssembly", .serialized)
struct MappedRunTests {
    final class Console: WasmHost {
        var output = ""
        var services: WasmHostServices {
            var services = WasmHostServices()
            services.entries = BASICFrameworkMap.entries
            return services
        }
        func write(_ text: String) { output += text }
        func readLine(prompt: String) -> String? { nil }
        func inkey() -> String { "" }
    }

    static let imports = SwiftMappedImports(
        frameworks: BASICFrameworkMap.frameworks.map {
            SwiftMappedImports.Framework(module: $0.module, symbolGraph: $0.symbolGraph.path, exported: $0.exported.path)
        },
        shims: Set(BASICFrameworkMap.entries.keys))

    /// The LLVM IR a program becomes, mapped.
    static func llvmIR(_ source: String) throws -> String {
        var options = CompileOptions(emitDebugInfo: false)
        options.hostedActiveUI = true
        let loaded = try imports.load(source: source, path: nil, name: "test", options: options)
        return try SwiftDialect(mappedImports: loaded.imports).lower(loaded.module, options: options).llvmIR
    }

    /// Compiles and runs a program on a thread of its own, as Studio does;
    /// the main thread stays free for the framework.
    static func run(_ source: String) throws -> (WasmRunOutcome, String) {
        nonisolated(unsafe) var outcome: Result<(WasmRunOutcome, String), Error>?
        let done = DispatchSemaphore(value: 0)
        let thread = Thread {
            outcome = Result {
                let program = try WasmTranslator.translate(llvmIR: try llvmIR(source))
                let console = Console()
                let missing = WasmRunner.missingImports(of: program, extra: console.services.entries)
                guard missing.isEmpty else { return (.notLoaded(missing.joined(separator: ", ")), "") }
                let ended = WasmRunner(program: program).run(host: console)
                return (ended, console.output)
            }
            done.signal()
        }
        thread.stackSize = 64 << 20
        thread.start()
        done.wait()
        return try outcome!.get()
    }

    @Test("The mapped IR names no Swift symbol, metadata or calling convention")
    func irIsPlain() throws {
        let ir = try Self.llvmIR("""
        IMPORT "ActiveUI"
        DIM Caption AS AUILabel
        Caption = NEW AUILabel("Hello")
        PRINT Caption.text
        """)
        #expect(!ir.contains("swiftcc"))
        #expect(!ir.contains("swiftself"))
        #expect(!ir.contains("%swift.type"))
        #expect(ir.contains("@basic_new_AUILabel_1("))
        #expect(ir.contains("@\"basic_get_AUILabel_text\"(") || ir.contains("@basic_get_AUILabel_text("))
        #expect(ir.contains("@basic_classid_ActiveUI("))
    }

    @Test("ActiveUI's own classes: NEW, properties, enums, statics, records, boxes, methods")
    func activeUICatalog() throws {
        let (outcome, output) = try Self.run("""
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
        #expect(outcome == .finished(0), "\(output)")
        #expect(output == """
        label text: Hello from BASIC
        bold: TRUE
        text now: Changed
        alignment: center
        padding: 8 16
        red is dark: TRUE
        button title: Press me
        spacing: 20
        alias: Changed

        """)
    }

    /// A BASIC class inheriting ActiveUI's `AUIView` (slice 11d): made as
    /// the map's forwarding class, its own fields in its record, the base's
    /// properties the framework's, and its override called by ActiveUI —
    /// `refresh()` calls `refreshSelf()` on every view below it.
    @Test("A BASIC class inheriting AUIView: own fields, the base's properties, an override ActiveUI calls")
    func inheritAUIView() throws {
        let (outcome, output) = try Self.run("""
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
        #expect(outcome == .finished(0), "\(output)")
        #expect(output == """
        hidden TRUE
        refreshed 2, count 2
        badge at  2
        called from BASIC: 3

        """)
    }

    /// TUIKit's `TUIView` inherited, its `layoutSubviews` overridden: TUIKit
    /// calls BASIC from `layoutIfNeeded`.
    @Test("A BASIC class inheriting TUIView: TUIKit calls its layoutSubviews")
    func inheritTUIView() throws {
        let (outcome, output) = try Self.run("""
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
        #expect(outcome == .finished(0), "\(output)")
        #expect(output == "laid out 1 level 10\n")
    }

    /// TUIKit's exhibit (R5.1): an `App` on a headless terminal, a BASIC
    /// closure TUIKit schedules and calls back while BASIC is inside
    /// `App.run` — run on the run's thread while it waits — and the frame
    /// read back.
    @Test("TUIKit's App runs, calls BASIC back inside run, and stops")
    func tuiKitExhibit() throws {
        let (outcome, output) = try Self.run("""
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
        #expect(outcome == .finished(0), "\(output)")
        #expect(output == "TUIKit drew8 lines\ntooltip shown: TRUE\n")
    }
}
#endif
