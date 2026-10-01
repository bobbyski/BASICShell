import BASICCore
#if canImport(AppKit)
import AppKit
#else
import UIKit
#endif
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
    /// Lines of console history kept by the terminal view and the model's console mirror.
    ///
    /// The cap bounds both what the user can scroll back through and the size of the
    /// string the console re-reads on every update, so it is a memory *and* a throughput
    /// setting. Values are clamped to `consoleScrollbackRange`.
    static let defaultConsoleScrollbackLines = 5000
    static let consoleScrollbackRange = 200...50_000

    /// The system's own look.
    static let defaultAppTheme = "Native"

    /// Four spaces, as the demos are written.
    static let defaultIndentUnit = "    "

    static func clampedConsoleScrollbackLines(_ lines: Int) -> Int {
        min(max(lines, consoleScrollbackRange.lowerBound), consoleScrollbackRange.upperBound)
    }

    var editorTheme: EditorTheme = .dark
    /// The ActiveUI shell's theme, by name: Native, NC State, Blue, …
    var appTheme = StudioSettings.defaultAppTheme
    var isEditorGutterVisible = false
    /// Tab and Shift-Tab indent or outdent the selected lines.
    var editorIndentsSelectionWithTab = true
    /// Return keeps the line's indentation.
    var editorIndentsNewLines = true
    /// One level of indentation: a tab, or spaces.
    var editorIndentUnit: String = StudioSettings.defaultIndentUnit
    var terminalScreenSize: TerminalScreenSize = .flexible
    var workingDirectoryPath: String?
    var promptTemplate: String = BASICSession.defaultPromptTemplate
    var fontFamily: String = StudioFonts.defaultFamily
    var fontSize: Double = 13
    var consoleScrollbackLines: Int = StudioSettings.defaultConsoleScrollbackLines
    /// The folder open as a project, reopened at launch (P3.7).
    var projectDirectoryPath: String?
    /// Programs are kept in iCloud Drive (``StudioCloudStorage``).
    var keepsProgramsInICloud = StudioSettings.defaultKeepsProgramsInICloud

    /// On by default on iPad and iPhone, where the app's own folder is
    /// otherwise the only place a program can be; off on the Mac, where
    /// people already keep their programs where they want them.
    static var defaultKeepsProgramsInICloud: Bool {
        #if os(iOS)
        true
        #else
        false
        #endif
    }

    private enum CodingKeys: String, CodingKey {
        case editorTheme
        case appTheme
        case isEditorGutterVisible
        case editorIndentsSelectionWithTab
        case editorIndentsNewLines
        case editorIndentUnit
        case terminalScreenSize
        case workingDirectoryPath
        case promptTemplate
        case fontFamily
        case fontSize
        case consoleScrollbackLines
        case projectDirectoryPath
        case keepsProgramsInICloud
    }

    init(
        editorTheme: EditorTheme = .dark,
        appTheme: String = StudioSettings.defaultAppTheme,
        isEditorGutterVisible: Bool = false,
        editorIndentsSelectionWithTab: Bool = true,
        editorIndentsNewLines: Bool = true,
        editorIndentUnit: String = StudioSettings.defaultIndentUnit,
        terminalScreenSize: TerminalScreenSize = .flexible,
        workingDirectoryPath: String? = nil,
        promptTemplate: String = BASICSession.defaultPromptTemplate,
        fontFamily: String = StudioFonts.defaultFamily,
        fontSize: Double = 13,
        consoleScrollbackLines: Int = StudioSettings.defaultConsoleScrollbackLines,
        projectDirectoryPath: String? = nil,
        keepsProgramsInICloud: Bool = StudioSettings.defaultKeepsProgramsInICloud
    ) {
        self.editorTheme = editorTheme
        self.appTheme = appTheme
        self.isEditorGutterVisible = isEditorGutterVisible
        self.editorIndentsSelectionWithTab = editorIndentsSelectionWithTab
        self.editorIndentsNewLines = editorIndentsNewLines
        self.editorIndentUnit = editorIndentUnit
        self.terminalScreenSize = terminalScreenSize
        self.workingDirectoryPath = workingDirectoryPath
        self.promptTemplate = promptTemplate
        self.fontFamily = fontFamily
        self.fontSize = fontSize
        self.consoleScrollbackLines = Self.clampedConsoleScrollbackLines(consoleScrollbackLines)
        self.projectDirectoryPath = projectDirectoryPath
        self.keepsProgramsInICloud = keepsProgramsInICloud
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        editorTheme = try container.decodeIfPresent(EditorTheme.self, forKey: .editorTheme) ?? .dark
        appTheme = try container.decodeIfPresent(String.self, forKey: .appTheme) ?? Self.defaultAppTheme
        isEditorGutterVisible = try container.decodeIfPresent(Bool.self, forKey: .isEditorGutterVisible) ?? false
        editorIndentsSelectionWithTab = try container.decodeIfPresent(Bool.self, forKey: .editorIndentsSelectionWithTab) ?? true
        editorIndentsNewLines = try container.decodeIfPresent(Bool.self, forKey: .editorIndentsNewLines) ?? true
        editorIndentUnit = try container.decodeIfPresent(String.self, forKey: .editorIndentUnit) ?? Self.defaultIndentUnit
        terminalScreenSize = try container.decodeIfPresent(TerminalScreenSize.self, forKey: .terminalScreenSize) ?? .flexible
        workingDirectoryPath = try container.decodeIfPresent(String.self, forKey: .workingDirectoryPath)
        promptTemplate = try container.decodeIfPresent(String.self, forKey: .promptTemplate) ?? BASICSession.defaultPromptTemplate
        fontFamily = try container.decodeIfPresent(String.self, forKey: .fontFamily) ?? StudioFonts.defaultFamily
        fontSize = try container.decodeIfPresent(Double.self, forKey: .fontSize) ?? 13
        consoleScrollbackLines = Self.clampedConsoleScrollbackLines(
            try container.decodeIfPresent(Int.self, forKey: .consoleScrollbackLines) ?? Self.defaultConsoleScrollbackLines
        )
        projectDirectoryPath = try container.decodeIfPresent(String.self, forKey: .projectDirectoryPath)
        keepsProgramsInICloud = try container.decodeIfPresent(Bool.self, forKey: .keepsProgramsInICloud)
            ?? Self.defaultKeepsProgramsInICloud
    }
}

