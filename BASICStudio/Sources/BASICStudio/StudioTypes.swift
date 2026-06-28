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

enum StudioPane {
    case editor
    case console
}

enum InspectorPane {
    case debug
    case docs
    case logs
}

enum LogIssuer: String, CaseIterable, Identifiable {
    case user = "U"
    case basic = "B"

    var id: String { rawValue }

    var label: String {
        switch self {
        case .user: return "User"
        case .basic: return "BASIC"
        }
    }
}

struct StudioLogEntry: Identifiable, Equatable {
    let id = UUID()
    let timestamp: Date
    let issuer: LogIssuer
    let level: String
    let module: String
    let text: String
}

struct BundledExample: Identifiable, Hashable {
    let path: String

    var id: String { path }

    var menuTitle: String {
        path
            .split(separator: "/")
            .map { part in
                part
                    .split(separator: "-")
                    .map { word in
                        guard let first = word.first else { return "" }
                        return first.uppercased() + word.dropFirst()
                    }
                    .joined(separator: " ")
            }
            .joined(separator: " / ")
    }
}

enum TerminalInputOperation {
    case append(String)
    case submit(String)
    case lineInputExit(String, String)
    case key(String)
}
