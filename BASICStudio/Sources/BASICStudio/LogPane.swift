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

    private static let timestampFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "HH:mm:ss.SSS"
        return formatter
    }()

    var body: some View {
        VStack(spacing: 0) {
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Toggle("Enabled", isOn: $model.isLoggingEnabled)
                    Spacer()
                    Button("Clear") { model.clearLogs() }
                        .disabled(model.logEntries.isEmpty)
                }

                HStack {
                    Toggle("User", isOn: $model.showUserLogs)
                    Toggle("BASIC", isOn: $model.showBasicLogs)
                    Toggle("Trace", isOn: $model.isTraceLoggingEnabled)
                    Button(model.isTraceLoggingEnabled ? "TROFF" : "TRON") {
                        model.toggleTraceLogging()
                    }
                    .buttonStyle(.bordered)
                    Spacer()
                    Menu("Levels") {
                        if model.availableLogLevels.isEmpty {
                            Text("No Levels")
                        } else {
                            Button(model.selectedLogLevels.isEmpty ? "All Selected" : "Show All") {
                                model.selectedLogLevels.removeAll()
                            }
                            Divider()
                            ForEach(model.availableLogLevels, id: \.self) { level in
                                Button {
                                    model.toggleLogLevel(level)
                                } label: {
                                    HStack {
                                        Text(level)
                                        if model.selectedLogLevels.isEmpty || model.selectedLogLevels.contains(level) {
                                            Spacer()
                                            Image(systemName: "checkmark")
                                        }
                                    }
                                }
                            }
                        }
                    }
                }
            }
            .padding(12)

            Divider()

            ScrollView {
                LazyVStack(alignment: .leading, spacing: 6) {
                    ForEach(model.filteredLogEntries) { entry in
                        logRow(entry)
                    }
                }
                .padding(12)
                .frame(maxWidth: .infinity, alignment: .topLeading)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color(nsColor: .controlBackgroundColor))
    }

    private func logRow(_ entry: StudioLogEntry) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(spacing: 6) {
                Text(Self.timestampFormatter.string(from: entry.timestamp))
                    .foregroundStyle(.secondary)
                Text(entry.issuer.rawValue)
                    .fontWeight(.bold)
                Text(entry.level)
                    .fontWeight(.semibold)
                    .foregroundStyle(color(for: entry.level))
                Text(entry.module)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                Spacer(minLength: 0)
            }
            .font(.caption.monospaced())

            Text(entry.text)
                .font(.system(.caption, design: .monospaced))
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(8)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(color(for: entry.level).opacity(0.12))
        .clipShape(RoundedRectangle(cornerRadius: 6))
    }

    private func color(for level: String) -> SwiftUI.Color {
        switch level.uppercased() {
        case "ERROR", "ERR", "FATAL":
            return .red
        case "WARN", "WARNING":
            return .yellow
        case "DEBUG", "TRACE", "INPUT":
            return .blue
        case "TARGET":
            return SwiftUI.Color(red: 0.95, green: 0.15, blue: 0.85)
        case "RUN", "INFO":
            return .green
        case "PAUSE":
            return .orange
        default:
            return .primary
        }
    }
}
