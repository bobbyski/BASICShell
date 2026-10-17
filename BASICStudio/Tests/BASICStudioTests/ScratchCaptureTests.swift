//
//  ScratchCaptureTests.swift — a scratch tool, not committed.
//
//  Runs SCRATCH_BAS in Studio's harness at SCRATCH_SIZE (960x600), types
//  SCRATCH_KEYS at the start, holds SCRATCH_HOLD (e.g. RIGHT,SPACE) after
//  SCRATCH_HOLD_AFTER frames, runs SCRATCH_FRAMES frames, and writes the VTG
//  stream to SCRATCH_OUT (console to SCRATCH_OUT.console). SCRATCH_ENGINE=wasm
//  runs it as WebAssembly.
//

import CoreGraphics
import Foundation
import SwiftTerm
import Testing
@testable import BASICStudio

@MainActor
@Suite("Scratch capture", .serialized)
struct ScratchCaptureTests {
    @Test func capture() async throws {
        let env = ProcessInfo.processInfo.environment
        guard let path = env["SCRATCH_BAS"], let out = env["SCRATCH_OUT"] else { return }
        let size = (env["SCRATCH_SIZE"] ?? "960x600").split(separator: "x").compactMap { Int($0) }
        let frames = Int(env["SCRATCH_FRAMES"] ?? "120") ?? 120
        let holdAfter = Int(env["SCRATCH_HOLD_AFTER"] ?? "0") ?? 0
        let studio = StudioHarness(program: try String(contentsOfFile: path, encoding: .utf8))
        studio.model.updateLiveVTGCanvasSize(width: size[0], height: size[1])
        var sent = ""
        studio.model.vtgDataSink = { sent += String(decoding: $0, as: UTF8.self) }
        let started = Date()
        if env["SCRATCH_ENGINE"] == "wasm" {
            studio.model.compiledRunTarget = .webAssembly
            studio.model.jitEditorProgram()
        } else {
            studio.model.runEditorProgram()
        }
        func count() -> Int { sent.components(separatedBy: "endFrame").count - 1 }
        try await studio.waitUntil("the first frame", timeout: .seconds(60)) { count() >= 1 }
        let firstFrame = Date()
        for key in (env["SCRATCH_KEYS"] ?? "").map(String.init) {
            studio.model.handleTerminalInput([.append(key == "_" ? " " : key)])
            try await Task.sleep(for: .milliseconds(120))
        }
        // SCRATCH_MOUSE: "frame:SUBTYPE:x:y;..." posted once that many frames are drawn.
        for step in (env["SCRATCH_MOUSE"] ?? "").split(separator: ";") {
            let bits = step.split(separator: ":").map(String.init)
            guard bits.count == 4, let at = Int(bits[0]), let x = Double(bits[2]), let y = Double(bits[3]) else { continue }
            try await studio.waitUntil("mouse at \(at)", timeout: .seconds(300)) { count() >= at }
            studio.model.postVTGMouseEvent(subtype: bits[1], x: x, y: y, button: 0, buttons: bits[1] == "UP" ? 0 : 1, duration: 0.05)
        }
        if holdAfter > 0 { try await studio.waitUntil("hold point", timeout: .seconds(120)) { count() >= holdAfter } }
        for key in (env["SCRATCH_HOLD"] ?? "").split(separator: ",") { studio.model.heldKeys.set(String(key), down: true) }
        try await studio.waitUntil("\(frames) frames", timeout: .seconds(300)) { count() >= frames }
        let seconds = Date().timeIntervalSince(firstFrame)
        for key in (env["SCRATCH_HOLD"] ?? "").split(separator: ",") { studio.model.heldKeys.set(String(key), down: false) }
        studio.model.handleTerminalInput([.append("q")])
        try? await studio.waitUntilStopped(timeout: .seconds(20))
        try sent.write(toFile: out, atomically: true, encoding: .utf8)
        try (studio.model.consoleText + "\nframes=\(count()) seconds=\(seconds) startup=\(firstFrame.timeIntervalSince(started))\n")
            .write(toFile: out + ".console", atomically: true, encoding: .utf8)
    }
    /// Scratch: a game run as WebAssembly, its touch Fire pressed.
    @Test func wasmTouchFire() async throws {
        let env = ProcessInfo.processInfo.environment
        guard let game = env["SCRATCH_GAME"] else { return }
        let control = env["SCRATCH_CONTROL"] ?? "fire"
        let studio = StudioHarness()
        let example = try #require(studio.model.bundledExamples.first { $0.path == "games/\(game)" })
        studio.model.loadBundledExample(example)
        var sent = ""
        studio.model.vtgDataSink = { sent += String(decoding: $0, as: UTF8.self) }
        if env["SCRATCH_ENGINE"] == "wasm" {
            studio.model.compiledRunTarget = .webAssembly
            studio.model.jitEditorProgram()
        } else {
            studio.model.runEditorProgram()
        }
        try await studio.waitUntil("the controls", timeout: .seconds(60)) { !studio.model.touchControls.isEmpty && sent.contains("endFrame") }
        try await Task.sleep(for: .seconds(2))
        let before = sent.count
        let screen = CGRect(x: 0, y: 0, width: 1000, height: 700)
        let found = try #require(studio.model.touchControls.snapshot().map(\.control).first { $0.id == control })
        let frame = StudioTouchControls.frame(of: found, in: screen)
        #expect(studio.model.touchControls.touchBegan(1, at: CGPoint(x: frame.midX, y: frame.midY), in: screen))
        try await Task.sleep(for: .seconds(Double(env["SCRATCH_HOLD_SECONDS"] ?? "2") ?? 2))
        studio.model.touchControls.touchEnded(1)
        try await Task.sleep(for: .seconds(1))
        let after = String(sent.dropFirst(before))
        let ids = Set(after.components(separatedBy: "id=").dropFirst().map { String($0.prefix { $0 != "," && $0 != ";" }) })
        let wanted = env["SCRATCH_WANT"] ?? "shot"
        print("SCRATCH \(wanted) after touch: \(ids.filter { $0.hasPrefix(wanted) }.sorted().prefix(12))")
        print("SCRATCH log: \(studio.model.consoleText.suffix(300))")
        studio.model.handleTerminalInput([.append("q")])
        try? await studio.waitUntilStopped(timeout: .seconds(20))
    }
    /// Scratch: the X a mouse handler sees, interpreted and as WebAssembly.
    @Test func mouseX() async throws {
        guard ProcessInfo.processInfo.environment["SCRATCH_MOUSE"] != nil else { return }
        for wasm in [false, true] {
            let studio = StudioHarness(program: """
            GLOBAL n = 0
            FUNCTION Moved(e AS BASICMouseEvent)
              PRINT "move "; e.X; " "; e.Y
              n = n + 1
            END FUNCTION
            FUNCTION Released(e AS BASICMouseEvent)
              PRINT "up "; e.X; " "; e.Y
              n = n + 1
            END FUNCTION
            FUNCTION Main() AS VOID
              PRINT "ready"
              WHILE n < 5
                LOCAL slept = AWAIT SLEEP(20)
              WEND
            END FUNCTION
            ON MOUSE MOVE CALL Moved
            ON MOUSE UP CALL Released
            Main()
            """)
            if wasm {
                studio.model.compiledRunTarget = .webAssembly
                studio.model.jitEditorProgram()
            } else {
                studio.model.runEditorProgram()
            }
            try await studio.waitUntil("ready", timeout: .seconds(60)) { studio.model.consoleText.contains("ready\n") }
            for (subtype, x) in [("DOWN", 300.0), ("MOVE", 310.0), ("MOVE", 320.0), ("UP", 320.0), ("MOVE", 330.0), ("UP", 340.0)] {
                studio.model.postVTGMouseEvent(subtype: subtype, x: x, y: 77, button: 0, buttons: subtype == "UP" ? 0 : 1, duration: 0.05)
                try await Task.sleep(for: .milliseconds(100))
            }
            try await Task.sleep(for: .seconds(1))
            print("SCRATCH \(wasm ? "wasm" : "interp"):\n\(studio.model.consoleText.suffix(300))")
            studio.model.stopProgram()
            try? await studio.waitUntil("stopped", timeout: .seconds(20)) { !studio.model.isProgramRunning && !studio.model.isJITRunning }
        }
    }

