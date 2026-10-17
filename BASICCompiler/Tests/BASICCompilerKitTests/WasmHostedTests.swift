#if canImport(JavaScriptCore)
import BASICCompilerKit
import BASICCore
import BASICDialectTraditional
import BASICWasm
@testable import BASICWasmRunner
import Foundation
import Testing
import VectorTerminalSDK

/// BASIC-45: what BASICStudio gives a program it runs as WebAssembly beyond
/// its console — the canvas, the events its console posts, the keys it sees
/// held, its size, and its touch controls — reaches the program as it does
/// an interpreted one.
@Suite("WebAssembly host services", .serialized)
struct WasmHostedTests {
    /// What the canvas was sent, as text.
    final class Stream: @unchecked Sendable {
        private let lock = NSLock()
        private var data = Data()
        func append(_ more: Data) { lock.lock(); data.append(more); lock.unlock() }
        var text: String { lock.lock(); defer { lock.unlock() }; return String(decoding: data, as: UTF8.self) }
    }

    /// The touch screen: what was placed, and a stick held to the right.
    final class Touch: BASICTouchControlsHost, @unchecked Sendable {
        var placed: [BASICTouchControl] = []
        /// Off: the person turned the on-screen controls off, and the screen
        /// still takes touch.
        var controlsShown = true
        var touchControlsAvailable: Bool { controlsShown }
        var hasTouchScreen: Bool { true }
        func placeTouchControl(_ control: BASICTouchControl) { placed.append(control) }
        func removeTouchControl(id: String) {}
        func clearTouchControls() { placed = [] }
        func touchControlState(id: String) -> BASICTouchControlState {
            BASICTouchControlState(x: id == "stick" ? 1 : 0, y: 0, held: id == "fire")
        }
        func takeTouchWheelTurn(id: String) -> Double { 0 }
    }

    final class Console: WasmHost {
        var output = ""
        let services: WasmHostServices
        init(services: WasmHostServices) { self.services = services }
        func write(_ text: String) { output += text }
        func readLine(prompt: String) -> String? { nil }
        func inkey() -> String { "" }
    }

    static func run(_ source: String, services: WasmHostServices, whileRunning: (() -> Void)? = nil) throws -> (WasmRunOutcome, String) {
        try WasmTranslatorTests.onLargeStack {
            var options = CompileOptions(emitDebugInfo: false)
            options.hostedActiveUI = true
            let compilation = Compilation(dialect: TraditionalDialect(), options: options)
            let ir = try compilation.dialect.lower(try compilation.bir(source: source, name: "test"), options: options).llvmIR
            let runner = WasmRunner(program: try WasmTranslator.translate(llvmIR: ir))
            if let whileRunning {
                DispatchQueue.global().asyncAfter(deadline: .now() + 0.2, execute: whileRunning)
            }
            let console = Console(services: services)
            let outcome = runner.run(host: console)
            return (outcome, console.output)
        }
    }

    @Test("Graphics draw on the host's canvas, which says its own size")
    func canvas() throws {
        let stream = Stream()
        let canvas = VectorTerminalCanvas.hostValidated(output: ClosureVTGOutput { stream.append($0) })
        let (outcome, output) = try Self.run("""
        let vtg = VectorTerminal()
        vtg.clear()
        vtg.line("diagonal", 10, 20, 300, 200, "#5eead4", 3)
        vtg.present()
        print vtg.canvasWidth(); "x"; vtg.canvasHeight()
        size = vtg.queryCurrentCanvas()
        print size("width"); "x"; size("height")
        pset (5, 6), 2
        """, services: WasmHostServices(canvas: canvas, canvasSize: { (width: 800, height: 600) }))
        #expect(outcome == .finished(0), "\(output)")
        #expect(output == "800x600\n800x600\n", "\(output)")
        #expect(stream.text.contains("_VTG;line,id=diagonal,x1=10,y1=20,x2=300,y2=200"), "\(stream.text.prefix(400))")
        #expect(stream.text.contains("_VTG;pixel,"), "PSET draws on the same canvas")
        #expect(!stream.text.hasSuffix("_VTG;clear\u{1B}\\\u{1B}_VTG;present\u{1B}\\"), "the picture stays when the program ends, as an interpreted one's does")
    }

