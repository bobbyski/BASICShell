//
//  GameDemoTests.swift
//  BASICStudioTests
//
//  The game demos, played headless: picked from Examples ▸ Games, run, and
//  driven with the keys a player would press, with the VTG commands they
//  draw read back from the console's graphics stream.
//

import CoreGraphics
import Foundation
import Testing
@testable import BASICStudio

@MainActor
@Suite("Game demos play in Studio", .serialized)
struct GameDemoTests {
    @Test("Brick Breaker: builds the wall, launches, breaks bricks, steers, and quits with its score")
    func brickBreaker() async throws {
        let studio = StudioHarness()
        let example = try #require(studio.model.bundledExamples.first { $0.path == "games/brick-breaker" })
        #expect(example.title == "Brick Breaker")
        studio.model.loadBundledExample(example)

        var sent = ""
        studio.model.vtgDataSink = { sent += String(decoding: $0, as: UTF8.self) }
        studio.model.runEditorProgram()

        // The whole wall, all 112 bricks, and the paddle under it.
        try await studio.waitUntil("the wall to be drawn") { sent.contains("id=brick111,") && sent.contains("id=paddle,") }
        #expect(sent.contains("id=brick0,"))

        // Space launches; the ball climbs into the bottom row and breaks a brick.
        studio.model.handleTerminalInput([.append(" ")])
        try await studio.waitUntil("a brick to break", timeout: .seconds(30)) { sent.contains("delete,id=brick") }

        // Held LEFT slides the paddle to the left wall.
        studio.model.heldKeys.set("LEFT", down: true)
        try await studio.waitUntil("the paddle to reach the left wall") {
            Self.lastX(of: "paddle", in: sent) == 18 // FIELDLEFT, drawn at the world's own scale
        }
        studio.model.heldKeys.set("LEFT", down: false)

        studio.model.handleTerminalInput([.append("q")])
        try await studio.waitUntilStopped(timeout: .seconds(20))
        #expect(studio.model.consoleText.contains("Final score:"), "\(studio.model.consoleText)")
        #expect(!studio.model.consoleText.contains("error"), "\(studio.model.consoleText)")
    }

    @Test("Electric Storm: draws the tube, moves and fires, zaps what climbs out, and quits with its score")
    func electricStorm() async throws {
        let studio = StudioHarness()
        let example = try #require(studio.model.bundledExamples.first { $0.path == "games/electric-storm" })
        #expect(example.title == "Electric Storm")
        studio.model.loadBundledExample(example)

        var sent = ""
        studio.model.vtgDataSink = { sent += String(decoding: $0, as: UTF8.self) }
        studio.model.runEditorProgram()

        // The tube — sixteen rails and both rims — and the ship on it.
        try await studio.waitUntil("the tube to be drawn") {
            sent.contains("id=rim-near,") && sent.contains("id=rail15,") && sent.contains("id=ship,")
        }

        // Held LEFT moves the ship round the rim: the rails it lights move with it.
        let railsLitAtStart = sent.components(separatedBy: "#fde047").count
        studio.model.heldKeys.set("LEFT", down: true)
        try await studio.waitUntil("the ship to change lane") { sent.components(separatedBy: "#fde047").count > railsLitAtStart + 4 }
        studio.model.heldKeys.set("LEFT", down: false)

        // Held SPACE keeps firing down the lane.
        studio.model.heldKeys.set("SPACE", down: true)
        try await studio.waitUntil("shots") { sent.contains("id=shot0,") && sent.contains("id=shot1,") }
        studio.model.heldKeys.set("SPACE", down: false)

        // Once something has climbed out, Z zaps it and the tube flashes white.
        try await studio.waitUntil("an enemy", timeout: .seconds(30)) { sent.contains("id=enemy") }
        studio.model.handleTerminalInput([.append("z")])
        try await studio.waitUntil("the Superzapper") { sent.contains("delete,id=enemy") && sent.contains("id=rim-near,stroke=#ffffff") }

        studio.model.handleTerminalInput([.append("q")])
        try await studio.waitUntilStopped(timeout: .seconds(20))
        #expect(studio.model.consoleText.contains("Final score:"), "\(studio.model.consoleText)")
        #expect(!studio.model.consoleText.contains("error"), "\(studio.model.consoleText)")
    }

