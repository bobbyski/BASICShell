import Foundation
#if canImport(Darwin)
import Darwin
#endif

public enum BASICPromptTemplateStore {
    private struct Payload: Codable {
        var promptTemplate: String
    }

    private static let fileName = "PromptSettings.json"

    /// Location of the shared prompt settings file.
    public static var settingsURL: URL {
        let fileManager = FileManager.default
        let base = fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? fileManager.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support")
        return base
            .appendingPathComponent("AIBasic", isDirectory: true)
            .appendingPathComponent(fileName)
    }

    /// Loads the shared prompt template, falling back to the provided default.
    public static func load(default defaultTemplate: String) -> String {
        guard let data = try? Data(contentsOf: settingsURL),
              let payload = try? JSONDecoder().decode(Payload.self, from: data),
              !payload.promptTemplate.isEmpty else {
            return defaultTemplate
        }
        return payload.promptTemplate
    }

    /// Saves the shared prompt template for all AIBasic hosts.
    public static func save(_ promptTemplate: String) {
        let url = settingsURL
        do {
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            let data = try JSONEncoder().encode(Payload(promptTemplate: promptTemplate))
            try data.write(to: url, options: .atomic)
        } catch {
            NSLog("Unable to save AIBasic prompt settings: \(error.localizedDescription)")
        }
    }
}

