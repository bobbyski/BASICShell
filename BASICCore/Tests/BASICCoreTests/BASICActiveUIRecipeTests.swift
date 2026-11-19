//
//  BASICActiveUIRecipeTests.swift
//  BASICCoreTests
//
//  The ActiveUI starters in BASICRecipes, run by the interpreter with the
//  recording host standing in for BASICStudio and the test playing the user.
//

import BASICCore
import Foundation
import Testing

/// The ActiveUI Click Counter, To-Do List and Master/Detail recipes
/// (BASICRecipes' `basic.activeui.counter`, `basic.activeui` and
/// `basic.activeui.masterdetail`), run headless by the interpreter, which is
/// how BASICStudio runs them.
///
/// Each starter is split into files (`models/`, `views/`, `controllers/`,
/// `app/`), so it is copied from its recipe folder as edited, with `{{NAME}}`
/// filled in the way a new project gets it, into a scratch folder the host
/// reads its `IMPORT`s from and keeps its data in. BASICRecipes' own tests
/// hold the compiled-in catalog to those folders.
@Suite("ActiveUI recipes, headless")
struct BASICActiveUIRecipeTests {
    /// What one run of a starter left behind.
    struct Run {
        /// Every request the program made, and what it was answered.
        let host: RecordingAUIHost
        /// The scratch folder: `src/` holds the program, `data/` its data.
        let root: URL
    }

