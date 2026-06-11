import BASICCore
import AppKit
import CoreText
import GameController
import MarkdownUI
import SwiftUI
import SwiftTerm
import UniformTypeIdentifiers
import VectorTerminalSDK
import WebKit

@MainActor
protocol StudioDebuggerInterface: AnyObject {
    var debuggerBreakpointLines: Set<Int> { get }
    var debuggerExecutionLine: Int? { get }
    func toggleDebuggerBreakpoint(atSourceLine lineNumber: Int)
    func openDebugger()
}

enum EditorTheme: String, CaseIterable, Codable {
    case dark
    case light
    case highContrast

    var label: String {
        switch self {
        case .dark: return "Dark"
        case .light: return "Light"
        case .highContrast: return "High Contrast"
        }
    }

    var monacoName: String {
        switch self {
        case .dark: return "vs-dark"
        case .light: return "vs"
        case .highContrast: return "hc-black"
        }
    }
}

enum TerminalScreenSize: String, CaseIterable, Codable {
    case eightyByTwentyFive
    case sixtyFourBySixteen
    case thirtyTwoBySixteen
    case flexible

    var label: String {
        switch self {
        case .eightyByTwentyFive: return "80x25"
        case .sixtyFourBySixteen: return "64x16"
        case .thirtyTwoBySixteen: return "32x16"
        case .flexible: return "Flexible"
        }
    }

    var dimensions: (cols: Int, rows: Int)? {
        switch self {
        case .eightyByTwentyFive: return (80, 25)
        case .sixtyFourBySixteen: return (64, 16)
        case .thirtyTwoBySixteen: return (32, 16)
        case .flexible: return nil
        }
    }
}

struct StudioSettings: Codable {
    var editorTheme: EditorTheme = .dark
    var isEditorGutterVisible = false
    var terminalScreenSize: TerminalScreenSize = .flexible
    var workingDirectoryPath: String?
    var promptTemplate: String = BASICSession.defaultPromptTemplate
    var fontFamily: String = StudioFonts.defaultFamily
    var fontSize: Double = 13

    private enum CodingKeys: String, CodingKey {
        case editorTheme
        case isEditorGutterVisible
        case terminalScreenSize
        case workingDirectoryPath
        case promptTemplate
        case fontFamily
        case fontSize
    }

    init(
        editorTheme: EditorTheme = .dark,
        isEditorGutterVisible: Bool = false,
        terminalScreenSize: TerminalScreenSize = .flexible,
        workingDirectoryPath: String? = nil,
        promptTemplate: String = BASICSession.defaultPromptTemplate,
        fontFamily: String = StudioFonts.defaultFamily,
        fontSize: Double = 13
    ) {
        self.editorTheme = editorTheme
        self.isEditorGutterVisible = isEditorGutterVisible
        self.terminalScreenSize = terminalScreenSize
        self.workingDirectoryPath = workingDirectoryPath
        self.promptTemplate = promptTemplate
        self.fontFamily = fontFamily
        self.fontSize = fontSize
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        editorTheme = try container.decodeIfPresent(EditorTheme.self, forKey: .editorTheme) ?? .dark
        isEditorGutterVisible = try container.decodeIfPresent(Bool.self, forKey: .isEditorGutterVisible) ?? false
        terminalScreenSize = try container.decodeIfPresent(TerminalScreenSize.self, forKey: .terminalScreenSize) ?? .flexible
        workingDirectoryPath = try container.decodeIfPresent(String.self, forKey: .workingDirectoryPath)
        promptTemplate = try container.decodeIfPresent(String.self, forKey: .promptTemplate) ?? BASICSession.defaultPromptTemplate
        fontFamily = try container.decodeIfPresent(String.self, forKey: .fontFamily) ?? StudioFonts.defaultFamily
        fontSize = try container.decodeIfPresent(Double.self, forKey: .fontSize) ?? 13
    }
}

struct StudioSettingsStore {
    private static let fileName = "StudioSettings.json"

    static var settingsURL: URL {
        let fileManager = FileManager.default
        let base = fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? fileManager.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support")
        return base
            .appendingPathComponent("AIBasic", isDirectory: true)
            .appendingPathComponent(fileName)
    }

    static func load() -> StudioSettings {
        let url = settingsURL
        guard let data = try? Data(contentsOf: url),
              let settings = try? JSONDecoder().decode(StudioSettings.self, from: data) else {
            return StudioSettings()
        }
        return settings
    }

    static func save(_ settings: StudioSettings) {
        let url = settingsURL
        do {
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            let data = try JSONEncoder.pretty.encode(settings)
            try data.write(to: url, options: .atomic)
        } catch {
            NSLog("Unable to save BASICStudio settings: \(error.localizedDescription)")
        }
    }
}

private extension JSONEncoder {
    static var pretty: JSONEncoder {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return encoder
    }
}

struct SettingsView: View {
    @ObservedObject var model: StudioModel

    var body: some View {
        TabView {
            generalPage
                .tabItem {
                    Label("General", systemImage: "gearshape")
                }

            fontPage
                .tabItem {
                    Label("Font", systemImage: "textformat")
                }
        }
        .padding()
    }

    private var generalPage: some View {
        NerdPromptEditorView(promptTemplate: $model.promptTemplate)
    }

    private var fontPage: some View {
        Form {
            Section("Editor And Console Font") {
                Picker("Font", selection: $model.fontFamily) {
                    ForEach(Self.availableFontFamilies, id: \.self) { family in
                        Text(family).tag(family)
                    }
                }
                .pickerStyle(.menu)

                HStack {
                    Text("Size")
                    Slider(value: $model.fontSize, in: 10...24, step: 1)
                    Text("\(Int(model.fontSize))")
                        .frame(width: 32, alignment: .trailing)
                        .monospacedDigit()
                }

                Text("The selected font is used by Monaco and the SwiftTerm console. Prompt symbols need a Nerd Font or a font with matching glyph coverage.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private static var availableFontFamilies: [String] {
        let families = NSFontManager.shared.availableFontFamilies.sorted {
            $0.localizedStandardCompare($1) == .orderedAscending
        }
        let preferred = [StudioFonts.defaultFamily, "SF Mono", "Hack Nerd Font", "JetBrains Mono", "Menlo", "Monaco"]
        var result: [String] = []
        for family in preferred where !result.contains(family) {
            result.append(family)
        }
        for family in families where !result.contains(family) {
            result.append(family)
        }
        return result
    }
}