    @Test("Incoming: draws the cities and silos, aims, fires from a silo, bursts, and quits with its score")
    func incoming() async throws {
        let studio = StudioHarness()
        let example = try #require(studio.model.bundledExamples.first { $0.path == "games/incoming" })
        #expect(example.title == "Incoming")
        studio.model.loadBundledExample(example)

        var sent = ""
        studio.model.vtgDataSink = { sent += String(decoding: $0, as: UTF8.self) }
        studio.model.runEditorProgram()

        // Six cities, three silos, and the crosshair.
        try await studio.waitUntil("the ground to be drawn") {
            sent.contains("id=city5a,") && sent.contains("id=silo2c,") && sent.contains("id=crosshair,")
        }

        // Held UP moves the crosshair.
        let crosshairs = sent.components(separatedBy: "id=crosshair,").count
        studio.model.heldKeys.set("UP", down: true)
        try await studio.waitUntil("the crosshair to move") { sent.components(separatedBy: "id=crosshair,").count > crosshairs + 3 }
        studio.model.heldKeys.set("UP", down: false)

        // 2 fires from the middle silo: a trail, its mark, then a fireball.
        studio.model.handleTerminalInput([.append("2")])
        try await studio.waitUntil("a counter-missile") { sent.contains("id=abm0,") && sent.contains("id=mark0,") }
        try await studio.waitUntil("a fireball") { sent.contains("id=blast0,") }

        // The first salvo comes in.
        try await studio.waitUntil("incoming missiles", timeout: .seconds(30)) { sent.contains("id=trail0,") && sent.contains("id=head0,") }

        studio.model.handleTerminalInput([.append("q")])
        try await studio.waitUntilStopped(timeout: .seconds(20))
        #expect(studio.model.consoleText.contains("Final score:"), "\(studio.model.consoleText)")
        #expect(!studio.model.consoleText.contains("error"), "\(studio.model.consoleText)")
    }

    @Test("Munchies: draws the maze and everyone in it, eats dots going left, and quits with its score")
    func munchies() async throws {
        let studio = StudioHarness()
        let example = try #require(studio.model.bundledExamples.first { $0.path == "games/munchies" })
        #expect(example.title == "Munchies")
        studio.model.loadBundledExample(example)

        var sent = ""
        studio.model.vtgDataSink = { sent += String(decoding: $0, as: UTF8.self) }
        studio.model.runEditorProgram()

        // The walls, all the dots, the Munchie and four ghosts.
        try await studio.waitUntil("the maze", timeout: .seconds(30)) {
            sent.contains("id=wall1,") && sent.contains("id=dot645,") && sent.contains("id=munchie,") && sent.contains("id=g3h,")
        }

        // After READY!, held LEFT runs along the bottom corridor eating dots.
        studio.model.heldKeys.set("LEFT", down: true)
        try await studio.waitUntil("a dot eaten", timeout: .seconds(20)) { sent.contains("delete,id=dot") }
        studio.model.heldKeys.set("LEFT", down: false)

        studio.model.handleTerminalInput([.append("q")])
        try await studio.waitUntilStopped(timeout: .seconds(20))
        #expect(studio.model.consoleText.contains("Final score:"), "\(studio.model.consoleText)")
        #expect(!studio.model.consoleText.contains("error"), "\(studio.model.consoleText)")
    }

