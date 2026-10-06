//
//  StudioDocumentsBoundaryTests.swift
//  BASICStudioTests
//
//  On iPhone and iPad, CD stops at the app's Documents folders, its own and
//  its iCloud one: nothing above them is anywhere the user can go
//  (BASIC-29). The rule is checked here on the Mac with iOS's paths.
//

import Foundation
import Testing
@testable import BASICStudio

@Suite("CD stops at Documents on iPhone and iPad")
struct StudioDocumentsBoundaryTests {
    private let local = "/var/mobile/Containers/Data/Application/0A1B2C3D-4E5F-6789-ABCD-EF0123456789/Documents"
    private let iCloud = "/var/mobile/Library/Mobile Documents/iCloud~com~aibasic~BASICStudio/Documents"

    private func allows(_ path: String) -> Bool {
        StudioDocumentsBoundary.allows(path, localDocuments: local)
    }

    @Test("Documents and anything in it, iCloud or local")
    func inside() {
        #expect(allows(iCloud))
        #expect(allows(iCloud + "/games"))
        #expect(allows(iCloud + "/games/.."))
        #expect(allows(local))
        #expect(allows(local + "/games/arcade"))
        #expect(allows("/private" + local + "/games"))
    }

    @Test("Not above it: cd .. from Documents, or anywhere else")
    func outside() {
        #expect(!allows(iCloud + "/.."))
        #expect(!allows("/var/mobile/Library/Mobile Documents"))
        #expect(!allows(local + "/.."))
        #expect(!allows(local + "/../Library"))
        #expect(!allows("/"))
        #expect(!allows("/var/mobile/Library/Mobile Documents/iCloud~com~other~App/Documents"))
    }

    @Test("~ is the Documents folder in use: iCloud's when it is on, the app's own otherwise")
    func tilde() {
        let cloud = URL(fileURLWithPath: iCloud, isDirectory: true)
        #expect(StudioDocumentsBoundary.tildeFolder(cloudFolder: cloud, localDocuments: local)?.path == iCloud)
        #expect(StudioDocumentsBoundary.tildeFolder(cloudFolder: nil, localDocuments: local)?.path == local)
        #expect(StudioDocumentsBoundary.tildeFolder(cloudFolder: nil, localDocuments: nil) == nil)
        // Either way, CD lets the user go there.
        #expect(allows(iCloud) && allows(local))
    }

    @Test("A folder that only starts like Documents is outside it")
    func lookalike() {
        #expect(!allows(local + "Old"))
        #expect(!allows("/var/mobile/Library/Mobile Documents/iCloud~com~aibasic~BASICStudio/DocumentsOld"))
    }
}
