//
//  GraphicsTutorialTests.swift
//  BASICStudioTests
//
//  BASIC-36: every step of the graphics tutorial runs exactly as printed, and
//  draws and answers clicks the way the page says. The steps are read out of
//  the shipped manual. What a step draws is read back from the console's VTG
//  stream; clicks go in the way the console sends them, through the hit
//  regions the program laid.
//

import Foundation
import Testing
@testable import BASICStudio

@MainActor
@Suite("BASIC-36 · The graphics tutorial's steps run as printed", .serialized)
struct GraphicsTutorialTests {
    /// Every whole program on the page, in order: the seven steps.
    static func steps() throws -> [String] {
        let page = try #require(UserDoc.loadAll().first { $0.id == "TUTORIAL_GRAPHICS.md" }, "the tutorial ships")
        var programs: [String] = []
        var rest = Substring(page.content)
        while let open = rest.range(of: "```basic\n") {
            let body = rest[open.upperBound...]
            guard let close = body.range(of: "```") else { break }
            programs.append(String(body[..<close.lowerBound]))
            rest = body[close.upperBound...]
        }
        return programs
    }

    /// What is on the console's drawing board: every shape by name, and every
    /// hit region, as the VTG stream has left them.
    @MainActor
    final class Board {
        private var pending = ""
        private(set) var stream = ""
        private(set) var shapes: [String: String] = [:]
        private(set) var hits: [String: Region] = [:]

        struct Region: Equatable {
            let x, y, width, height: Int
            init(_ x: Int, _ y: Int, _ width: Int, _ height: Int) {
                (self.x, self.y, self.width, self.height) = (x, y, width, height)
            }
        }

        func take(_ data: Data) {
            let text = String(decoding: data, as: UTF8.self)
            stream += text
            pending += text
            while let open = pending.range(of: "\u{1B}_VTG;"),
                  let close = pending.range(of: "\u{1B}\\", range: open.upperBound..<pending.endIndex) {
                apply(String(pending[open.upperBound..<close.lowerBound]))
                pending = String(pending[close.upperBound...])
            }
        }

        private func apply(_ command: String) {
            let head = command.split(separator: ";", maxSplits: 1).first.map(String.init) ?? command
            let fields = Self.fields(head)
            switch head.split(separator: ",").first {
            case "clear":
                shapes.removeAll()
            case "delete":
                if let id = fields["id"] { shapes[id] = nil }
            case "hit":
                if let id = fields["id"], let x = fields["x"].flatMap(Int.init), let y = fields["y"].flatMap(Int.init),
                   let width = fields["w"].flatMap(Int.init), let height = fields["h"].flatMap(Int.init) {
                    hits[id] = Region(x, y, width, height)
                }
            default:
                if let id = fields["id"] { shapes[id] = command }
            }
        }

        static func fields(_ head: String) -> [String: String] {
            var fields: [String: String] = [:]
            for part in head.split(separator: ",") {
                let pair = part.split(separator: "=", maxSplits: 1)
                if pair.count == 2 { fields[String(pair[0])] = String(pair[1]) }
            }
            return fields
        }

        /// The strokes of each letter `vectorPrint` drew under `id`, in order:
        /// it names them `id-letter-stroke`.
        func letters(_ id: String) -> [[[(x: Int, y: Int)]]] {
            var strokes: [Int: [Int: [(x: Int, y: Int)]]] = [:]
            for (name, command) in shapes {
                guard name.hasPrefix(id + "-") else { continue }
                let numbers = name.dropFirst(id.count + 1).split(separator: "-")
                guard numbers.count == 2, let letter = Int(numbers[0]), let stroke = Int(numbers[1]),
                      let points = command.split(separator: ";", maxSplits: 1).last else { continue }
                strokes[letter, default: [:]][stroke] = points.split(separator: " ").compactMap { point in
                    let xy = point.split(separator: ",").compactMap { Int($0) }
                    return xy.count == 2 ? (xy[0], xy[1]) : nil
                }
            }
            return strokes.keys.sorted().map { letter in strokes[letter]!.keys.sorted().map { strokes[letter]![$0]! } }
        }
    }

    /// The vector letters at the sizes the page uses, drawn once, so a word
    /// on the board can be read back: each letter's strokes, measured from
    /// its first point, are the same wherever it is drawn.
    static var alphabet: [String: Character] = [:]

    static func signature(_ letter: [[(x: Int, y: Int)]]) -> String {
        guard let origin = letter.first?.first else { return "" }
        return letter.map { stroke in stroke.map { "\($0.x - origin.x),\($0.y - origin.y)" }.joined(separator: " ") }
            .joined(separator: "|")
    }

