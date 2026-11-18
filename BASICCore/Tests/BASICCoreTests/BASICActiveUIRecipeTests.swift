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

/// The ActiveUI Click Counter and Master/Detail recipes (BASICRecipes'
/// `basic.activeui.counter` and `basic.activeui.masterdetail`), run headless.
///
/// Each program is read from its recipe folder as edited, with `{{NAME}}`
/// filled in the way a new project gets it; BASICRecipes' own tests hold the
/// compiled-in catalog to those folders.
@Suite("ActiveUI recipes, headless")
struct BASICActiveUIRecipeTests {
    /// Recipe folder `folder`'s program, as a project called `name` gets it.
    private func recipeProgram(_ folder: String, name: String) throws -> String {
        let code = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()   // BASICCoreTests
            .deletingLastPathComponent()   // Tests
            .deletingLastPathComponent()   // BASICCore
            .deletingLastPathComponent()   // Code
        let main = code.appendingPathComponent("BASICRecipes/Recipes/\(folder)/src/main.bas")
        return try String(contentsOf: main, encoding: .utf8).replacingOccurrences(of: "{{NAME}}", with: name)
    }

    /// Runs `source` until its window closes. `user` plays the user once the
    /// window is up, then the window closes.
    private func run(_ source: String, user: @escaping @Sendable (BASICSession) -> Void) throws -> RecordingAUIHost {
        let host = RecordingAUIHost()
        let session = BASICSession(host: host)
        host.onShow = { [weak session, weak host] window in
            if let session { user(session) }
            DispatchQueue.global().asyncAfter(deadline: .now() + 0.3) {
                host?.close(window)
                session?.postAUIEvent(kind: "close", source: window)
            }
        }
        session.program.loadSource(source)
        try session.runProgram()
        return host
    }

    /// The requests made once the window was up: what the user's actions did.
    private func afterShow(_ host: RecordingAUIHost) -> [BASICAUIRequest] {
        guard let shown = host.requests.firstIndex(of: .show(id: 1)) else { return [] }
        return Array(host.requests[shown...])
    }

    @Test("The Click Counter: \"Count: 0\" and Click me at 320 by 200, and two clicks count two")
    func clickCounter() throws {
        let host = try run(try recipeProgram("05-activeui-counter", name: "Clicks")) { session in
            session.postAUIEvent(kind: "click", source: 3, text: "Click me")
            session.postAUIEvent(kind: "click", source: 3, text: "Click me")
        }
        #expect(host.requests.prefix(3) == [
            .create(id: 1, kind: .window, arguments: ["Clicks"]),
            .create(id: 2, kind: .label, arguments: ["Count: 0"]),
            .create(id: 3, kind: .button, arguments: ["Click me"]),
        ])
        #expect(host.requests.contains(.add(parent: 1, child: 2)))
        #expect(host.requests.contains(.add(parent: 1, child: 3)))
        #expect(host.requests.contains(.setSize(id: 1, width: 320, height: 200)))
        #expect(afterShow(host).filter { if case .setText = $0 { true } else { false } } == [
            .setText(id: 2, text: "Count: 1"),
            .setText(id: 2, text: "Count: 2"),
        ])
        #expect(host.texts[2] == "Count: 2")
        #expect(host.output.isEmpty)
    }

    @Test("The Master/Detail: three items under \"Items\", the first shown, and a pick shows its title, summary and body")
    func masterDetail() throws {
        let host = try run(try recipeProgram("05-activeui-masterdetail", name: "Notes")) { session in
            session.postAUIEvent(kind: "select", source: 2, text: "The views", index: 2)
            session.postAUIEvent(kind: "select", source: 2, text: "The model", index: 1)
        }
        #expect(host.requests.prefix(5) == [
            .create(id: 1, kind: .window, arguments: ["Notes"]),
            .create(id: 2, kind: .list, arguments: []),
            .create(id: 3, kind: .label, arguments: [""]),
            .create(id: 4, kind: .label, arguments: [""]),
            .create(id: 5, kind: .label, arguments: [""]),
        ])
        // The master, "Items" over the list, beside the detail's three labels.
        #expect(host.requests.contains(.create(id: 6, kind: .stack, arguments: ["vertical"])))
        #expect(host.requests.contains(.create(id: 7, kind: .label, arguments: ["Items"])))
        #expect(host.requests.contains(.add(parent: 6, child: 7)))
        #expect(host.requests.contains(.add(parent: 6, child: 2)))
        #expect(host.requests.contains(.create(id: 9, kind: .stack, arguments: ["horizontal"])))
        #expect(host.requests.contains(.add(parent: 9, child: 6)))
        #expect(host.requests.contains(.add(parent: 9, child: 8)))
        for child in [3, 4, 5] { #expect(host.requests.contains(.add(parent: 8, child: child))) }
        #expect(host.requests.contains(.add(parent: 1, child: 9)))
        #expect(host.items[2] == [["Getting started"], ["The model"], ["The views"]])
        #expect(host.requests.contains(.select(id: 2, index: 0)))
        #expect(host.requests.contains(.setSize(id: 1, width: 760, height: 460)))

        // Before the window: the first item. Then each pick, in turn.
        let beforeShow = host.requests.prefix { $0 != .show(id: 1) }
        #expect(beforeShow.contains(.setText(id: 3, text: "Getting started")))
        #expect(beforeShow.contains(.setText(id: 4, text: "What this app is")))
        #expect(afterShow(host).filter { if case .setText = $0 { true } else { false } } == [
            .setText(id: 3, text: "The views"),
            .setText(id: 4, text: "ActiveUI from BASIC"),
            .setText(id: 5, text: "Two stacks hold the panes and AUIList the rows. A pick updates these labels."),
            .setText(id: 3, text: "The model"),
            .setText(id: 4, text: "Plain BASIC"),
            .setText(id: 5, text: "Each item is three strings. The views read them; they know nothing of ActiveUI."),
        ])
        #expect(host.output.isEmpty)
    }
}
