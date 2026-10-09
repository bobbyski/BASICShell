#if canImport(JavaScriptCore)
import BASICCompilerKit
import BASICCore
import BASICDialectTraditional
import BASICWasm
@testable import BASICWasmRunner
import Foundation
import Testing

/// BASIC-45: a program compiled to WebAssembly makes ActiveUI windows through
/// its host, as the interpreter does. Each test is one of BASICCore's
/// `BASICActiveUITests`, compiled, with the same program and the same answer;
/// the recording host stands in for BASICStudio.
@Suite("WebAssembly ActiveUI", .serialized)
struct WasmActiveUITests {
    /// Records every request and answers from what it was told, as BASICCore's
    /// `RecordingAUIHost` does. What the user does goes to the compiled
    /// program's queue.
    final class Windows: BASICAUIHost, @unchecked Sendable {
        private let lock = NSLock()
        private(set) var requests: [BASICAUIRequest] = []
        var texts: [Int: String] = [:]
        var items: [Int: [[String]]] = [:]
        var selection: [Int: Int] = [:]
        var openWindows: Set<Int> = []
        var dialogAnswer = 0
        /// The test's user: called when a window goes up, on the program's thread.
        var onShow: ((Int) -> Void)?

        func print(_ text: String, terminator: String) {}
        func printLine(_ text: String) {}
        func readLine(prompt: String) -> String? { nil }

        func close(_ id: Int) {
            lock.lock()
            openWindows.remove(id)
            lock.unlock()
        }

        func auiPerform(_ request: BASICAUIRequest) throws -> BASICAUIAnswer {
            lock.lock()
            requests.append(request)
            var showWindow: Int?
            defer {
                if let showWindow { onShow?(showWindow) }
            }
            defer { lock.unlock() }
            switch request {
            case .create(let id, let kind, let arguments):
                if kind == .label || kind == .field || kind == .date { texts[id] = arguments.first ?? "" }
            case .setText(let id, let text):
                texts[id] = text
            case .text(let id):
                return .text(texts[id] ?? "")
            case .addItem(let id, let cells):
                items[id, default: []].append(cells)
            case .clearItems(let id):
                items[id] = []
            case .itemCount(let id):
                return .number(Double(items[id]?.count ?? 0))
            case .selectedIndex(let id):
                return .number(Double(selection[id] ?? -1))
            case .selectedText(let id):
                guard let index = selection[id], let rows = items[id], rows.indices.contains(index) else { return .text("") }
                return .text(rows[index].first ?? "")
            case .show(let id):
                if case .create(_, .dialog, _)? = requests.first(where: { if case .create(id, _, _) = $0 { true } else { false } }) {
                    return .number(Double(dialogAnswer))
                }
                openWindows.insert(id)
                showWindow = id
            case .close(let id):
                openWindows.remove(id)
            case .isOpen(let id):
                return .flag(openWindows.contains(id))
            case .select(let id, let index):
                selection[id] = index
            default:
                break
            }
            return .none
        }
    }

    final class Console: WasmHost {
        var output = ""
        let windows: Windows?
        init(windows: Windows?) { self.windows = windows }
        func write(_ text: String) { output += text }
        func readLine(prompt: String) -> String? { nil }
        func inkey() -> String { "" }
        var activeUIHost: BASICAUIHost? { windows }
    }

    /// Compiles `source` as Studio does for a WebAssembly run, and runs it
    /// with `windows`.
    static func run(_ source: String, windows: Windows? = Windows(), stopAfter: Double? = nil) throws -> (WasmRunOutcome, String) {
        try WasmTranslatorTests.onLargeStack {
            var options = CompileOptions(emitDebugInfo: false)
            options.hostedActiveUI = true
            let compilation = Compilation(dialect: TraditionalDialect(), options: options)
            let ir = try compilation.dialect.lower(try compilation.bir(source: source, name: "test"), options: options).llvmIR
            let runner = WasmRunner(program: try WasmTranslator.translate(llvmIR: ir))
            if let stopAfter {
                DispatchQueue.global().asyncAfter(deadline: .now() + stopAfter) { runner.requestStop() }
            }
            let console = Console(windows: windows)
            let outcome = runner.run(host: console)
            return (outcome, console.output)
        }
    }