    private func learnAlphabet() async throws {
        guard Self.alphabet.isEmpty else { return }
        let reference = """
        all$ = ""
        FOR c = 33 TO 126
            all$ = all$ + CHR$(c)
        NEXT c
        vtg = VectorTerminal()
        vtg.vectorPrint("big", 0, 0, 21, all$, "#ffffff", 2)
        vtg.vectorPrint("small", 0, 100, 14, all$, "#ffffff", 1)
        """
        let studio = StudioHarness(program: reference)
        let board = Board()
        studio.model.vtgDataSink = { board.take($0) }
        try await studio.run()
        try await studio.waitUntil("the letters to be drawn") { board.letters("small").count == 94 }
        for id in ["big", "small"] {
            for (offset, letter) in board.letters(id).enumerated() {
                let character = Character(UnicodeScalar(UInt8(33 + offset)))
                // Lowercase may share a capital's strokes; the first, the capital, wins.
                if Self.alphabet[Self.signature(letter)] == nil {
                    Self.alphabet[Self.signature(letter)] = character
                }
            }
        }
    }

    /// The words drawn under `id`, without spaces, as capitals.
    private func read(_ id: String, on board: Board) -> String {
        String(board.letters(id).map { Self.alphabet[Self.signature($0)] ?? "?" }).uppercased()
    }

    /// Runs `program` with its drawing read onto a board.
    private func start(_ program: String) -> (StudioHarness, Board) {
        let studio = StudioHarness(program: program)
        let board = Board()
        studio.model.vtgDataSink = { board.take($0) }
        studio.model.runEditorProgram()
        return (studio, board)
    }

    private func press(_ key: String, in studio: StudioHarness) {
        studio.model.handleTerminalInput([.append(key)])
    }

    /// A click in the middle of the hit region `id`, as the console sends one.
    private func click(_ id: String, on board: Board, in studio: StudioHarness) throws {
        let region = try #require(board.hits[id], "no hit region \(id)")
        try click(atX: Double(region.x + region.width / 2), y: Double(region.y + region.height / 2), in: studio)
    }

    private func click(atX x: Double, y: Double, in studio: StudioHarness) throws {
        let hit = studio.model.hitRegion(atX: x, y: y)
        for (subtype, buttons) in [("DOWN", 1), ("UP", 0)] {
            studio.model.postVTGMouseEvent(subtype: subtype, x: x, y: y, button: 0, buttons: buttons, duration: 0,
                                           hitID: hit?.id ?? "", target: hit?.target ?? "")
        }
    }

    /// Clicks the calculator's button `id` and waits for the display to be
    /// drawn again, as every click on a button does: clicks that reach the
    /// program together are merged, as a fast hand's would be.
    private func press(_ id: String, on board: Board, in studio: StudioHarness) async throws {
        let drawn = board.stream.components(separatedBy: "draw,id=number-0-0,").count
        try click(id, on: board, in: studio)
        try await studio.waitUntil("the display after \(id)") {
            board.stream.components(separatedBy: "draw,id=number-0-0,").count > drawn
        }
    }

    /// Waits until the program's `ON MOUSE UP` is registered: a click before
    /// then is not the program's to hear.
    private func listening(_ studio: StudioHarness) async throws {
        try await studio.waitUntil("the program to listen for clicks") {
            studio.model.session.acceptsHostInputEvent(type: "MOUSE", subtype: "UP")
        }
    }

    /// Presses a key and waits for the program to finish, leaving the board
    /// clear and, unless an error was the point, the console without one.
    private func finish(_ studio: StudioHarness, _ board: Board, expectingError: Bool = false) async throws {
        press("q", in: studio)
        try await studio.waitUntilStopped()
        #expect(board.shapes.isEmpty, "the closing CLS clears the board")
        if !expectingError {
            #expect(!studio.model.consoleText.contains("error"), "\(studio.model.consoleText)")
        }
    }

    @Test("The page has its seven steps")
    func sevenSteps() throws {
        #expect(try Self.steps().count == 7)
    }

    @Test("Step 1: four lines make the box, the circle is in its middle, and a key finishes")
    func boxAndCircle() async throws {
        let (studio, board) = start(try Self.steps()[0])
        try await studio.waitUntil("the circle") { board.stream.contains("circle,") }
        #expect(studio.model.consoleText.contains("Press any key to finish."))
        for line in ["x1=40,y1=60,x2=240,y2=60", "x1=240,y1=60,x2=240,y2=180", "x1=240,y1=180,x2=40,y2=180", "x1=40,y1=180,x2=40,y2=60"] {
            #expect(board.shapes.values.contains { $0.hasPrefix("line,") && $0.contains(line) && $0.contains("#22c55e") }, "\(line)")
        }
        #expect(board.shapes.values.contains { $0.hasPrefix("circle,") && $0.contains("cx=140,cy=120,r=40") })
        try await finish(studio, board)
    }

