//
//  LogPaneModel.swift
//  BASICStudio
//
//  What the Log inspector shows, for either shell.
//

import Foundation

/// The Log inspector as values: its toggles, its Levels menu, and its rows.
///
/// A projection, not a store (ACTIVEUI_TRANSITION.md §2). It is built from a
/// ``StudioModel`` on demand, owns nothing, and imports no UI framework, so
/// the SwiftUI pane and the ActiveUI pane draw from the same values. The
/// pane's actions go straight to the model.
///
/// ```text
///   ┌ [x] Enabled                      Clear ┐   canClear
///   │ [x] User [ ] BASIC [ ] Trace [TRON]  Levels ▾ │   traceButtonTitle, levelsMenu
///   ├──────────────────────────────────────┤
///   │ 12:00:01.250 U INFO BASIC            │   rows: time, issuer,
///   │ hello                                │   level (tinted by levelKind),
///   └──────────────────────────────────────┘   module, text
/// ```
struct LogPaneModel: Equatable {
    /// What a level's tint means. Each shell maps these to its own colors.
    enum LevelKind: Equatable {
        case error, warning, debug, target, run, pause, plain

        /// `ERROR`, `ERR` and `FATAL` are errors; `WARN` and `WARNING` are
        /// warnings; and so on. Case does not matter.
        init(level: String) {
            switch level.uppercased() {
            case "ERROR", "ERR", "FATAL": self = .error
            case "WARN", "WARNING": self = .warning
            case "DEBUG", "TRACE", "INPUT": self = .debug
            case "TARGET": self = .target
            case "RUN", "INFO": self = .run
            case "PAUSE": self = .pause
            default: self = .plain
            }
        }
    }

    /// One log entry, ready to draw.
    struct Row: Identifiable, Equatable {
        let id: UUID
        /// `HH:mm:ss.SSS`.
        let time: String
        /// `U` or `B`.
        let issuer: String
        let level: String
        let levelKind: LevelKind
        let module: String
        let text: String
    }

    /// One level in the Levels menu.
    struct LevelItem: Equatable {
        let level: String
        /// Checked when it is shown: every level is while none is chosen.
        let isChecked: Bool
    }

    let isLoggingEnabled: Bool
    let showsUserLogs: Bool
    let showsBasicLogs: Bool
    let isTraceLoggingEnabled: Bool
    /// The trace button names what pressing it does.
    let traceButtonTitle: String
    let canClear: Bool
    /// The Levels menu's first item, above a divider; nil when there are no
    /// levels yet, and the menu says so instead.
    let levelsMenuHeader: String?
    let levelsMenu: [LevelItem]
    /// What the menu says with no levels to list.
    static let noLevelsTitle = "No Levels"
    /// The entries that pass the filters, oldest first.
    let rows: [Row]

    @MainActor
    init(_ model: StudioModel) {
        isLoggingEnabled = model.isLoggingEnabled
        showsUserLogs = model.showUserLogs
        showsBasicLogs = model.showBasicLogs
        isTraceLoggingEnabled = model.isTraceLoggingEnabled
        traceButtonTitle = model.isTraceLoggingEnabled ? "TROFF" : "TRON"
        canClear = !model.logEntries.isEmpty
        let levels = model.availableLogLevels
        let selected = model.selectedLogLevels
        levelsMenuHeader = levels.isEmpty ? nil : (selected.isEmpty ? "All Selected" : "Show All")
        levelsMenu = levels.map { LevelItem(level: $0, isChecked: selected.isEmpty || selected.contains($0)) }
        rows = model.filteredLogEntries.map(Self.row)
    }

    static func row(_ entry: StudioLogEntry) -> Row {
        Row(
            id: entry.id,
            time: timestampFormatter.string(from: entry.timestamp),
            issuer: entry.issuer.rawValue,
            level: entry.level,
            levelKind: LevelKind(level: entry.level),
            module: entry.module,
            text: entry.text
        )
    }

    private static let timestampFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "HH:mm:ss.SSS"
        return formatter
    }()
}