    /// Copies recipe `folder`'s `src/` into a scratch folder as a project
    /// called `name` gets it.
    private func scratchProject(_ folder: String, name: String) throws -> URL {
        let code = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()   // BASICCoreTests
            .deletingLastPathComponent()   // Tests
            .deletingLastPathComponent()   // BASICCore
            .deletingLastPathComponent()   // Code
        let source = code.appendingPathComponent("BASICRecipes/Recipes/\(folder)/src")
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("basic-aui-recipe-\(UUID().uuidString)")
        let files = try #require(FileManager.default.enumerator(at: source, includingPropertiesForKeys: nil))
        for case let file as URL in files where file.pathExtension == "bas" {
            let relative = String(file.path.dropFirst(source.path.count + 1))
            let target = root.appendingPathComponent("src/\(relative)")
            try FileManager.default.createDirectory(at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
            let text = try String(contentsOf: file, encoding: .utf8).replacingOccurrences(of: "{{NAME}}", with: name)
            try text.write(to: target, atomically: true, encoding: .utf8)
        }
        try FileManager.default.createDirectory(at: root.appendingPathComponent("data"), withIntermediateDirectories: true)
        return root
    }

    /// Runs recipe `folder` as `name` until its window closes. `user` plays
    /// the user once the window is up, then the window closes. `data` is
    /// written into the data folder first, as an earlier launch would have.
    private func run(_ folder: String, name: String, data: [String: String] = [:],
                     user: @escaping @Sendable (BASICSession, RecordingAUIHost) -> Void) throws -> Run {
        let root = try scratchProject(folder, name: name)
        for (file, text) in data {
            try text.write(to: root.appendingPathComponent("data/\(file)"), atomically: true, encoding: .utf8)
        }
        let recorder = RecordingAUIHost()
        let host = RecipeFileHost(recorder: recorder, root: root)
        let session = BASICSession(host: host)
        recorder.onShow = { [weak session, weak recorder] window in
            if let session, let recorder { user(session, recorder) }
            DispatchQueue.global().asyncAfter(deadline: .now() + 0.4) {
                recorder?.close(window)
                session?.postAUIEvent(kind: "close", source: window)
            }
        }
        // APP_DATA_DIR keeps the program's data in the scratch folder, never
        // in the real Application Support; the host refuses anything else.
        _ = session.submit("SETENV \"APP_DATA_DIR\", \"\(root.appendingPathComponent("data").path)\"")
        let main = root.appendingPathComponent("src/main.bas")
        session.program.loadSource(try String(contentsOf: main, encoding: .utf8), fileName: main.path)
        // On a lane with a big stack, as BASICStudio runs a program: the
        // interpreter recurses for every BASIC call, and a test's thread has
        // too little stack for a starter's calls within calls.
        let finished = DispatchSemaphore(value: 0)
        nonisolated(unsafe) var failure: Error?
        nonisolated(unsafe) let running = session
        BASICWorkerLane(label: "BASICActiveUIRecipeTests").submit {
            do { try running.runProgram() } catch { failure = error }
            finished.signal()
        }
        finished.wait()
        if let failure { throw failure }
        #expect(host.refusedPaths.isEmpty, "wrote outside the scratch folder: \(host.refusedPaths)")
        return Run(host: recorder, root: root)
    }

    /// The requests made before the window went up.
    private func beforeShow(_ host: RecordingAUIHost) -> [BASICAUIRequest] {
        Array(host.requests.prefix { $0 != .show(id: 1) })
    }

    /// The requests made once the window was up: what the user's actions did.
    private func afterShow(_ host: RecordingAUIHost) -> [BASICAUIRequest] {
        guard let shown = host.requests.firstIndex(of: .show(id: 1)) else { return [] }
        return Array(host.requests[shown...])
    }

    /// The id the program gave the control it made of `kind` with `arguments`.
    private func id(of kind: BASICAUIKind, _ arguments: [String], in host: RecordingAUIHost) throws -> Int {
        let found = host.requests.compactMap { request -> Int? in
            if case .create(let id, kind, arguments) = request { return id }
            return nil
        }
        return try #require(found.first, "no \(kind) \(arguments)")
    }

    /// Whether control `id` was last grayed out or enabled in `requests`.
    private func lastEnabled(_ id: Int, in requests: [BASICAUIRequest]) -> Bool? {
        for request in requests.reversed() {
            if case .setEnabled(id, let enabled) = request { return enabled }
        }
        return nil
    }

    // MARK: Click Counter

    @Test("The Click Counter: Reset grayed at zero, \"Count: 0\" and Click me at 320 by 200, and two clicks count two")
    func clickCounter() throws {
        let run = try run("05-activeui-counter", name: "Clicks") { session, _ in
            // Window 1, Reset 2, the label 3, Click me 4.
            session.postAUIEvent(kind: "click", source: 4, text: "Click me")
            session.postAUIEvent(kind: "click", source: 4, text: "Click me")
        }
        defer { try? FileManager.default.removeItem(at: run.root) }
        let host = run.host
        #expect(host.requests.filter { if case .create = $0 { true } else { false } }.prefix(4) == [
            .create(id: 1, kind: .window, arguments: ["Clicks"]),
            .create(id: 2, kind: .button, arguments: ["Reset"]),
            .create(id: 3, kind: .label, arguments: ["Count: 0"]),
            .create(id: 4, kind: .button, arguments: ["Click me"]),
        ])
        // Reset above the count, then the button, in the window's column.
        for child in [2, 3, 4] { #expect(host.requests.contains(.add(parent: 1, child: child))) }
        #expect(host.requests.contains(.setSize(id: 1, width: 320, height: 200)))
        #expect(lastEnabled(2, in: beforeShow(host)) == false, "Reset opens grayed out, at zero")
        #expect(afterShow(host).filter { if case .setText = $0 { true } else { false } } == [
            .setText(id: 3, text: "Count: 1"),
            .setText(id: 3, text: "Count: 2"),
        ])
        #expect(lastEnabled(2, in: afterShow(host)) == true, "Reset is enabled once there is a count")
        #expect(host.texts[3] == "Count: 2")
        #expect(host.output.isEmpty)
    }

    @Test("The Click Counter's Reset goes back to zero and grays itself out")
    func clickCounterReset() throws {
        let run = try run("05-activeui-counter", name: "Clicks") { session, _ in
            session.postAUIEvent(kind: "click", source: 4, text: "Click me")
            session.postAUIEvent(kind: "click", source: 2, text: "Reset")
        }
        defer { try? FileManager.default.removeItem(at: run.root) }
        #expect(run.host.texts[3] == "Count: 0")
        #expect(lastEnabled(2, in: afterShow(run.host)) == false)
    }

    // MARK: To-Do List

    @Test("The To-Do List: three sample tasks, \"2 to do · 1 done\", and Done and Delete grayed until a task is picked")
    func todoFirstLaunch() throws {
        let run = try run("05-activeui", name: "Tasks") { _, _ in }
        defer { try? FileManager.default.removeItem(at: run.root) }
        let host = run.host
        #expect(host.requests.first == .create(id: 1, kind: .window, arguments: ["Tasks"]))
        let newTask = try id(of: .button, ["New Task"], in: host)
        let done = try id(of: .button, ["Done"], in: host)
        let delete = try id(of: .button, ["Delete"], in: host)
        let clearDone = try id(of: .button, ["Clear Done"], in: host)
        let field = try id(of: .field, ["", "New task"], in: host)
        let list = try id(of: .list, [], in: host)
        // The commands come first, across the top, then the field, the list
        // and the status line.
        #expect([newTask, done, delete, clearDone] == [Int](3...6))
        #expect(field < list)
        #expect(host.items[list] == [["☐ Try this program"], ["☐ Pick a task, then press Done"], ["☑ Open the To-Do List"]])
        #expect(host.texts.values.contains("2 to do · 1 done"))
        let opening = beforeShow(host)
        #expect(lastEnabled(newTask, in: opening) == false, "New Task has nothing to add yet")
        #expect(lastEnabled(done, in: opening) == false, "Done opens grayed out: nothing is picked")
        #expect(lastEnabled(delete, in: opening) == false, "Delete opens grayed out: nothing is picked")
        #expect(lastEnabled(clearDone, in: opening) == true, "a sample task is done")
        #expect(host.requests.contains(.setSize(id: 1, width: 420, height: 460)))
        // Nothing changed, so nothing was written.
        #expect(!FileManager.default.fileExists(atPath: run.root.appendingPathComponent("data/tasks.txt").path))
    }

    @Test("The To-Do List's commands: a typed task, Done on a picked one, Delete, and Clear Done after asking; tasks.txt keeps them")
    func todoCommands() throws {
        // Window 1, the command bar 2, New Task 3, Done 4, Delete 5,
        // Clear Done 6, the field 7, the list 8.
        let run = try run("05-activeui", name: "Tasks") { session, host in
            host.texts[7] = "Buy milk"
            session.postAUIEvent(kind: "submit", source: 7, text: "Buy milk")
            session.postAUIEvent(kind: "select", source: 8, text: "☐ Try this program", index: 0)
            session.postAUIEvent(kind: "click", source: 4, text: "Done")
            session.postAUIEvent(kind: "select", source: 8, text: "☐ Pick a task, then press Done", index: 1)
            session.postAUIEvent(kind: "click", source: 5, text: "Delete")
            session.postAUIEvent(kind: "click", source: 6, text: "Clear Done")
        }
        defer { try? FileManager.default.removeItem(at: run.root) }
        let host = run.host
        #expect(try id(of: .list, [], in: host) == 8)
        let saved = try String(contentsOf: run.root.appendingPathComponent("data/tasks.txt"), encoding: .utf8)
        #expect(saved == "todo\tBuy milk\n", "after Clear Done only the typed task is left")
        #expect(host.items[8] == [["☐ Buy milk"]])
        #expect(host.texts.values.contains("1 to do · 0 done"))
        _ = try id(of: .dialog, ["Clear completed tasks?", "The done tasks are removed. This cannot be undone."], in: host)
        let after = afterShow(host)
        // Picking a task to do enabled Done; the Delete left nothing picked.
        #expect(after.contains(.setEnabled(id: 4, enabled: true)))
        #expect(lastEnabled(4, in: after) == false)
        #expect(lastEnabled(5, in: after) == false)
        #expect(lastEnabled(6, in: after) == false, "nothing is done once Clear Done has run")
        #expect(host.texts[7] == "", "the field empties once its task is added")
    }

    @Test("The To-Do List reads tasks.txt back, escapes and all")
    func todoReadsItsFile() throws {
        let run = try run("05-activeui", name: "Tasks", data: ["tasks.txt": "done\tTabs\\tand \\\\ slashes\ntodo\tSecond\n"]) { _, _ in }
        defer { try? FileManager.default.removeItem(at: run.root) }
        #expect(run.host.items[8] == [["☑ Tabs\tand \\ slashes"], ["☐ Second"]])
        #expect(run.host.texts.values.contains("1 to do · 1 done"))
    }

    // MARK: Master/Detail

    @Test("The Master/Detail: Favorites and Items, the first item chosen, and its title and notes beside the list")
    func masterDetailFirstLaunch() throws {
        let run = try run("05-activeui-masterdetail", name: "Notes") { _, _ in }
        defer { try? FileManager.default.removeItem(at: run.root) }
        let host = run.host
        #expect(host.requests.first == .create(id: 1, kind: .window, arguments: ["Notes"]))
        let newItem = try id(of: .button, ["New Item"], in: host)
        let favorite = try id(of: .button, ["Favorite"], in: host)
        let delete = try id(of: .button, ["Delete"], in: host)
        #expect([newItem, favorite, delete] == [Int](3...5))
        let search = try id(of: .field, ["", "Search"], in: host)
        let list = try id(of: .list, [], in: host)
        let title = try id(of: .field, ["", "Title"], in: host)
        #expect(search < list && list < title)
        #expect(host.items[list] == [["FAVORITES"], ["  ★ Getting started"], ["ITEMS"], ["  ▤ The model"], ["  ▤ The views"]])
        #expect(host.selection[list] == 1, "the first item's row is picked")
        #expect(host.texts[title] == "Getting started")
        #expect(host.texts.values.contains("Favorite"))
        // The master and the detail are two stacks side by side.
        _ = try id(of: .stack, ["horizontal"], in: host)
        let opening = beforeShow(host)
        #expect(lastEnabled(favorite, in: opening) == true)
        #expect(lastEnabled(delete, in: opening) == true)
        #expect(host.requests.contains(.setSize(id: 1, width: 760, height: 460)))
    }

    @Test("The Master/Detail's commands: a heading chooses nothing and grays Favorite and Delete; edits, New Item and Delete are kept in items.txt")
    func masterDetailCommands() throws {
        // Window 1, the bar 2, New Item 3, Favorite 4, Delete 5, the two
        // panes 6 and 7; the master: search 8, list 9; the detail: heading
        // 10, caption 11, title 12, notes 13.
        let run = try run("05-activeui-masterdetail", name: "Notes") { session, host in
            session.postAUIEvent(kind: "select", source: 9, text: "ITEMS", index: 2)
            session.postAUIEvent(kind: "select", source: 9, text: "  ▤ The model", index: 3)
            host.texts[12] = "The data"
            session.postAUIEvent(kind: "change", source: 12, text: "The data")
            session.postAUIEvent(kind: "click", source: 4, text: "Favorite")
            session.postAUIEvent(kind: "select", source: 9, text: "  ★ Getting started", index: 1)
            session.postAUIEvent(kind: "click", source: 5, text: "Delete")
            session.postAUIEvent(kind: "click", source: 3, text: "New Item")
        }
        defer { try? FileManager.default.removeItem(at: run.root) }
        let host = run.host
        #expect(try id(of: .list, [], in: host) == 9)
        #expect(try id(of: .field, ["", "Title"], in: host) == 12)
        let after = afterShow(host)
        // The heading row chose nothing: the empty state, Favorite and Delete grayed.
        #expect(after.contains(.setText(id: 10, text: "No Item Selected")))
        #expect(after.contains(.setEnabled(id: 4, enabled: false)))
        // The edit renamed the item in the list as it was typed.
        #expect(after.contains(.addItem(id: 9, cells: ["  ▤ The data"])))
        let saved = try String(contentsOf: run.root.appendingPathComponent("data/items.txt"), encoding: .utf8)
        #expect(saved.split(separator: "\n").map(String.init) == [
            "favorite\tThe data\tmodels/Item.bas, ItemList.bas and ItemStore.bas: plain BASIC, and the file.",
            "item\tThe views\tviews/ItemSidebarView.bas and views/ItemDetailView.bas show; the controller decides.",
            "item\t\t",
        ])
        #expect(host.items[9] == [["FAVORITES"], ["  ★ The data"], ["ITEMS"], ["  ▤ The views"], ["  ▤ Untitled"]])
        #expect(host.texts[10] == "Untitled", "New Item chose the new item")
        #expect(lastEnabled(5, in: after) == true)
    }

    @Test("The Master/Detail's search narrows the list, whatever the case")
    func masterDetailSearch() throws {
        let run = try run("05-activeui-masterdetail", name: "Notes") { session, host in
            host.texts[8] = "VIEW"
            session.postAUIEvent(kind: "change", source: 8, text: "VIEW")
        }
        defer { try? FileManager.default.removeItem(at: run.root) }
        #expect(run.host.items[9] == [["ITEMS"], ["  ▤ The views"]])
    }
}

