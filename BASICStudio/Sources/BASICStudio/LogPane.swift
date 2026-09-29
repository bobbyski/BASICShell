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

struct LogPane: View {
    @ObservedObject var model: StudioModel

    var body: some View {
        // Everything drawn comes from the projection, which the ActiveUI
        // pane reads too. The toggles still bind to the model directly.
        let pane = LogPaneModel(model)
        VStack(spacing: 0) {
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Toggle("Enabled", isOn: $model.isLoggingEnabled)
                    Spacer()
                    Button("Clear") { model.clearLogs() }
                        .disabled(!pane.canClear)
                }

                HStack {
                    Toggle("User", isOn: $model.showUserLogs)
                    Toggle("BASIC", isOn: $model.showBasicLogs)
                    Toggle("Trace", isOn: $model.isTraceLoggingEnabled)
                    Button(pane.traceButtonTitle) {
                        model.toggleTraceLogging()
                    }
                    .buttonStyle(.bordered)
                    Spacer()
                    Menu("Levels") {
                        if let header = pane.levelsMenuHeader {
                            Button(header) {
                                model.selectedLogLevels.removeAll()
                            }
                            Divider()
                            ForEach(pane.levelsMenu, id: \.level) { item in
                                Button {
                                    model.toggleLogLevel(item.level)
                                } label: {
                                    HStack {
                                        Text(item.level)
                                        if item.isChecked {
                                            Spacer()
                                            Image(systemName: "checkmark")
                                        }
                                    }
                                }
                            }
                        } else {
                            Text(LogPaneModel.noLevelsTitle)
                        }
                    }
                }
            }
            .padding(12)

            Divider()

            ScrollView {
                LazyVStack(alignment: .leading, spacing: 6) {
                    ForEach(pane.rows) { row in
                        logRow(row)
                    }
                }
                .padding(12)
                .frame(maxWidth: .infinity, alignment: .topLeading)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color(nsColor: .controlBackgroundColor))
    }

    private func logRow(_ row: LogPaneModel.Row) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(spacing: 6) {
                Text(row.time)
                    .foregroundStyle(.secondary)
                Text(row.issuer)
                    .fontWeight(.bold)
                Text(row.level)
                    .fontWeight(.semibold)
                    .foregroundStyle(color(for: row.levelKind))
                Text(row.module)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                Spacer(minLength: 0)
            }
            .font(.caption.monospaced())

            Text(row.text)
                .font(.system(.caption, design: .monospaced))
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(8)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(color(for: row.levelKind).opacity(0.12))
        .clipShape(RoundedRectangle(cornerRadius: 6))
    }

    private func color(for kind: LogPaneModel.LevelKind) -> SwiftUI.Color {
        switch kind {
        case .error: return .red
        case .warning: return .yellow
        case .debug: return .blue
        case .target: return SwiftUI.Color(red: 0.95, green: 0.15, blue: 0.85)
        case .run: return .green
        case .pause: return .orange
        case .plain: return .primary
        }
    }
}