    @Test("Bugs from Space: the bugs fly in, the fighter moves and fires, and it quits with its score")
    func bugsFromSpace() async throws {
        let studio = StudioHarness()
        let example = try #require(studio.model.bundledExamples.first { $0.path == "games/bugs-from-space" })
        #expect(example.title == "Bugs From Space")
        studio.model.loadBundledExample(example)

        var sent = ""
        studio.model.vtgDataSink = { sent += String(decoding: $0, as: UTF8.self) }
        studio.model.runEditorProgram()

        // The fighter, the score, and the first bug flying in.
        try await studio.waitUntil("the fighter and the first bug") {
            sent.contains("id=f1a,") && sent.contains("id=score") && sent.contains("id=b0c,")
        }

        // Held LEFT moves the fighter; its canopy is the circle f1f.
        let start = try #require(Self.lastX(of: "f1f", in: sent))
        studio.model.heldKeys.set("LEFT", down: true)
        try await studio.waitUntil("the fighter to move left") { (Self.lastX(of: "f1f", in: sent) ?? start) < start - 20 }
        studio.model.heldKeys.set("LEFT", down: false)

        // A tap of Space fires.
        studio.model.handleTerminalInput([.append(" ")])
        try await studio.waitUntil("a shot") { sent.contains("id=p0,") }

        // They come in groups of eight: here comes the second.
        try await studio.waitUntil("the second group", timeout: .seconds(30)) { sent.contains("id=b8c,") }

        studio.model.handleTerminalInput([.append("q")])
        try await studio.waitUntilStopped(timeout: .seconds(20))
        #expect(studio.model.consoleText.contains("Final score:"), "\(studio.model.consoleText)")
        #expect(!studio.model.consoleText.contains("error"), "\(studio.model.consoleText)")
    }

    @Test("Protector: the planet scrolls by, the ship climbs, turns and fires, landers come, and it quits with its score")
    func protector() async throws {
        let studio = StudioHarness()
        let example = try #require(studio.model.bundledExamples.first { $0.path == "games/protector" })
        #expect(example.title == "Protector")
        studio.model.loadBundledExample(example)

        var sent = ""
        studio.model.vtgDataSink = { sent += String(decoding: $0, as: UTF8.self) }
        studio.model.runEditorProgram()

        // The ship, the mountains across the screen, the score, and the
        // first five landers on the scanner.
        try await studio.waitUntil("the ship, the mountains and the first landers") {
            sent.contains("id=se,") && sent.contains("id=m8,") && sent.contains("id=score") && sent.contains("id=ke4,")
        }

        // Held UP climbs; the ship's canopy is the circle se.
        let low = try #require(Self.lastField("cy", of: "se", in: sent))
        studio.model.heldKeys.set("UP", down: true)
        try await studio.waitUntil("the ship to climb") { (Self.lastField("cy", of: "se", in: sent) ?? low) < low - 30 }
        studio.model.heldKeys.set("UP", down: false)

        // Held LEFT turns it round, and the camera glides it across the
        // screen so the long view is ahead.
        let start = try #require(Self.lastX(of: "se", in: sent))
        studio.model.heldKeys.set("LEFT", down: true)
        try await studio.waitUntil("the ship to turn and glide across") { (Self.lastX(of: "se", in: sent) ?? start) > start + 200 }
        studio.model.heldKeys.set("LEFT", down: false)

        // A tap of Space fires a laser; B sets off a smart bomb, which
        // flashes the screen.
        studio.model.handleTerminalInput([.append(" ")])
        try await studio.waitUntil("a laser") { sent.contains("id=l0,") }
        studio.model.handleTerminalInput([.append("b")])
        try await studio.waitUntil("the smart bomb's flash") { sent.contains("id=flash,") }

        studio.model.handleTerminalInput([.append("q")])
        try await studio.waitUntilStopped(timeout: .seconds(20))
        #expect(studio.model.consoleText.contains("Final score:"), "\(studio.model.consoleText)")
        #expect(!studio.model.consoleText.contains("error"), "\(studio.model.consoleText)")
    }