    /// Scratch: Brick Breaker's paddle after a tap, frame by frame.
    @Test func paddleAfterTap() async throws {
        guard ProcessInfo.processInfo.environment["SCRATCH_PADDLE"] != nil else { return }
        for wasm in [false, true] {
            let studio = StudioHarness()
            let example = try #require(studio.model.bundledExamples.first { $0.path == "games/brick-breaker" })
            studio.model.loadBundledExample(example)
            var sent = ""
            studio.model.vtgDataSink = { sent += String(decoding: $0, as: UTF8.self) }
            if wasm {
                studio.model.compiledRunTarget = .webAssembly
                studio.model.jitEditorProgram()
            } else {
                studio.model.runEditorProgram()
            }
            try await studio.waitUntil("frames", timeout: .seconds(60)) { sent.components(separatedBy: "endFrame").count > 20 }
            func paddles(_ text: Substring) -> [String] {
                text.components(separatedBy: "id=paddle,").dropFirst().map { String($0.prefix { $0 != ";" }.prefix(30)) }
            }
            let before = sent.count
            try await Task.sleep(for: .milliseconds(500))
            print("SCRATCH \(wasm ? "wasm" : "interp") idle: \(paddles(sent.dropFirst(before)).suffix(4))")
            let tapAt = sent.count
            studio.model.postVTGMouseEvent(subtype: "DOWN", x: 800, y: 500, button: 0, buttons: 1, duration: 0.05)
            try await Task.sleep(for: .milliseconds(60))
            studio.model.postVTGMouseEvent(subtype: "UP", x: 800, y: 500, button: 0, buttons: 0, duration: 0.06)
            try await Task.sleep(for: .milliseconds(1500))
            let after = paddles(sent.dropFirst(tapAt))
            print("SCRATCH \(wasm ? "wasm" : "interp") after tap (\(after.count)): \(after.prefix(6)) ... \(after.suffix(4))")
            print("SCRATCH touch: \(studio.model.touchControls.snapshot().map { "\($0.control.id) \($0.state)" })")
            studio.model.handleTerminalInput([.append("q")])
            studio.model.stopProgram()
            try? await studio.waitUntil("stopped", timeout: .seconds(20)) { !studio.model.isProgramRunning && !studio.model.isJITRunning }
        }
    }

