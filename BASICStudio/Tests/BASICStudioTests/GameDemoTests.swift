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
import SwiftTerm
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

    @Test("Outatime: the title shows every era's plane, Space starts, the plane turns and fires, the enemy comes, and it quits with its score")
    func outatime() async throws {
        let studio = StudioHarness()
        let example = try #require(studio.model.bundledExamples.first { $0.path == "games/outatime" })
        #expect(example.title == "Outatime")
        studio.model.loadBundledExample(example)

        var sent = ""
        studio.model.vtgDataSink = { sent += String(decoding: $0, as: UTF8.self) }
        studio.model.runEditorProgram()

        // The pictures are sprites: uploaded once, then the title puts up
        // every era's plane, 1910 to 2001.
        try await studio.waitUntil("the title's planes", timeout: .seconds(60)) {
            sent.contains("spriteDataUpload,id=p1910,") && sent.contains("sprite,id=t5,image=p2001,")
        }

        // Space starts in 1910, with its biplane in the middle of the sky.
        studio.model.handleTerminalInput([.append(" ")])
        try await studio.waitUntil("the plane") { sent.contains("sprite,id=plane,image=p1910,") }

        // Held RIGHT turns it, a sixteenth at a time, until it faces right.
        studio.model.heldKeys.set("RIGHT", down: true)
        try await studio.waitUntil("the plane to face right") { sent.contains("spriteRotate,id=plane,rotation=90") }
        studio.model.heldKeys.set("RIGHT", down: false)

        // Held SPACE keeps firing.
        studio.model.heldKeys.set("SPACE", down: true)
        try await studio.waitUntil("shots") { sent.contains("circle,id=s0,") && sent.contains("circle,id=s1,") }
        studio.model.heldKeys.set("SPACE", down: false)

        // The era's planes come in.
        try await studio.waitUntil("the enemy", timeout: .seconds(30)) { sent.contains("image=e1910,") }

        studio.model.handleTerminalInput([.append("q")])
        try await studio.waitUntilStopped(timeout: .seconds(20))
        #expect(studio.model.consoleText.contains("Final score:"), "\(studio.model.consoleText)")
        #expect(!studio.model.consoleText.contains("error"), "\(studio.model.consoleText)")
    }

    @Test("Soft Landing: the title shows the lander over the ground, Space starts, Up fires the engine, Right turns, the view closes in on the ground, it crashes, and it quits with its score")
    func softLanding() async throws {
        let studio = StudioHarness()
        let example = try #require(studio.model.bundledExamples.first { $0.path == "games/soft-landing" })
        #expect(example.title == "Soft Landing")
        studio.model.loadBundledExample(example)

        var sent = ""
        studio.model.vtgDataSink = { sent += String(decoding: $0, as: UTF8.self) }
        studio.model.runEditorProgram()

        // The ground, its pads and the lander are vector sprites; the title
        // puts the lander up large over a landing site.
        try await studio.waitUntil("the title", timeout: .seconds(60)) {
            sent.contains("vectorSpriteUpload,id=rockart,") && sent.contains("vectorSpriteUpload,id=padart,")
                && sent.contains("sprite,id=titlelander,image=landerart,")
        }

        // Space starts: the lander, high over a new site.
        studio.model.handleTerminalInput([.append(" ")])
        try await studio.waitUntil("the lander") { sent.contains("sprite,id=lander,image=landerart,") }

        // Up fires the engine.
        studio.model.heldKeys.set("UP", down: true)
        try await studio.waitUntil("the flame") { sent.contains("draw,id=flame,") }
        studio.model.heldKeys.set("UP", down: false)

        // Right turns it clockwise, four degrees a frame.
        studio.model.heldKeys.set("RIGHT", down: true)
        try await studio.waitUntil("the lander to turn") { Self.turned("lander", in: sent) }
        studio.model.heldKeys.set("RIGHT", down: false)

        // Left alone it falls: near the ground the view closes in, three
        // times as close, and tilted and too fast, it crashes.
        try await studio.waitUntil("the view to close in", timeout: .seconds(60)) {
            sent.range(of: #"spriteTransform,id=rock0,[^\x{1B}]*scale=(2\.[5-9]|[3-9]\.)"#, options: .regularExpression) != nil
        }
        try await studio.waitUntil("the crash", timeout: .seconds(60)) { sent.contains("draw,id=w0,") }

        studio.model.handleTerminalInput([.append("q")])
        try await studio.waitUntilStopped(timeout: .seconds(20))
        #expect(studio.model.consoleText.contains("Final score:"), "\(studio.model.consoleText)")
        #expect(!studio.model.consoleText.contains("error"), "\(studio.model.consoleText)")
    }

    /// Scorch is played with the mouse or a finger, on buttons it draws
    /// itself, so it is driven here by mouse events alone; as WebAssembly too,
    /// which is how it runs on an iPad. At 960 by 640 the world is the
    /// canvas, so a click lands where the program drew the button.
    @Test("Scorch by mouse: two tanks from the first screen, START, a drag aims the barrel, FIRE shoots, the shell bursts and digs a crater, and it quits with the standings", arguments: [false, true])
    func scorchByMouse(asWebAssembly: Bool) async throws {
        let studio = StudioHarness()
        let example = try #require(studio.model.bundledExamples.first { $0.path == "games/scorch" })
        #expect(example.title == "Scorch")
        studio.model.loadBundledExample(example)
        studio.model.updateLiveVTGCanvasSize(width: 960, height: 640)

        var sent = ""
        studio.model.vtgDataSink = { sent += String(decoding: $0, as: UTF8.self) }
        if asWebAssembly {
            studio.model.compiledRunTarget = .webAssembly
            studio.model.jitEditorProgram()
        } else {
            studio.model.runEditorProgram()
        }
        func post(_ subtype: String, _ x: Double, _ y: Double) async throws {
            studio.model.postVTGMouseEvent(subtype: subtype, x: x, y: y, button: 0, buttons: subtype == "UP" ? 0 : 1, duration: 0.05)
            try await Task.sleep(for: .milliseconds(150))
        }

        // The first screen: hills behind a panel of buttons, four tanks.
        try await studio.waitUntil("the first screen", timeout: .seconds(120)) { sent.contains("id=panel,") && sent.contains("id=bt16,") }

        // Its - twice: two tanks, you (RED) and the computer (BLUE). The
        // screen is built again each time, with two buttons fewer.
        try await post("DOWN", 422, 179)
        try await post("UP", 422, 179)
        try await post("DOWN", 422, 179)
        try await post("UP", 422, 179)
        try await studio.waitUntil("two tanks") { Self.lastCommand(of: "bt13", in: sent)?.hasPrefix("delete") == true }

        // START: the bar along the top, and the round.
        try await post("DOWN", 420, 540)
        try await post("UP", 420, 540)
        try await studio.waitUntil("the round") { sent.contains("id=barbg,") && sent.contains("id=tg0,") }

        // Your turn, whenever BLUE has had its own: FIRE turns red.
        try await studio.waitUntil("your turn", timeout: .seconds(90)) {
            Self.lastCommand(of: "bt9", in: sent)?.contains("fill=#dc2626") == true
        }

        // A drag from the barrel's pivot up and toward the middle: the
        // barrel turns to 45 degrees, and a guide line shows while dragging.
        let barrel = try #require(Self.lastCommand(of: "tg0", in: sent))
        let pivotX = Double(try #require(Self.value("x1", in: barrel)))
        let pivotY = Double(try #require(Self.value("y1", in: barrel)))
        let toward: Double = pivotX < 480 ? 1 : -1
        try await post("DOWN", pivotX + toward * 100, pivotY - 100)
        try await post("MOVE", pivotX + toward * 150, pivotY - 150)
        try await studio.waitUntil("the guide") { sent.contains("id=guide,") }
        try await post("UP", pivotX + toward * 150, pivotY - 150)
        let turned = try #require(Self.lastCommand(of: "tg0", in: sent))
        let tipX = try #require(Self.value("x2", in: turned))
        #expect(abs(Double(tipX) - (pivotX + toward * 12)) <= 2, "barrel \(turned)")

        // FIRE: a shell, its trail, a burst, and the sky reaching down into
        // the crater.
        let fired = sent.count
        try await post("DOWN", 850, 57)
        try await post("UP", 850, 57)
        try await studio.waitUntil("the shell") { sent.dropFirst(fired).contains("circle,id=sh") && sent.dropFirst(fired).contains("line,id=tl0,") }
        try await studio.waitUntil("the burst", timeout: .seconds(30)) { sent.dropFirst(fired).contains("circle,id=xo") }
        let burst = sent.count
        try await studio.waitUntil("the crater", timeout: .seconds(30)) { sent.dropFirst(burst).contains("rect,id=sk") }

        studio.model.handleTerminalInput([.append("q")])
        if asWebAssembly {
            try await studio.waitUntil("the compiled run to end", timeout: .seconds(30)) { !studio.model.isJITRunning }
        } else {
            try await studio.waitUntilStopped(timeout: .seconds(20))
        }
        #expect(studio.model.consoleText.contains("Thanks for playing Scorch."), "\(studio.model.consoleText.suffix(300))")
        #expect(studio.model.consoleText.contains("Final standings:"), "\(studio.model.consoleText.suffix(300))")
        #expect(!studio.model.consoleText.contains("rror"), "\(studio.model.consoleText.suffix(300))")
    }

    /// The last command sent for `id` — a delete as well as a drawing — from
    /// its name to the end of its fields.
    private static func lastCommand(of id: String, in sent: String) -> String? {
        let found = ["id=\(id),", "id=\(id)\u{1B}"].compactMap { sent.range(of: $0, options: .backwards) }
        guard let command = found.max(by: { $0.lowerBound < $1.lowerBound }) else { return nil }
        let start = sent[..<command.lowerBound].lastIndex(of: ";").map { sent.index(after: $0) } ?? command.lowerBound
        return String(sent[start...].prefix { $0 != "\u{1B}" })
    }

    /// The whole number in `field=` among a command's fields.
    private static func value(_ field: String, in command: String) -> Int? {
        command.split(separator: ",").first { $0.hasPrefix("\(field)=") }.flatMap { Int($0.dropFirst(field.count + 1)) }
    }

    /// Whether sprite `id` has been turned 20 to 99 degrees clockwise.
    private static func turned(_ id: String, in sent: String) -> Bool {
        sent.range(of: #"(sprite|spriteTransform),id=\#(id),[^\x{1B}]*rotation=[2-9][0-9][,.\x{1B}]"#, options: .regularExpression) != nil
    }

    /// VTG coordinates must be whole numbers, and a game that scales its world
    /// to the window computes them; at 1:1 a stray half can stay hidden.
    /// Munchies' score popup stopped the game this way in a window that
    /// scaled it to 0.76 — behind its own backdrop, so it looked like a hang.
    @Test("Every game runs at an awkward scale with no runtime error", arguments: ["brick-breaker", "bugs-from-space", "electric-storm", "incoming", "munchies", "outatime", "protector", "scorch", "soft-landing"])
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

    /// The sprites a terminal would draw once `sent` has all been applied to
    /// SwiftTerm's own VTG scene, and whether the picture each one shows is
    /// still uploaded. `clear` and `clearSprites` take the pictures away as
    /// well, so a game that clears after uploading shows no sprite at all —
    /// which reading the commands alone never shows.
    ///
    /// Also, every picture uploaded that the scene does not hold: SwiftTerm
    /// refuses a picture named with "_" or "-", which the SDK sends anyway.
    private static func spritesShown(in sent: String) -> (sprites: [(id: String, image: String, hasPicture: Bool)], refused: [String]) {
        let scene = VTGGraphicsScene()
        var uploaded: [String] = []
        for command in VectorTerminalGraphicsParser().feed(ArraySlice(Array(sent.utf8))).commands {
            _ = scene.apply(command)
            if ["spriteUpload", "spriteDataUpload", "vectorSpriteUpload"].contains(command.name), let id = command.parameters["id"] {
                uploaded.append(id)
            }
        }
        func holds(_ image: String) -> Bool {
            scene.indexedSpriteAsset(id: image) != nil || scene.vectorSpriteAsset(id: image) != nil || scene.spriteAsset(id: image) != nil
        }
        let sprites = scene.primitives.compactMap { primitive -> (id: String, image: String, hasPicture: Bool)? in
            guard case .sprite(let id, let image, _, _, _, _, _, _) = primitive else { return nil }
            return (id, image, holds(image))
        }
        return (sprites, Array(Set(uploaded.filter { !holds($0) })).sorted())
    }

    @Test("Sprite games keep their pictures: in SwiftTerm's own scene, every picture is taken and every sprite placed shows one", arguments: [("outatime", "plane"), ("outatime", "c0"), ("soft-landing", "lander"), ("soft-landing", "rock0")])
    func spritePicturesKept(game: String, sprite: String) async throws {
        let studio = StudioHarness()
        let example = try #require(studio.model.bundledExamples.first { $0.path == "games/\(game)" })
        studio.model.loadBundledExample(example)
        var sent = ""
        studio.model.vtgDataSink = { sent += String(decoding: $0, as: UTF8.self) }
        studio.model.runEditorProgram()
        try await studio.waitUntil("the title", timeout: .seconds(60)) { sent.contains("endFrame") }
        studio.model.handleTerminalInput([.append(" ")])
        try await studio.waitUntil("the \(sprite)", timeout: .seconds(30)) { sent.contains("id=\(sprite),") }
        let frames = sent.components(separatedBy: "endFrame").count
        try await studio.waitUntil("a second more") { sent.components(separatedBy: "endFrame").count > frames + 30 }

        // Before quitting, which clears everything away.
        let shown = Self.spritesShown(in: sent)
        let placed = shown.sprites.map { $0.id }
        let missing = shown.sprites.filter { !$0.hasPicture }.map { $0.image }
        #expect(placed.contains(sprite), "\(placed)")
        #expect(missing.isEmpty, "no picture for \(missing)")
        #expect(shown.refused.isEmpty, "the terminal refused \(shown.refused)")

        studio.model.handleTerminalInput([.append("q")])
        try await studio.waitUntilStopped(timeout: .seconds(20))
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
        ("outatime", ["stick", "fire", "pause"]),
        ("soft-landing", ["stick", "thrust", "pause"]),
        ("scorch", ["menu"]),
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

    /// On iPad every program runs as WebAssembly, and a touch button reports
    /// as a game controller does. Studio once asked only the interpreter
    /// whether anything wanted the event, and dropped every press.
    @Test("By touch, as WebAssembly as on iPad: a game's buttons reach it", arguments: [("electric-storm", "fire", "id=shot0,"), ("soft-landing", "thrust", "sprite,id=lander,"), ("outatime", "fire", "sprite,id=plane,")])
    func touchButtonsAsWebAssembly(game: String, control: String, shows: String) async throws {
        let studio = StudioHarness()
        let example = try #require(studio.model.bundledExamples.first { $0.path == "games/\(game)" })
        studio.model.loadBundledExample(example)
        var sent = ""
        studio.model.vtgDataSink = { sent += String(decoding: $0, as: UTF8.self) }
        studio.model.compiledRunTarget = .webAssembly
        studio.model.jitEditorProgram()
        try await studio.waitUntil("the game, compiled", timeout: .seconds(120)) {
            sent.contains("endFrame") && !studio.model.touchControls.isEmpty
        }
        #expect(!sent.contains(shows))

        try Self.touch(studio, control, finger: 1)
        try await studio.waitUntil("\(control) to work", timeout: .seconds(30)) { sent.contains(shows) }
        studio.model.touchControls.touchEnded(1)

        studio.model.handleTerminalInput([.append("q")])
        try await studio.waitUntil("the compiled run to end", timeout: .seconds(30)) { !studio.model.isJITRunning }
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

    @Test("Outatime by touch: Fire starts, the stick points the plane, and Fire shoots")
    func outatimeByTouch() async throws {
        let studio = StudioHarness()
        let example = try #require(studio.model.bundledExamples.first { $0.path == "games/outatime" })
        studio.model.loadBundledExample(example)
        var sent = ""
        studio.model.vtgDataSink = { sent += String(decoding: $0, as: UTF8.self) }
        studio.model.runEditorProgram()
        try await studio.waitUntil("the title", timeout: .seconds(60)) {
            sent.contains("sprite,id=t5,") && !studio.model.touchControls.isEmpty
        }

        try Self.touch(studio, "fire", finger: 1)
        try await studio.waitUntil("the plane") { sent.contains("sprite,id=plane,") }
        try await studio.waitUntil("shots") { sent.contains("circle,id=s0,") }
        studio.model.touchControls.touchEnded(1)

        // The stick points down: the plane turns all the way round.
        try Self.touch(studio, "stick", finger: 2)
        try Self.slide(studio, "stick", finger: 2, x: 0, y: 0.9)
        try await studio.waitUntil("the plane to face down") { sent.contains("spriteRotate,id=plane,rotation=180") }
        studio.model.touchControls.touchEnded(2)

        studio.model.handleTerminalInput([.append("q")])
        try await studio.waitUntilStopped(timeout: .seconds(20))
        #expect(!studio.model.consoleText.contains("rror"), "\(studio.model.consoleText.suffix(300))")
    }

    @Test("Soft Landing by touch: Thrust starts the game and fires the engine, and the stick turns the lander")
    func softLandingByTouch() async throws {
        let studio = StudioHarness()
        let example = try #require(studio.model.bundledExamples.first { $0.path == "games/soft-landing" })
        studio.model.loadBundledExample(example)
        var sent = ""
        studio.model.vtgDataSink = { sent += String(decoding: $0, as: UTF8.self) }
        studio.model.runEditorProgram()
        try await studio.waitUntil("the title", timeout: .seconds(60)) {
            sent.contains("sprite,id=titlelander,") && !studio.model.touchControls.isEmpty
        }

        // Thrust reports as a right trigger squeezed all the way.
        try Self.touch(studio, "thrust", finger: 1)
        try await studio.waitUntil("the lander") { sent.contains("sprite,id=lander,") }
        try await studio.waitUntil("the flame") { sent.contains("draw,id=flame,") }
        studio.model.touchControls.touchEnded(1)

        // The stick pushed right turns it clockwise.
        try Self.touch(studio, "stick", finger: 2)
        try Self.slide(studio, "stick", finger: 2, x: 0.9, y: 0)
        try await studio.waitUntil("the lander to turn") { Self.turned("lander", in: sent) }
        studio.model.touchControls.touchEnded(2)

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
