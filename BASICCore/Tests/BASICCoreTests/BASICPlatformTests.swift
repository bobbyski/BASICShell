//
//  BASICPlatformTests.swift
//  BASICCoreTests
//
//  What a platform lacks is said one way, naming the feature.
//

import Testing
@testable import BASICCore

@Suite
struct BASICPlatformTests {
    @Test
    func aMissingFeatureNamesItselfInTheSharedWords() {
        #expect(BASICPlatform.notAvailableMessage("PIPE") == "PIPE is not available on iPad/iPhone")
        #expect(BASICPlatform.notAvailable("SYSTEM$").description.contains("SYSTEM$ is not available on iPad/iPhone"))
    }

    @Test
    func theMacRunsOtherPrograms() {
        #if os(macOS)
        #expect(BASICPlatform.runsOtherPrograms)
        #endif
    }
}