/// The recording AUI host, with a file system: the program's `IMPORT`s and
/// data, all inside one scratch folder. A path outside it is refused and
/// noted, so a starter that wrote to the real Application Support fails.
final class RecipeFileHost: BASICAUIHost, BASICFileHost, @unchecked Sendable {
    /// Answers every AUI request and records it.
    let recorder: RecordingAUIHost
    /// The only folder the program may read or write.
    let root: URL
    /// The paths the program tried outside `root`.
    private(set) var refusedPaths: [String] = []
    /// Where a relative path starts.
    private var currentDirectory: String

    init(recorder: RecordingAUIHost, root: URL) {
        self.recorder = recorder
        self.root = root.resolvingSymlinksInPath()
        currentDirectory = self.root.appendingPathComponent("src").path
    }

    func print(_ text: String, terminator: String) { recorder.print(text, terminator: terminator) }
    func printLine(_ text: String) { recorder.printLine(text) }
    func readLine(prompt: String) -> String? { nil }
    func auiPerform(_ request: BASICAUIRequest) throws -> BASICAUIAnswer { try recorder.auiPerform(request) }

    /// `path` made absolute and checked to be inside `root`.
    private func inside(_ path: String) throws -> String {
        let absolute = path.hasPrefix("/") ? path : (currentDirectory as NSString).appendingPathComponent(path)
        let resolved = URL(fileURLWithPath: absolute).standardizedFileURL.resolvingSymlinksInPath().path
        guard resolved == root.path || resolved.hasPrefix(root.path + "/") else {
            refusedPaths.append(path)
            throw BASICError.runtime("outside the test's folder: \(path)")
        }
        return resolved
    }