    /// VTG coordinates must be whole numbers, and a game that scales its world
    /// to the window computes them; at 1:1 a stray half can stay hidden.
    /// Munchies' score popup stopped the game this way in a window that
    /// scaled it to 0.76 — behind its own backdrop, so it looked like a hang.
    @Test("Every game runs at an awkward scale with no runtime error", arguments: ["brick-breaker", "bugs-from-space", "electric-storm", "incoming", "munchies", "protector"])
    func awkwardScale(game: String) async throws {
        let studio = StudioHarness()
        let example = try #require(studio.model.bundledExamples.first { $0.path == "games/\(game)" })
        studio.model.loadBundledExample(example)
        studio.model.updateLiveVTGCanvasSize(width: 486, height: 548)

        var frames = 0
        studio.model.vtgDataSink = { frames += String(decoding: $0, as: UTF8.self).components(separatedBy: "endFrame").count - 1 }
        studio.model.runEditorProgram()
        try await studio.waitUntil("three seconds of play", timeout: .seconds(30)) { frames > 90 }
        #expect(studio.model.isProgramRunning, "\(studio.model.consoleText.suffix(300))")

        studio.model.handleTerminalInput([.append("q")])
        try await studio.waitUntilStopped(timeout: .seconds(20))
        #expect(!studio.model.consoleText.contains("rror"), "\(studio.model.consoleText.suffix(300))")
    }

    // MARK: - Touch and gamepad

    /// The screen the touch tests put fingers on. On the Mac the controls are
    /// kept but not drawn; a touch reaches them the way the iPad's view would
    /// send it.
    private static let screen = CGRect(x: 0, y: 0, width: 1000, height: 700)

    /// A finger down on control `id`, at a fraction of its radius from the
    /// middle.
    private static func touch(_ studio: StudioHarness, _ id: String, finger: Int, x: Double = 0, y: Double = 0) throws {
        let control = try #require(studio.model.touchControls.snapshot().map(\.control).first { $0.id == id }, "no control \(id)")
        let frame = StudioTouchControls.frame(of: control, in: screen)
        let point = CGPoint(x: frame.midX + CGFloat(x) * frame.width / 2, y: frame.midY + CGFloat(y) * frame.width / 2)
        #expect(studio.model.touchControls.touchBegan(finger, at: point, in: screen))
    }

    private static func slide(_ studio: StudioHarness, _ id: String, finger: Int, x: Double, y: Double) throws {
        let control = try #require(studio.model.touchControls.snapshot().map(\.control).first { $0.id == id })
        let frame = StudioTouchControls.frame(of: control, in: screen)
        studio.model.touchControls.touchMoved(finger, to: CGPoint(x: frame.midX + CGFloat(x) * frame.width / 2, y: frame.midY + CGFloat(y) * frame.width / 2), in: screen)
    }

    @Test("Every game places its touch controls, and takes them away when it ends", arguments: [
        ("roids", ["stick", "fire", "jump", "pause"]),
        ("brick-breaker", ["stick", "launch", "pause"]),
        ("electric-storm", ["wheel", "fire", "zap", "pause"]),
        ("incoming", ["stick", "fire", "silo1", "silo2", "silo3", "pause"]),
        ("munchies", ["pad", "pause"]),
        ("bugs-from-space", ["stick", "fire", "pause"]),
        ("protector", ["stick", "fire", "bomb", "hyper", "pause"]),
    ])
    func touchControlsPlaced(game: String, controls: [String]) async throws {
        let studio = StudioHarness()
        let example = try #require(studio.model.bundledExamples.first { $0.path == "games/\(game)" })
        studio.model.loadBundledExample(example)
        studio.model.vtgDataSink = { _ in }
        studio.model.runEditorProgram()
        try await studio.waitUntil("the controls", timeout: .seconds(20)) { !studio.model.touchControls.isEmpty }
        try await studio.waitUntil("all of them") { studio.model.touchControls.snapshot().count == controls.count }
        #expect(studio.model.touchControls.snapshot().map(\.control.id) == controls)

        studio.model.handleTerminalInput([.append("q")])
        try await studio.waitUntilStopped(timeout: .seconds(20))
        #expect(studio.model.touchControls.isEmpty)
        #expect(!studio.model.consoleText.contains("rror"), "\(studio.model.consoleText.suffix(300))")
    }

