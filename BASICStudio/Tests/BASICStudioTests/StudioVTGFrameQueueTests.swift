//
//  StudioVTGFrameQueueTests.swift
//  BASICStudioTests
//
//  A program's VTG frame reaches the console in one piece, so a main thread
//  held up partway through cannot make the terminal throw the frame away
//  (Outatime's smoke that never cleared, on the iPad).
//

import Foundation
import Testing
@testable import BASICStudio

@MainActor
@Suite("VTG output reaches the console a frame at a time")
struct StudioVTGFrameQueueTests {
    private func command(_ text: String) -> Data { Data("\u{1B}_VTG;\(text)\u{1B}\\".utf8) }

    private func waitFor(_ condition: () -> Bool) async throws {
        for _ in 0..<400 where !condition() { try await Task.sleep(for: .milliseconds(5)) }
    }

    @Test("What comes before a frame is delivered at once; the frame only when it ends, in one piece")
    func frameInOnePiece() async throws {
        var deliveries: [String] = []
        let queue = StudioVTGFrameQueue { deliveries.append(String(decoding: $0, as: UTF8.self)) }
        queue.write(command("clear"))
        queue.write(command("startFrame,id=game,timeout=250"))
        queue.write(command("sprite,id=x0,image=boom3"))
        try await waitFor { !deliveries.isEmpty }
        try await Task.sleep(for: .milliseconds(50))
        #expect(deliveries == [String(decoding: command("clear"), as: UTF8.self)])

        queue.write(command("removeSprite,id=x0"))
        queue.write(command("endFrame,id=game"))
        queue.write(command("present"))
        try await waitFor { deliveries.count >= 2 }
        let frame = ["startFrame,id=game,timeout=250", "sprite,id=x0,image=boom3", "removeSprite,id=x0", "endFrame,id=game", "present"]
            .map { String(decoding: command($0), as: UTF8.self) }.joined()
        #expect(deliveries.dropFirst().joined() == frame)
        #expect(deliveries[1].hasPrefix(String(decoding: command("startFrame,id=game,timeout=250"), as: UTF8.self)))
        #expect(deliveries[1].contains("endFrame"))
    }

    @Test("A frame never ended is delivered as it stands after the limit")
    func heldFrameReleased() async throws {
        var delivered = ""
        let queue = StudioVTGFrameQueue { delivered += String(decoding: $0, as: UTF8.self) }
        queue.write(command("startFrame,id=game"))
        queue.write(command("rect,id=r"))
        try await Task.sleep(for: .milliseconds(300))
        #expect(delivered.isEmpty)
        try await waitFor { delivered.contains("rect,id=r") }
        #expect(delivered.contains("startFrame") && delivered.contains("rect,id=r"))
    }
}