    @Test("Each class constructs through the host, with its arguments as text")
    func construction() throws {
        let windows = Windows()
        let (outcome, output) = try Self.run("""
        let w = AUIWindow("Contacts")
        let s = AUIStack("horizontal")
        let l = AUILabel("Count: 0")
        let b = NEW AUIButton("Click me")
        let f = AUIField("", "Name")
        let li = AUIList()
        let t = AUITable("Name", "Year")
        let d = AUIDialog("Delete?", "It cannot be undone.")
        print w.id(); ","; t.id()
        """, windows: windows)
        #expect(outcome == .finished(0))
        #expect(windows.requests.prefix(8) == [
            .create(id: 1, kind: .window, arguments: ["Contacts"]),
            .create(id: 2, kind: .stack, arguments: ["horizontal"]),
            .create(id: 3, kind: .label, arguments: ["Count: 0"]),
            .create(id: 4, kind: .button, arguments: ["Click me"]),
            .create(id: 5, kind: .field, arguments: ["", "Name"]),
            .create(id: 6, kind: .list, arguments: []),
            .create(id: 7, kind: .table, arguments: ["Name", "Year"]),
            .create(id: 8, kind: .dialog, arguments: ["Delete?", "It cannot be undone."]),
        ])
        #expect(output == "1,7\n", "\(output)")
    }

    @Test("Controls go into windows and stacks; texts and items round-trip")
    func methods() throws {
        let windows = Windows()
        windows.selection[4] = 1
        let (outcome, output) = try Self.run("""
        let w = AUIWindow("Demo")
        let s = AUIStack()
        let l = AUILabel("before")
        let li = AUIList()
        w.add(s)
        s.add(l)
        s.add(li)
        l.text("after")
        li.add("Ada")
        li.additem("Grace")
        print l.text$(); " "; li.count(); " "; li.selectedindex(); " "; li.selectedtext$()
        li.clear()
        print li.count()
        w.title("Renamed")
        """, windows: windows)
        #expect(outcome == .finished(0))
        #expect(windows.requests.contains(.add(parent: 1, child: 2)))
        #expect(windows.requests.contains(.add(parent: 2, child: 3)))
        #expect(windows.requests.contains(.setText(id: 1, text: "Renamed")))
        #expect(output == "after 2 1 Grace\n0\n", "\(output)")
    }

    @Test("A table's rows take a cell per column; enabled takes TRUE or FALSE")
    func tableAndEnabled() throws {
        let windows = Windows()
        let (outcome, _) = try Self.run("""
        let t = AUITable("Name", "Year")
        t.addrow("Ada", 1815)
        let b = AUIButton("Go")
        b.enabled(FALSE)
        """, windows: windows)
        #expect(outcome == .finished(0))
        #expect(windows.requests.contains(.addItem(id: 1, cells: ["Ada", "1815"])))
        #expect(windows.requests.contains(.setEnabled(id: 2, enabled: false)))
    }

    @Test("A control's own handler comes before ON AUI; run() delivers events until the window closes")
    func runDeliversEvents() throws {
        let windows = Windows()
        windows.onShow = { [weak windows] window in
            // The user: pick a list row, click twice, then close the window.
            BASICCompiledAUI.post(kind: "select", source: 3, text: "Grace", index: 1)
            BASICCompiledAUI.post(kind: "click", source: 2, text: "Go")
            BASICCompiledAUI.post(kind: "click", source: 2, text: "Go")
            DispatchQueue.global().asyncAfter(deadline: .now() + 0.2) {
                windows?.close(window)
                BASICCompiledAUI.post(kind: "close", source: window)
            }
        }
        let (outcome, output) = try Self.run("""
        GLOBAL clicks = 0
        let w = AUIWindow("Demo")
        let b = AUIButton("Go")
        let li = AUIList()
        w.add(b)
        w.add(li)
        b.onclick("Clicked")
        w.onclose("Closed")
        on aui select call Picked
        w.run()
        print "after run, clicks "; clicks

        function Clicked(event as BASICAUIEvent)
            clicks = clicks + 1
        end function

        function Picked(event as BASICAUIEvent)
            print "picked "; event.Text$; " at "; event.Index
        end function

        function Closed()
            print "closed"
        end function
        """, windows: windows)
        #expect(outcome == .finished(0))
        #expect(output == "picked Grace at 1\nclosed\nafter run, clicks 2\n", "\(output)")
    }

    @Test("A dialog's show answers the button pressed")
    func dialog() throws {
        let windows = Windows()
        windows.dialogAnswer = 1
        let (outcome, output) = try Self.run("""
        let d = AUIDialog("Delete?", "Really?")
        d.addbutton("Cancel")
        d.addbutton("Delete")
        print d.show()
        """, windows: windows)
        #expect(outcome == .finished(0))
        #expect(windows.requests.contains(.addButton(id: 1, title: "Delete")))
        #expect(output == "1\n", "\(output)")
    }

    @Test("Stop ends a run() that is waiting for the window")
    func stopWhileRunning() throws {
        let (outcome, output) = try Self.run("""
        let w = AUIWindow("Waiting")
        w.run()
        print "never"
        """, stopAfter: 0.3)
        #expect(outcome == .stopped)
        #expect(output.hasPrefix("Break at "), "\(output)")
    }

    @Test("Mistakes are named as the interpreter names them, and a host without windows says so")
    func errors() throws {
        let (badAxis, axisOutput) = try Self.run("let s = AUIStack(\"diagonal\")")
        #expect(badAxis == .failed)
        #expect(axisOutput.contains("vertical"), "\(axisOutput)")
        let (unknown, unknownOutput) = try Self.run("let b = AUIButton(\"x\")\nb.spin()")
        #expect(unknown == .failed)
        #expect(unknownOutput.contains("AUIButton has no method spin"), "\(unknownOutput)")
        let (none, noneOutput) = try Self.run("let w = AUIWindow(\"x\")", windows: nil)
        #expect(none == .failed)
        #expect(noneOutput.contains("BASICStudio"), "\(noneOutput)")
    }

    @Test("Without a host's windows, basicc refuses ActiveUI as it always has")
    func refusedNatively() throws {
        let compilation = Compilation(dialect: TraditionalDialect(), options: CompileOptions(emitDebugInfo: false))
        for source in ["let w = AUIWindow(\"x\")", "dim w as AUIWindow", "sub h(e as BASICAUIEvent)\nend sub"] {
            #expect(throws: CompileError.self) {
                _ = try WasmTranslatorTests.onLargeStack { try compilation.bir(source: source, name: "test") }
            }
        }
    }
}
#endif
