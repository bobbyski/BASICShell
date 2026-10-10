//
//  StudioVTGFrameQueue.swift
//  BASICStudio
//
//  A program's VTG output, carried from its thread to the console's view a
//  frame at a time.
//
//  The canvas writes each command on its own, and each write used to reach
//  the main thread as its own block, so a frame of a hundred commands was a
//  hundred blocks among whatever else the main thread had to do. A frame has
//  a deadline (`startFrame`'s timeout, 250 ms unless the program says), and
//  when the main thread was held up between a frame's first block and its
//  last — starting a sound, on the iPad — the terminal threw the frame away,
//  as the VTG spec says it must. What was in it was lost: an explosion's
//  `removeSprite`, and Outatime's smoke stayed on the screen for good.
//
//  So the commands are gathered here, and a frame's are held from
//  `startFrame` until `endFrame` or `cancelFrame`, then delivered in one
//  block, where no deadline can fall between them. A frame left open longer
//  than `heldLimit` — a program stopped in the middle of one — is delivered
//  as it stands, and the terminal's own deadline deals with it as before.
//

import Foundation

final class StudioVTGFrameQueue: @unchecked Sendable {
    /// How long a frame's commands are held at most.
    static let heldLimit: TimeInterval = 1

    private let lock = NSLock()
    private var pending = Data()
    /// Where the open frame's commands begin in `pending`, while one is open.
    private var frameStart: Int?
    /// Counts the frames opened, so a check for one leaves the next alone.
    private var frameNumber = 0
    private var isDeliveryScheduled = false
    private let deliver: @MainActor (Data) -> Void

    init(deliver: @escaping @MainActor (Data) -> Void) {
        self.deliver = deliver
    }

    private static let startFrame = Data("\u{1B}_VTG;startFrame".utf8)
    private static let endFrame = Data("\u{1B}_VTG;endFrame".utf8)
    private static let cancelFrame = Data("\u{1B}_VTG;cancelFrame".utf8)

    /// One write of the canvas's, from any thread.
    func write(_ data: Data) {
        lock.lock()
        var opened: Int?
        if data.starts(with: Self.startFrame), frameStart == nil {
            frameStart = pending.count
            frameNumber += 1
            opened = frameNumber
        }
        pending.append(data)
        if data.starts(with: Self.endFrame) || data.starts(with: Self.cancelFrame) {
            frameStart = nil
        }
        // Inside a frame there is nothing to deliver until it ends, unless
        // something came before it.
        let deliverable = frameStart.map { $0 > 0 } ?? true
        let schedule = deliverable && !isDeliveryScheduled
        if schedule { isDeliveryScheduled = true }
        lock.unlock()
        if schedule {
            DispatchQueue.main.async { [weak self] in
                MainActor.assumeIsolated { self?.deliverReady(releasingFrame: nil) }
            }
        }
        // A frame still open after `heldLimit` is delivered as it stands.
        if let opened {
            DispatchQueue.main.asyncAfter(deadline: .now() + Self.heldLimit) { [weak self] in
                MainActor.assumeIsolated { self?.deliverReady(releasingFrame: opened) }
            }
        }
    }

    /// Everything before the open frame, or everything when none is open —
    /// or when the open one is `releasingFrame`, held too long.
    @MainActor private func deliverReady(releasingFrame: Int?) {
        lock.lock()
        if releasingFrame == nil { isDeliveryScheduled = false }
        var ready = Data()
        if let start = frameStart, releasingFrame != frameNumber {
            ready = pending.prefix(start)
            pending = Data(pending.dropFirst(start))
            frameStart = 0
        } else {
            swap(&ready, &pending)
            frameStart = nil
        }
        lock.unlock()
        if !ready.isEmpty { deliver(ready) }
    }
}
