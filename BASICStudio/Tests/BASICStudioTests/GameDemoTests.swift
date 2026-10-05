//
//  GameDemoTests.swift
//  BASICStudioTests
//
//  The game demos, played headless: picked from Examples ▸ Games, run, and
//  driven with the keys a player would press, with the VTG commands they
//  draw read back from the console's graphics stream.
//

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

    /// The `x` the last command for `id` drew it at.
    private static func lastX(of id: String, in sent: String) -> Int? {
        guard let command = sent.range(of: "id=\(id),", options: .backwards) else { return nil }
        let rest = sent[command.upperBound...]
        guard let x = rest.range(of: "x=") else { return nil }
        return Int(rest[x.upperBound...].prefix { $0.isNumber || $0 == "-" })
    }
}
