//
//  BASICActiveUITests.swift
//  BASICCoreTests
//
//  The ActiveUI pseudo classes, driven with no window (ACTIVEUI_TRANSITION.md
//  P6.5). A recording host stands in for BASICStudio, so a failure here is
//  the binding's and not ActiveUI's.
//

import BASICCore
import Foundation
import Testing

/// Records every request, and answers from what it was told: the texts set,
/// the items added, a scripted selection, and windows that close when the
/// test says so.
final class RecordingAUIHost: BASICAUIHost, @unchecked Sendable {
    private let lock = NSLock()
    private var pendingLine = ""
    private(set) var output: [String] = []
    private(set) var requests: [BASICAUIRequest] = []
    var texts: [Int: String] = [:]
    var items: [Int: [[String]]] = [:]
    var selection: [Int: Int] = [:]
    var openWindows: Set<Int> = []
    var dialogAnswer = 0
    /// The test's user: called when a window goes up, on the program's thread.
    var onShow: ((Int) -> Void)?

    func print(_ text: String, terminator: String) {
        lock.lock()
        defer { lock.unlock() }
        pendingLine += text + terminator
        while let newline = pendingLine.firstIndex(of: "\n") {
            output.append(String(pendingLine[..<newline]))
            pendingLine = String(pendingLine[pendingLine.index(after: newline)...])
        }
    }

    func printLine(_ text: String) {
        print(text, terminator: "\n")
    }

    func readLine(prompt: String) -> String? {
        nil
    }

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
            if kind == .label || kind == .field { texts[id] = arguments.first ?? "" }
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
            guard let index = selection[id], let row = items[id]?[index] else { return .text("") }
            return .text(row.first ?? "")
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
        case .add, .setEnabled, .addButton:
            break
        }
        return .none
    }
}

@Suite("ActiveUI pseudo classes, headless")
struct BASICActiveUITests {
    private func run(_ source: String, host: RecordingAUIHost = RecordingAUIHost()) throws -> (RecordingAUIHost, BASICSession) {
        let session = BASICSession(host: host)
        session.program.loadSource(source)
        try session.runProgram()
        return (host, session)
    }