    @Test("Bugs from Space by touch: the stick moves the fighter and Fire shoots")
    func bugsFromSpaceByTouch() async throws {
        let studio = StudioHarness()
        let example = try #require(studio.model.bundledExamples.first { $0.path == "games/bugs-from-space" })
        studio.model.loadBundledExample(example)
        var sent = ""
        studio.model.vtgDataSink = { sent += String(decoding: $0, as: UTF8.self) }
        studio.model.runEditorProgram()
        try await studio.waitUntil("the fighter") { sent.contains("id=f1f,") && !studio.model.touchControls.isEmpty }

        let start = try #require(Self.lastX(of: "f1f", in: sent))
        try Self.touch(studio, "stick", finger: 1)
        try Self.slide(studio, "stick", finger: 1, x: 0.9, y: 0)
        try await studio.waitUntil("the fighter to move right") { (Self.lastX(of: "f1f", in: sent) ?? start) > start + 20 }
        studio.model.touchControls.touchEnded(1)

        try Self.touch(studio, "fire", finger: 2)
        try await studio.waitUntil("a shot") { sent.contains("id=p0,") }
        studio.model.touchControls.touchEnded(2)

        studio.model.handleTerminalInput([.append("q")])
        try await studio.waitUntilStopped(timeout: .seconds(20))
        #expect(!studio.model.consoleText.contains("rror"), "\(studio.model.consoleText.suffix(300))")
    }

    @Test("Protector by touch: the stick flies the ship, Fire shoots, and Bomb sets off a smart bomb")
    func protectorByTouch() async throws {
        let studio = StudioHarness()
        let example = try #require(studio.model.bundledExamples.first { $0.path == "games/protector" })
        studio.model.loadBundledExample(example)
        var sent = ""
        studio.model.vtgDataSink = { sent += String(decoding: $0, as: UTF8.self) }
        studio.model.runEditorProgram()
        try await studio.waitUntil("the ship") { sent.contains("id=se,") && !studio.model.touchControls.isEmpty }

        let low = try #require(Self.lastField("cy", of: "se", in: sent))
        try Self.touch(studio, "stick", finger: 1)
        try Self.slide(studio, "stick", finger: 1, x: 0, y: -0.9)
        try await studio.waitUntil("the ship to climb") { (Self.lastField("cy", of: "se", in: sent) ?? low) < low - 30 }
        studio.model.touchControls.touchEnded(1)

        try Self.touch(studio, "fire", finger: 2)
        try await studio.waitUntil("a laser") { sent.contains("id=l0,") }
        studio.model.touchControls.touchEnded(2)

        try Self.touch(studio, "bomb", finger: 3)
        try await studio.waitUntil("the smart bomb's flash") { sent.contains("id=flash,") }
        studio.model.touchControls.touchEnded(3)

        studio.model.handleTerminalInput([.append("q")])
        try await studio.waitUntilStopped(timeout: .seconds(20))
        #expect(!studio.model.consoleText.contains("rror"), "\(studio.model.consoleText.suffix(300))")
    }

