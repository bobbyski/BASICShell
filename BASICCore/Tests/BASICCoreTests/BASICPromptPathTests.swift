//
//  BASICPromptPathTests.swift
//  BASICCoreTests
//
//  The current directory as the prompt shows it. On iPhone and iPad nothing
//  above the app's Documents folder is anywhere the user can go, so the
//  path starts there (BASIC-29).
//

import Testing
@testable import BASICCore

@Suite("The prompt's path")
struct BASICPromptPathTests {
    private let iCloud = "/var/mobile/Library/Mobile Documents/iCloud~com~aibasic~BASICStudio"
    private let container = "/var/mobile/Containers/Data/Application/0A1B2C3D-4E5F-6789-ABCD-EF0123456789"

    private func onIOS(_ path: String) -> String {
        BASICSession.promptPath(path, home: container, fromDocuments: true)
    }

    @Test("On iOS the iCloud folder's path starts at Documents")
    func iCloudDocuments() {
        #expect(onIOS(iCloud + "/Documents") == "Documents")
        #expect(onIOS(iCloud + "/Documents/games") == "Documents/games")
        #expect(onIOS(iCloud + "/Documents/games/arcade") == "Documents/games/arcade")
    }

    @Test("So does the app's own Documents folder, however iOS spells the container")
    func localDocuments() {
        #expect(onIOS(container + "/Documents/games") == "Documents/games")
        #expect(onIOS("/private" + container + "/Documents") == "Documents")
    }

    @Test("A folder called Documents inside Documents is kept")
    func nestedDocuments() {
        #expect(onIOS(iCloud + "/Documents/Documents/notes") == "Documents/Documents/notes")
    }

    @Test("Mobile Documents is not Documents, and above Documents nothing changes but ~")
    func aboveDocuments() {
        #expect(onIOS(iCloud) == iCloud)
        #expect(onIOS("/var/mobile/Library/Mobile Documents") == "/var/mobile/Library/Mobile Documents")
        #expect(onIOS("/private" + container + "/tmp") == "~/tmp")
    }

    @Test("On the Mac, home is ~ and anything else is shown as it is")
    func mac() {
        #expect(BASICSession.promptPath("/Users/pat", home: "/Users/pat", fromDocuments: false) == "~")
        #expect(BASICSession.promptPath("/Users/pat/src/AIBasic", home: "/Users/pat", fromDocuments: false) == "~/src/AIBasic")
        #expect(BASICSession.promptPath("/Users/pat/Documents", home: "/Users/pat", fromDocuments: false) == "~/Documents")
        #expect(BASICSession.promptPath("/private/tmp/work", home: "/Users/pat", fromDocuments: false) == "/private/tmp/work")
    }
}