    @Test("Step 2: a filled box and ball, by name")
    func namedShapes() async throws {
        let (studio, board) = start(try Self.steps()[1])
        try await studio.waitUntil("the ball") { board.shapes["ball"] != nil }
        #expect(board.shapes["box"]?.contains("rect,id=box,x=40,y=60,w=200,h=120,stroke=#22c55e,fill=#0f172a,width=2") == true)
        #expect(board.shapes["ball"]?.contains("cx=140,cy=120,r=40,stroke=#60a5fa,fill=#60a5fa") == true)
        try await finish(studio, board)
    }

    @Test("Step 3: each key moves the one ball along; the fourth takes it away")
    func movingBall() async throws {
        let (studio, board) = start(try Self.steps()[2])
        for x in [80, 120, 160, 200] {
            try await studio.waitUntil("the ball at \(x)") { board.shapes["ball"]?.contains("cx=\(x),") == true }
            #expect(board.shapes.keys.sorted() == ["ball", "box"], "one ball, replaced, not added")
            press("m", in: studio)
        }
        try await studio.waitUntil("the ball to go") { studio.model.consoleText.contains("The ball has gone.") }
        #expect(board.shapes.keys.sorted() == ["box"])
        try await finish(studio, board)
    }

    @Test("Step 4: a captioned button with a hit region over it, and a click does nothing yet")
    func button() async throws {
        try await learnAlphabet()
        let (studio, board) = start(try Self.steps()[3])
        try await studio.waitUntil("the hit region") { board.hits["button-hit"] != nil }
        #expect(read("caption", on: board) == "PRESSME")
        #expect(board.shapes["caption-0-0"]?.contains(";56,") == true, "the caption starts at x = 56")
        #expect(board.hits["button-hit"] == Board.Region(40, 60, 200, 60))
        let before = board.shapes
        try click("button-hit", on: board, in: studio)
        try await Task.sleep(for: .milliseconds(300))
        #expect(board.shapes.keys.sorted() == before.keys.sorted())
        try await finish(studio, board)
    }

    @Test("Step 5: clicks on the button are counted; a click beside it is not")
    func listening() async throws {
        try await learnAlphabet()
        let (studio, board) = start(try Self.steps()[4])
        try await studio.waitUntil("the hit region") { board.hits["button-hit"] != nil }
        try await listening(studio)
        try click("button-hit", on: board, in: studio)
        try await studio.waitUntil("Clicks: 1") { read("count", on: board) == "CLICKS:1" }
        try click("button-hit", on: board, in: studio)
        try await studio.waitUntil("Clicks: 2") { read("count", on: board) == "CLICKS:2" }
        try click(atX: 300, y: 300, in: studio)
        try await Task.sleep(for: .milliseconds(300))
        #expect(read("count", on: board) == "CLICKS:2")
        try await finish(studio, board)
    }

    @Test("Step 6: digits build the number, C clears it")
    func digits() async throws {
        try await learnAlphabet()
        let (studio, board) = start(try Self.steps()[5])
        try await studio.waitUntil("the buttons") { board.hits.count == 11 }
        try await listening(studio)
        #expect(read("number", on: board) == "0")
        #expect(board.hits["key7"] == Board.Region(40, 130, 60, 50), "7 at the top left")
        #expect(board.hits["key0"] == Board.Region(110, 310, 60, 50), "0 at the bottom, in the middle")
        for (key, shown) in [("key1", "1"), ("key2", "12"), ("key3", "123"), ("keyC", "0"), ("key0", "0"), ("key7", "7")] {
            try await press(key, on: board, in: studio)
            #expect(read("number", on: board) == shown, "after \(key)")
        }
        try await finish(studio, board)
    }

    @Test("Step 7: 12 + 3 × 2 = 30, one sum at a time; / 4 = 7.5; a long answer shrinks to fit")
    func calculator() async throws {
        try await learnAlphabet()
        let (studio, board) = start(try Self.steps()[6])
        try await studio.waitUntil("the buttons") { board.hits.count == 16 }
        try await listening(studio)
        let clicks: [(String, String)] = [
            ("key1", "1"), ("key2", "12"), ("plus", "12"), ("key3", "3"), ("times", "15"), ("key2", "2"), ("equals", "30"),
            ("divide", "30"), ("key4", "4"), ("equals", "7.5"),
            ("minus", "7.5"), ("key9", "9"), ("equals", "-1.5"), ("keyC", "0"),
        ]
        for (key, shown) in clicks {
            try await press(key, on: board, in: studio)
            #expect(read("number", on: board) == shown, "after \(key)")
        }

        // 1 / 3 has too many digits for 21-point letters: smaller ones fit it in.
        for key in ["key1", "divide", "key3", "equals"] {
            try await press(key, on: board, in: studio)
        }
        #expect(board.letters("number").count == 18, "0.3333333333333333")
        let xs = board.letters("number").flatMap { $0.flatMap { $0.map(\.x) } }
        #expect(xs.min()! > 40 && xs.max()! < 310, "inside the display")
        try await finish(studio, board)
    }