    @Test("P6.1 · Each class constructs through the host, with its arguments as text")
    func construction() throws {
        let (host, _) = try run("""
        let w = AUIWindow("Contacts")
        let s = AUIStack("horizontal")
        let l = AUILabel("Count: 0")
        let b = NEW AUIButton("Click me")
        let f = AUIField("", "Name")
        let li = AUIList()
        let t = AUITable("Name", "Year")
        let d = AUIDialog("Delete?", "It cannot be undone.")
        print w.id(); ","; t.id()
        """)
        #expect(host.requests.prefix(8) == [
            .create(id: 1, kind: .window, arguments: ["Contacts"]),
            .create(id: 2, kind: .stack, arguments: ["horizontal"]),
            .create(id: 3, kind: .label, arguments: ["Count: 0"]),
            .create(id: 4, kind: .button, arguments: ["Click me"]),
            .create(id: 5, kind: .field, arguments: ["", "Name"]),
            .create(id: 6, kind: .list, arguments: []),
            .create(id: 7, kind: .table, arguments: ["Name", "Year"]),
            .create(id: 8, kind: .dialog, arguments: ["Delete?", "It cannot be undone."]),
        ])
        #expect(host.output == ["1,7"])
    }

    @Test("P6.1 · Controls go into windows and stacks; texts and items round-trip")
    func methods() throws {
        let host = RecordingAUIHost()
        host.selection[4] = 1
        let (_, _) = try run("""
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
        """, host: host)
        #expect(host.requests.contains(.add(parent: 1, child: 2)))
        #expect(host.requests.contains(.add(parent: 2, child: 3)))
        #expect(host.requests.contains(.setText(id: 1, text: "Renamed")))
        #expect(host.output == ["after 2 1 Grace", "0"])
    }

    @Test("P6.1 · A table's rows take a cell per column; enabled takes TRUE or FALSE")
    func tableAndEnabled() throws {
        let (host, _) = try run("""
        let t = AUITable("Name", "Year")
        t.addrow("Ada", 1815)
        let b = AUIButton("Go")
        b.enabled(FALSE)
        """)
        #expect(host.requests.contains(.addItem(id: 1, cells: ["Ada", "1815"])))
        #expect(host.requests.contains(.setEnabled(id: 2, enabled: false)))
    }

    @Test("P6.1 · Mistakes are named: a window in a window, a bad axis, an unknown method, no windows at all")
    func errors() throws {
        func failure(_ source: String, host: BASICHost = RecordingAUIHost()) -> String {
            let session = BASICSession(host: host)
            session.program.loadSource(source)
            do {
                try session.runProgram()
                return "no error"
            } catch {
                return "\(error)"
            }
        }
        #expect(failure("let w = AUIWindow(\"a\")\nlet v = AUIWindow(\"b\")\nw.add(v)").contains("expects a control"))
        #expect(failure("let s = AUIStack(\"diagonal\")").contains("vertical"))
        #expect(failure("let b = AUIButton(\"x\")\nb.spin()").contains("AUIButton has no method spin"))
        #expect(failure("let l = AUILabel(\"x\")\nl.onclick(\"H\")").contains("no click"))
        #expect(failure("let w = AUIWindow(\"x\")", host: TextHost()).contains("BASICStudio"))
    }

    @Test("P6.1 · DIM … AS a class holds nothing until assigned")
    func dimAs() throws {
        let (host, _) = try run("""
        DIM w AS AUIWindow
        w = AUIWindow("Late")
        w.show()
        """)
        #expect(host.requests.last == .show(id: 1))
    }

    @Test("P6.2 · ON AUI CLICK CALL gets a BASICAUIEvent: Source, Text$, Index; every click arrives")
    func onAUIEvents() throws {
        let host = RecordingAUIHost()
        let session = BASICSession(host: host)
        let control = BASICExecutionControl()
        let pause = BASICBreakpointLocation(lineNumber: 4, statementNumber: 0)
        control.setBreakpoints([BASICBreakpoint(location: pause)])
        session.program.loadSource("""
        let b = AUIButton("Go")
        on aui click call Clicked
        print "ready"
        yield
        print "done"

        function Clicked(event as BASICAUIEvent)
            print event.Type + ":" + event.Subtype + ":" + str$(event.Source) + ":" + event.Text$ + ":" + str$(event.Index)
        end function
        """)
        do {
            try session.runProgram(executionControl: control)
            Issue.record("expected the breakpoint at yield")
        } catch BASICError.breakpoint {}
        session.postAUIEvent(kind: "click", source: 1, text: "Go")
        session.postAUIEvent(kind: "click", source: 1, text: "Go")
        control.ignoreBreakpointOnce(at: pause)
        try session.continueProgram(executionControl: control)
        #expect(host.output == ["ready", "AUI:CLICK: 1:Go:-1", "AUI:CLICK: 1:Go:-1", "done"])
    }

    @Test("P6.2 · A control's own handler comes before ON AUI; run() delivers events until the window closes")
    func runDeliversEvents() throws {
        let host = RecordingAUIHost()
        let session = BASICSession(host: host)
        host.onShow = { [weak session, weak host] window in
            // The user: pick a list row, click twice, then close the window.
            session?.postAUIEvent(kind: "select", source: 3, text: "Grace", index: 1)
            session?.postAUIEvent(kind: "click", source: 2, text: "Go")
            session?.postAUIEvent(kind: "click", source: 2, text: "Go")
            DispatchQueue.global().asyncAfter(deadline: .now() + 0.2) {
                host?.close(window)
                session?.postAUIEvent(kind: "close", source: window)
            }
        }
        session.program.loadSource("""
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
        """)
        try session.runProgram()
        #expect(host.output == ["picked Grace at 1", "closed", "after run, clicks 2"])
    }

    @Test("P6.1 · A dialog's show answers the button pressed")
    func dialog() throws {
        let host = RecordingAUIHost()
        host.dialogAnswer = 1
        let (_, _) = try run("""
        let d = AUIDialog("Delete?", "Really?")
        d.addbutton("Cancel")
        d.addbutton("Delete")
        print d.show()
        """, host: host)
        #expect(host.requests.contains(.addButton(id: 1, title: "Delete")))
        #expect(host.output == ["1"])
    }

    @Test("P6.1 · Stop reaches a program waiting in run()")
    func stopReachesRun() throws {
        let host = RecordingAUIHost()
        let session = BASICSession(host: host)
        let control = BASICExecutionControl()
        host.onShow = { _ in
            DispatchQueue.global().asyncAfter(deadline: .now() + 0.1) { control.requestBreak() }
        }
        session.program.loadSource("""
        let w = AUIWindow("Forever")
        w.run()
        print "not reached"
        """)
        do {
            try session.runProgram(executionControl: control)
            Issue.record("expected the break")
        } catch BASICError.breakRequested {}
        #expect(!host.output.contains("not reached"))
    }
}

/// A host with no windows, as BASICShell is.
final class TextHost: BASICHost {
    func print(_ text: String, terminator: String) {}
    func printLine(_ text: String) {}
    func readLine(prompt: String) -> String? { nil }
}
