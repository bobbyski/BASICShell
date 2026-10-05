//
//  BASICWorkerLaneTests.swift
//  BASICCoreTests
//
//  A worker lane runs a program on a thread with stack enough for deep
//  BASIC: the interpreter recurses for every BASIC call.
//

import Foundation
import Testing
@testable import BASICCore

@Suite("Worker lane")
struct BASICWorkerLaneTests {
    @Test("A program three hundred calls deep runs on a lane; eight used to overflow its stack")
    func deepCallsRunOnALane() throws {
        let host = TestHost()
        let session = BASICSession(host: host)
        session.program.loadSource("""
        FUNCTION Depth(n AS INTEGER) AS INTEGER
            IF n <= 0 THEN RETURN 0
            RETURN 1 + Depth(n - 1)
        END FUNCTION
        PRINT "DEPTH"; Depth(300)
        """)
        let lane = BASICWorkerLane(label: "AIBasic.Tests.Lane")
        let finished = DispatchSemaphore(value: 0)
        #expect(lane.submit {
            session.submit("RUN")
            finished.signal()
        })
        #expect(finished.wait(timeout: .now() + 60) == .success)
        #expect(host.output.joined().filter { $0 != " " }.contains("DEPTH300"), "\(host.output)")
    }

    @Test("One operation at a time")
    func oneAtATime() {
        let lane = BASICWorkerLane(label: "AIBasic.Tests.Lane")
        let release = DispatchSemaphore(value: 0)
        let finished = DispatchSemaphore(value: 0)
        #expect(lane.submit {
            release.wait()
            finished.signal()
        })
        #expect(lane.isRunning)
        #expect(!lane.submit {})
        release.signal()
        #expect(finished.wait(timeout: .now() + 10) == .success)
    }
}