/// The user's home on the Mac; the app's own on iPhone and iPad, where there
/// is no other to reach.
enum StudioHome {
    static var url: URL {
        #if os(macOS)
        FileManager.default.homeDirectoryForCurrentUser
        #else
        URL(fileURLWithPath: NSHomeDirectory(), isDirectory: true)
        #endif
    }
}

struct StudioSettingsStore {
    private static let fileName = "StudioSettings.json"

    static var settingsURL: URL {
        let fileManager = FileManager.default
        let base = fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? StudioHome.url.appendingPathComponent("Library/Application Support")
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

#if os(macOS)
// The SwiftUI shell's Settings, which is macOS-only.
struct SettingsView: View {
    @ObservedObject var model: StudioModel
    /// General at first, or the tab the parity walk asked for.
    @State private var tab = StudioLaunchOptions.current.walk?.settingsTabIndex ?? 0

    var body: some View {
        let tabs = SettingsViewModel.tabs
        TabView(selection: $tab) {
            generalPage
                .tabItem {
                    Label(tabs[0].title, systemImage: tabs[0].symbol)
                }
                .tag(0)

            fontPage
                .tabItem {
                    Label(tabs[1].title, systemImage: tabs[1].symbol)
                }
                .tag(1)

            consolePage
                .tabItem {
                    Label(tabs[2].title, systemImage: tabs[2].symbol)
                }
                .tag(2)
        }
        .padding()
    }

    private static let scrollbackSliderBounds: ClosedRange<Double> = {
        let range = SettingsViewModel.scrollbackRange
        return Double(range.lowerBound)...Double(range.upperBound)
    }()

    private var scrollbackLinesBinding: Binding<Double> {
        Binding(
            get: { Double(model.consoleScrollbackLines) },
            set: { model.consoleScrollbackLines = Int($0.rounded()) }
        )
    }

    private var consolePage: some View {
        let settings = SettingsViewModel(model)
        return Form {
            Section(SettingsViewModel.scrollbackSectionTitle) {
                HStack {
                    Text("Lines")
                    Slider(value: scrollbackLinesBinding, in: Self.scrollbackSliderBounds, step: Double(SettingsViewModel.scrollbackStep))
                    Stepper(
                        value: $model.consoleScrollbackLines,
                        in: SettingsViewModel.scrollbackRange,
                        step: SettingsViewModel.scrollbackStep
                    ) {
                        Text(settings.scrollbackText)
                            .frame(width: 56, alignment: .trailing)
                            .monospacedDigit()
                    }
                }

                Text(SettingsViewModel.scrollbackNote)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private var generalPage: some View {
        NerdPromptEditorView(promptTemplate: $model.promptTemplate)
    }

    private var fontPage: some View {
        let settings = SettingsViewModel(model)
        return Form {
            Section(SettingsViewModel.fontSectionTitle) {
                Picker("Font", selection: $model.fontFamily) {
                    ForEach(Self.availableFontFamilies, id: \.self) { family in
                        Text(family).tag(family)
                    }
                }
                .pickerStyle(.menu)

                HStack {
                    Text("Size")
                    Slider(value: $model.fontSize, in: SettingsViewModel.fontSizeRange, step: SettingsViewModel.fontSizeStep)
                    Text(settings.fontSizeText)
                        .frame(width: 32, alignment: .trailing)
                        .monospacedDigit()
                }

                Text(SettingsViewModel.fontNote)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private static var availableFontFamilies: [String] {
        SettingsViewModel.fontFamilies(installed: NSFontManager.shared.availableFontFamilies)
    }
}
#endif