    /// Scratch (BASIC-47): how long Stop takes to reach a loop, per engine.
    @Test func stopLatency() async throws {
        guard ProcessInfo.processInfo.environment["SCRATCH_STOP"] != nil else { return }
        let programs = [
            ("tight", "n = 0\nwhile 1\n    n = n + 1\nwend"),
            ("heavy", "big$ = STRING$(2000000, \"x\")\nn = 0\nwhile 1\n    p = INSTR(big$, \"y\")\n    n = n + 1\nwend"),
        ]
        for (name, source) in programs {
            for engine in ["interpreter", "wasm"] {
                let studio = StudioHarness(program: source)
                let model = studio.model
                switch engine {
                case "interpreter": model.runEditorProgram()
                case "llvm": model.compiledRunTarget = .llvm; model.jitEditorProgram()
                default: model.compiledRunTarget = .webAssembly; model.jitEditorProgram()
                }
                try await studio.waitUntil("running", timeout: .seconds(60)) { model.isProgramRunning || model.isJITRunning }
                try await Task.sleep(for: .seconds(2))
                let clock = ContinuousClock()
                let start = clock.now
                model.stopProgram()
                try? await studio.waitUntil("stopped", timeout: .seconds(30)) { !model.isProgramRunning && !model.isJITRunning }
                let took = clock.now - start
                let broke = model.consoleText.contains("Break")
                print("SCRATCHSTOP \(name) \(engine): \(took) break=\(broke)")
            }
        }
    }

    /// Scratch: what a TUI app in Studio says about VTG, both engines.
    @Test func tuiVTGReport() async throws {
        guard let out = ProcessInfo.processInfo.environment["SCRATCH_VTG"] else { return }
        for target in [StudioRunTarget.interpreter, .webAssembly] {
            let path = out + "-" + target.rawValue + ".txt"
            try? FileManager.default.removeItem(atPath: path)
            let studio = StudioHarness(program: """
            GLOBAL app = TUIApp()
            function Check() as variant
                OPEN "\(path)" FOR OUTPUT AS #1
                PRINT #1, app.vtgreport()
                CLOSE #1
                app.stop()
                return 0
            end function
            shell = TUIShell()
            app.after(300, "Check")
            app.run(shell)
            """)
            studio.model.runTarget = target
            studio.model.runEditorProgram()
            try await studio.waitUntil("the report", timeout: .seconds(60)) { FileManager.default.fileExists(atPath: path) }
            try await studio.waitUntil("the end", timeout: .seconds(30)) { !studio.model.isProgramRunning && !studio.model.isJITRunning }
            print("SCRATCHVTG \(target): \((try? String(contentsOfFile: path, encoding: .utf8)) ?? "none")")
        }
    }

    /// Scratch: a captured stream, applied to SwiftTerm's own scene.
    @Test func sceneOf() throws {
        guard let path = ProcessInfo.processInfo.environment["SCRATCH_STREAM"] else { return }
        let sent = try String(contentsOfFile: path, encoding: .utf8)
        let scene = VTGGraphicsScene()
        for command in VectorTerminalGraphicsParser().feed(ArraySlice(Array(sent.utf8))).commands { _ = scene.apply(command) }
        for primitive in scene.primitives {
            if case .sprite(let id, let image, let x, let y, let rotation, let scale, _, _) = primitive {
                let has = scene.indexedSpriteAsset(id: image) != nil
                print("SCENE sprite \(id) \(image) at \(x),\(y) rot \(rotation) scale \(scale) layer \(scene.layersByID[id] ?? -9) picture \(has)")
            }
        }
        print("SCENE assets \(scene.indexedSpriteAssets.keys.sorted())")
    }
}
