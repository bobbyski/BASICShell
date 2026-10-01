//
//  StudioCloudStorageTests.swift
//  BASICStudioTests
//
//  Programs in iCloud Drive: the folder, placeholders, and the setting.
//

import Foundation
import Testing
@testable import BASICStudio

@Suite("iCloud Drive storage", .serialized)
@MainActor
struct StudioCloudStorageTests {
    @Test("A container's folder on disk swaps its dots for tildes")
    func containerFolderName() {
        #expect(StudioCloudStorage.onDiskName(of: "iCloud.com.aibasic.BASICStudio") == "iCloud~com~aibasic~BASICStudio")
    }

    @Test("A placeholder names the program it stands for")
    func placeholders() {
        #expect(StudioCloudStorage.realName(ofPlaceholder: ".hello.bas.icloud") == "hello.bas")
        #expect(StudioCloudStorage.realName(ofPlaceholder: "hello.bas") == nil)
        #expect(StudioCloudStorage.realName(ofPlaceholder: ".icloud") == nil)
    }

    @Test("The Mac finds the container only where iCloud Drive is on")
    func macContainer() throws {
        let home = FileManager.default.temporaryDirectory
            .appendingPathComponent("StudioCloudStorageTests-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: home) }
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
        #expect(StudioCloudStorage.macContainerOnDisk(home: home) == nil)

        let drive = home.appendingPathComponent("Library/Mobile Documents/com~apple~CloudDocs", isDirectory: true)
        try FileManager.default.createDirectory(at: drive, withIntermediateDirectories: true)
        let container = try #require(StudioCloudStorage.macContainerOnDisk(home: home))
        #expect(container.lastPathComponent == "iCloud~com~aibasic~BASICStudio")
        #expect(StudioCloudStorage.isInCloud(container.appendingPathComponent("Documents/hello.bas")))
    }

    @Test("A save outside iCloud is a plain write")
    func plainWrite() throws {
        let file = FileManager.default.temporaryDirectory.appendingPathComponent("plain-\(UUID().uuidString).bas")
        defer { try? FileManager.default.removeItem(at: file) }
        #expect(!StudioCloudStorage.isInCloud(file))
        try StudioCloudStorage.write("PRINT 1\n", to: file)
        #expect(try String(contentsOf: file, encoding: .utf8) == "PRINT 1\n")
    }

    @Test("The setting is saved, and off on the Mac until turned on")
    func setting() throws {
        #expect(!StudioSettings().keepsProgramsInICloud)
        let saved = try JSONEncoder().encode(StudioSettings(keepsProgramsInICloud: true))
        #expect(try JSONDecoder().decode(StudioSettings.self, from: saved).keepsProgramsInICloud)
        // Settings written before there was a setting read as the default.
        #expect(try !JSONDecoder().decode(StudioSettings.self, from: Data("{}".utf8)).keepsProgramsInICloud)
    }

    @Test("Turned on headless, it says iCloud is unavailable and leaves the folder alone")
    func headless() {
        let model = StudioHarness().model
        #expect(model.cloudStatus == .off)
        model.keepsProgramsInICloud = true
        #expect(model.cloudStatus == .unavailable)
        model.keepsProgramsInICloud = false
        #expect(model.cloudStatus == .off)
        #expect(SettingsAUI.cloudStatusText(.unavailable).contains("iCloud Drive is off"))
    }
}