    @Test("Electric Storm by touch: the wheel moves the ship round the rim, and Fire shoots")
    func electricStormByTouch() async throws {
        let studio = StudioHarness()
        let example = try #require(studio.model.bundledExamples.first { $0.path == "games/electric-storm" })
        studio.model.loadBundledExample(example)
        var sent = ""
        studio.model.vtgDataSink = { sent += String(decoding: $0, as: UTF8.self) }
        studio.model.runEditorProgram()
        try await studio.waitUntil("the ship") { sent.contains("id=ship,") && !studio.model.touchControls.isEmpty }

        // A quarter turn clockwise: five lanes.
        let ships = sent.components(separatedBy: "draw,id=ship,").count
        try Self.touch(studio, "wheel", finger: 1, x: 0.8, y: 0)
        try Self.slide(studio, "wheel", finger: 1, x: 0.57, y: 0.57)
        try Self.slide(studio, "wheel", finger: 1, x: 0, y: 0.8)
        studio.model.touchControls.touchEnded(1)
        try await studio.waitUntil("the ship to move") { sent.components(separatedBy: "draw,id=ship,").count > ships }

        try Self.touch(studio, "fire", finger: 2)
        try await studio.waitUntil("a shot") { sent.contains("id=shot0,") }
        studio.model.touchControls.touchEnded(2)

        studio.model.handleTerminalInput([.append("q")])
        try await studio.waitUntilStopped(timeout: .seconds(20))
        #expect(!studio.model.consoleText.contains("rror"), "\(studio.model.consoleText.suffix(300))")
    }

    @Test("Brick Breaker by touch: a lean on the stick slides the paddle, and Launch serves")
    func brickBreakerByTouch() async throws {
        let studio = StudioHarness()
        let example = try #require(studio.model.bundledExamples.first { $0.path == "games/brick-breaker" })
        studio.model.loadBundledExample(example)
        var sent = ""
        studio.model.vtgDataSink = { sent += String(decoding: $0, as: UTF8.self) }
        studio.model.runEditorProgram()
        try await studio.waitUntil("the paddle") { sent.contains("id=paddle,") && !studio.model.touchControls.isEmpty }

        let start = try #require(Self.lastX(of: "paddle", in: sent))
        try Self.touch(studio, "stick", finger: 1)
        try Self.slide(studio, "stick", finger: 1, x: -0.5, y: 0)
        try await studio.waitUntil("the paddle to slide left") { (Self.lastX(of: "paddle", in: sent) ?? start) < start - 30 }
        studio.model.touchControls.touchEnded(1)

        let balls = sent.components(separatedBy: "id=ball,").count
        try Self.touch(studio, "launch", finger: 2)
        studio.model.touchControls.touchEnded(2)
        try await studio.waitUntil("the ball to fly") { sent.components(separatedBy: "id=ball,").count > balls + 5 }

        studio.model.handleTerminalInput([.append("q")])
        try await studio.waitUntilStopped(timeout: .seconds(20))
        #expect(!studio.model.consoleText.contains("rror"), "\(studio.model.consoleText.suffix(300))")
    }

    @Test("Incoming by touch: the stick moves the crosshair and a silo button fires from that silo")
    func incomingByTouch() async throws {
        let studio = StudioHarness()
        let example = try #require(studio.model.bundledExamples.first { $0.path == "games/incoming" })
        studio.model.loadBundledExample(example)
        var sent = ""
        studio.model.vtgDataSink = { sent += String(decoding: $0, as: UTF8.self) }
        studio.model.runEditorProgram()
        try await studio.waitUntil("the crosshair") { sent.contains("id=crosshair,") && !studio.model.touchControls.isEmpty }

        let crosshairs = sent.components(separatedBy: "id=crosshair,").count
        try Self.touch(studio, "stick", finger: 1)
        try Self.slide(studio, "stick", finger: 1, x: 0, y: -0.9)
        try await studio.waitUntil("the crosshair to move") { sent.components(separatedBy: "id=crosshair,").count > crosshairs + 3 }
        studio.model.touchControls.touchEnded(1)

        try Self.touch(studio, "silo2", finger: 2)
        studio.model.touchControls.touchEnded(2)
        try await studio.waitUntil("a counter-missile") { sent.contains("id=abm0,") }

        studio.model.handleTerminalInput([.append("q")])
        try await studio.waitUntilStopped(timeout: .seconds(20))
        #expect(!studio.model.consoleText.contains("rror"), "\(studio.model.consoleText.suffix(300))")
    }