    func loadTextFile(path: String) throws -> String { try String(contentsOfFile: try inside(path), encoding: .utf8) }
    func saveTextFile(path: String, text: String) throws { try text.write(toFile: try inside(path), atomically: true, encoding: .utf8) }
    func loadFileData(path: String) throws -> Data { try Data(contentsOf: URL(fileURLWithPath: try inside(path))) }
    func saveFileData(path: String, data: Data) throws { try data.write(to: URL(fileURLWithPath: try inside(path))) }
    func fileExists(path: String) throws -> Bool { FileManager.default.fileExists(atPath: try inside(path)) }
    func currentDirectoryPath() throws -> String { currentDirectory }
    func changeDirectory(path: String) throws { currentDirectory = try inside(path) }
    func listFiles() throws -> [String] { try listFiles(path: currentDirectory) }
    func listFiles(path: String) throws -> [String] { try FileManager.default.contentsOfDirectory(atPath: try inside(path)).sorted() }
    func listDirectory(path: String) throws -> [String] { try listFiles(path: path) }
    func isDirectory(path: String) throws -> Bool {
        var directory: ObjCBool = false
        return FileManager.default.fileExists(atPath: try inside(path), isDirectory: &directory) && directory.boolValue
    }
    func createDirectory(path: String) throws {
        try FileManager.default.createDirectory(atPath: try inside(path), withIntermediateDirectories: true)
    }
    func removePath(path: String) throws { try FileManager.default.removeItem(atPath: try inside(path)) }
    func renamePath(from source: String, to destination: String) throws {
        try FileManager.default.moveItem(atPath: try inside(source), toPath: try inside(destination))
    }
}