    @Test("The console's events reach ON … CALL; KEYDOWN and SCREENWIDTH are the host's")
    func eventsKeysAndSize() throws {
        let (outcome, output) = try Self.run("""
        GLOBAL done = 0
        on mouse down call Pressed
        on resize call Resized
        print screenwidth; "x"; screenheight; " "; keydown("LEFT"); keydown("A")
        while done < 2
            yield
        wend
        print "done"

        function Pressed(e as BASICMouseEvent)
            print "mouse "; e.x; ","; e.y; " button "; e.Button
            done = done + 1
        end function

        function Resized(e as BASICResizeEvent)
            print "resize "; e.Width; "x"; e.Height
            done = done + 1
        end function
        """, services: WasmHostServices(
            screenSize: { (columns: 132, rows: 43) },
            keyDown: { name in name == "LEFT" }
        ), whileRunning: {
            BASICCompiledEvents.post(type: "MOUSE", subtype: "DOWN", fields: [
                "type": .string("MOUSE"), "subtype": .string("DOWN"),
                "x": .number(12), "y": .number(34), "button": .number(0),
            ])
            BASICCompiledEvents.post(type: "RESIZE", subtype: "", fields: [
                "type": .string("RESIZE"), "width": .number(1024), "height": .number(768),
            ], coalesces: true)
        })
        #expect(outcome == .finished(0), "\(output)")
        #expect(output == "132x43 10\nmouse 12,34 button 0\nresize 1024x768\ndone\n", "\(output)")
    }

    @Test("TouchControls places its controls on the host's screen and reads them back")
    func touchControls() throws {
        let touch = Touch()
        let (outcome, output) = try Self.run("""
        let touch = TouchControls()
        print touch.Available()
        touch.Joystick("stick", "BOTTOMRIGHT", 40, 40, 160)
        touch.Button("fire", "BOTTOMLEFT", 40, 40, 90, "FIRE", "#ff3b30")
        print touch.X("stick"); touch.Held("fire"); touch.Held("stick")
        """, services: WasmHostServices(touchControls: touch))
        #expect(outcome == .finished(0), "\(output)")
        #expect(output == "TRUE\n1TRUEFALSE\n", "\(output)")
        #expect(touch.placed.map(\.id) == ["stick", "fire"])
    }

    @Test("HASTOUCH is the host's screen, controls shown or not, and 0 without a host (BASIC-70)")
    func hasTouch() throws {
        let program = """
        let touch = TouchControls()
        print HASTOUCH; HASTOUCH(); touch.Available()
        if HASTOUCH then print "TAP" else print "CLICK"
        """
        let screen = Touch()
        screen.controlsShown = false
        let (outcome, output) = try Self.run(program, services: WasmHostServices(touchControls: screen))
        #expect(outcome == .finished(0), "\(output)")
        #expect(output == "11FALSE\nTAP\n", "\(output)")

        let (bareOutcome, bare) = try Self.run(program, services: WasmHostServices())
        #expect(bareOutcome == .finished(0), "\(bare)")
        #expect(bare == "00FALSE\nCLICK\n", "\(bare)")
    }

    @Test("Without a touch screen TouchControls says so and does nothing, as the interpreter's does")
    func noTouchScreen() throws {
        let (outcome, output) = try Self.run("""
        let touch = TouchControls()
        print touch.Available()
        touch.Joystick("stick", "BOTTOMRIGHT", 40, 40, 160)
        print touch.X("stick")
        """, services: WasmHostServices())
        #expect(outcome == .finished(0), "\(output)")
        #expect(output == "FALSE\n0\n", "\(output)")
    }
}
#endif