    @Test("Munchies by touch: the pad held left eats dots along the bottom corridor")
    func munchiesByTouch() async throws {
        let studio = StudioHarness()
        let example = try #require(studio.model.bundledExamples.first { $0.path == "games/munchies" })
        studio.model.loadBundledExample(example)
        var sent = ""
        studio.model.vtgDataSink = { sent += String(decoding: $0, as: UTF8.self) }
        studio.model.runEditorProgram()
        try await studio.waitUntil("the maze", timeout: .seconds(30)) { sent.contains("id=munchie,") && !studio.model.touchControls.isEmpty }

        try Self.touch(studio, "pad", finger: 1, x: -0.7, y: 0)
        try await studio.waitUntil("a dot eaten", timeout: .seconds(20)) { sent.contains("delete,id=dot") }
        studio.model.touchControls.touchEnded(1)

        studio.model.handleTerminalInput([.append("q")])
        try await studio.waitUntilStopped(timeout: .seconds(20))
        #expect(!studio.model.consoleText.contains("rror"), "\(studio.model.consoleText.suffix(300))")
    }

    @Test("Roids by touch: Fire shoots and the stick turns the ship")
    func roidsByTouch() async throws {
        let studio = StudioHarness()
        let example = try #require(studio.model.bundledExamples.first { $0.path == "games/roids" })
        studio.model.loadBundledExample(example)
        var sent = ""
        studio.model.vtgDataSink = { sent += String(decoding: $0, as: UTF8.self) }
        studio.model.runEditorProgram()
        try await studio.waitUntil("the ship") { sent.contains("id=ship,") && !studio.model.touchControls.isEmpty }

        try Self.touch(studio, "fire", finger: 1)
        studio.model.touchControls.touchEnded(1)
        try await studio.waitUntil("a shot") { sent.contains("id=shot0,") }

        let ship = try #require(sent.range(of: "draw,id=ship,", options: .backwards)).upperBound
        let before = String(sent[ship...].prefix { $0 != "\u{1b}" })
        try Self.touch(studio, "stick", finger: 2)
        try Self.slide(studio, "stick", finger: 2, x: -0.9, y: 0)
        try await studio.waitUntil("the ship to turn") {
            guard let now = sent.range(of: "draw,id=ship,", options: .backwards)?.upperBound else { return false }
            return String(sent[now...].prefix { $0 != "\u{1b}" }) != before
        }
        studio.model.touchControls.touchEnded(2)

        studio.model.handleTerminalInput([.append("q")])
        try await studio.waitUntilStopped(timeout: .seconds(20))
        #expect(!studio.model.consoleText.contains("rror"), "\(studio.model.consoleText.suffix(300))")
    }

    /// The value of `field` in the last command for `id`: `cy` for a
    /// circle's center, say.
    private static func lastField(_ field: String, of id: String, in sent: String) -> Int? {
        guard let command = sent.range(of: "id=\(id),", options: .backwards) else { return nil }
        let rest = sent[command.upperBound...]
        guard let value = rest.range(of: ",\(field)=") else { return nil }
        return Int(rest[value.upperBound...].prefix { $0.isNumber || $0 == "-" })
    }

    /// The `x` the last command for `id` drew it at.
    private static func lastX(of id: String, in sent: String) -> Int? {
        guard let command = sent.range(of: "id=\(id),", options: .backwards) else { return nil }
        let rest = sent[command.upperBound...]
        guard let x = rest.range(of: "x=") else { return nil }
        return Int(rest[x.upperBound...].prefix { $0.isNumber || $0 == "-" })
    }
}