    @Test("Mistake: without present() the picture is the same in Studio")
    func noPresent() async throws {
        let step = try Self.steps()[1].replacingOccurrences(of: "vtg.present()\n", with: "")
        let (studio, board) = start(step)
        try await studio.waitUntil("the ball") { board.shapes["ball"] != nil }
        #expect(board.shapes["box"] != nil)
        try await finish(studio, board)
    }

    @Test("Mistake: a second shape called box replaces the first")
    func sameName() async throws {
        let line = "vtg.circle(\"box\", 140, 120, 40, \"#60a5fa\", \"#60a5fa\")"
        let page = try #require(UserDoc.loadAll().first { $0.id == "TUTORIAL_GRAPHICS.md" }).content
        #expect(page.contains(line), "the page prints this line")
        let step = try Self.steps()[1].replacingOccurrences(of: "vtg.circle(\"ball\"", with: "vtg.circle(\"box\"")
        let (studio, board) = start(step)
        try await studio.waitUntil("the circle") { board.stream.contains("circle,id=box") }
        #expect(board.shapes.keys.sorted() == ["box"])
        #expect(board.shapes["box"]?.hasPrefix("circle,") == true)
        try await finish(studio, board)
    }

    @Test("Mistake: a misspelled handler stops the program at once")
    func misspelledHandler() async throws {
        let step = try Self.steps()[4].replacingOccurrences(of: "ON MOUSE UP CALL Clicked", with: "ON MOUSE UP CALL Clickd")
        let (studio, _) = start(step)
        try await studio.waitUntilStopped()
        #expect(studio.model.consoleText.contains("Function Clickd is not defined"), "\(studio.model.consoleText)")
    }

    @Test("Mistake: a handler with no room for the event reports each click, and the program carries on")
    func noEvent() async throws {
        let step = try Self.steps()[4].replacingOccurrences(of: "FUNCTION Clicked(event AS BASICMouseEvent)", with: "FUNCTION Clicked()")
        let (studio, board) = start(step)
        try await studio.waitUntil("the hit region") { board.hits["button-hit"] != nil }
        try await listening(studio)
        try click("button-hit", on: board, in: studio)
        try await studio.waitUntil("the message") {
            studio.model.consoleText.contains("Runtime error: Function Clicked expects 0 arguments, got 1")
        }
        #expect(studio.model.isProgramRunning)
        #expect(!board.stream.contains("id=count-"))
        press("q", in: studio)
        try await studio.waitUntilStopped()
    }

    @Test("Mistake: while INPUT$ waits, clicks do nothing")
    func waitingWithInput() async throws {
        let loop = "WHILE INKEY$() = \"\"\n    rested = AWAIT Sleep(20)\nWEND\n"
        let source = try Self.steps()[4]
        #expect(source.contains(loop))
        let (studio, board) = start(source.replacingOccurrences(of: loop, with: "key$ = INPUT$(1)\n"))
        try await studio.waitUntil("the hit region") { board.hits["button-hit"] != nil }
        try await listening(studio)
        try click("button-hit", on: board, in: studio)
        try await Task.sleep(for: .milliseconds(500))
        #expect(!board.stream.contains("id=count-"), "no count while INPUT$ waits")
        try await finish(studio, board)
    }

    @Test("Mistake: 5 / 0 = reports Division by zero, the display keeps its 0, and C starts again")
    func divideByZero() async throws {
        try await learnAlphabet()
        let (studio, board) = start(try Self.steps()[6])
        try await studio.waitUntil("the buttons") { board.hits.count == 16 }
        try await listening(studio)
        for key in ["key5", "divide", "key0"] {
            try await press(key, on: board, in: studio)
        }
        try click("equals", on: board, in: studio)
        try await studio.waitUntil("the message") { studio.model.consoleText.contains("Runtime error: Division by zero") }
        #expect(read("number", on: board) == "0")
        #expect(studio.model.isProgramRunning)
        for (key, shown) in [("keyC", "0"), ("key8", "8")] {
            try await press(key, on: board, in: studio)
            #expect(read("number", on: board) == shown, "after \(key)")
        }
        try await finish(studio, board, expectingError: true)
    }
}
