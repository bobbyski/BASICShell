//
//  NerdPromptSegments.swift
//  BASICStudio
//
//  The prompt's segments, colors, edges and template, with no UI framework.
//  Moved unchanged out of NerdPromptEditorView.swift (ACTIVEUI_TRANSITION.md
//  P1 unit 7), so the ActiveUI prompt editor builds the same template.
//

import BASICCore
import Foundation

struct NerdPromptSegment: Identifiable, Equatable {
    enum Kind: String, CaseIterable {
        case os
        case home
        case currentDirectory
        case gitBranch
        case gitStatus
        case user
        case literal
        case newline

        var title: String {
            switch self {
            case .os: return "macOS Icon"
            case .home: return "Home"
            case .currentDirectory: return "Current Directory"
            case .gitBranch: return "Git Branch"
            case .gitStatus: return "Git Status"
            case .user: return "User"
            case .literal: return "Text"
            case .newline: return "New Line"
            }
        }

        var icon: String {
            switch self {
            case .os: return ""
            case .home: return ""
            case .currentDirectory: return ""
            case .gitBranch: return ""
            case .gitStatus: return "!"
            case .user: return ""
            case .literal: return "T"
            case .newline: return "↵"
            }
        }

        var systemImage: String {
            switch self {
            case .os: return "desktopcomputer"
            case .home: return "house"
            case .currentDirectory: return "folder"
            case .gitBranch: return "point.3.connected.trianglepath.dotted"
            case .gitStatus: return "exclamationmark.triangle"
            case .user: return "person"
            case .literal: return "textformat"
            case .newline: return "return"
            }
        }
    }

    let id = UUID()
    var kind: Kind
    var literal: String = ""
    var foreground: NerdPromptColor
    var background: NerdPromptColor
    var leftEdge: NerdPromptSegmentEdge = .match
    var rightEdge: NerdPromptSegmentEdge = .angled

    var title: String {
        kind == .literal ? "Text: \(literal)" : kind.title
    }

    var previewText: String {
        switch kind {
        case .os: return ""
        case .home: return " ~"
        case .currentDirectory: return " ~/src/AIBasic/Code"
        case .gitBranch: return "git  feature/classes"
        case .gitStatus: return "!1 ⇡2"
        case .user: return "bobby"
        case .literal: return literal.isEmpty ? "Text" : literal
        case .newline: return "↵"
        }
    }

    var templateSource: String {
        switch kind {
        case .os: return ""
        case .home: return " ~"
        case .currentDirectory: return " ${currentdir}"
        case .gitBranch: return "git  ${gitstatus}"
        case .gitStatus: return "!1"
        case .user: return "${user}"
        case .literal: return literal
        case .newline: return "%nl"
        }
    }

    static let shellStylePreset: [NerdPromptSegment] = [
        NerdPromptSegment(kind: .os, foreground: .black, background: .silver),
        NerdPromptSegment(kind: .currentDirectory, foreground: .white, background: .purple),
        NerdPromptSegment(kind: .gitBranch, foreground: .black, background: .gold),
        NerdPromptSegment(kind: .gitStatus, literal: "!1", foreground: .black, background: .gold),
        NerdPromptSegment(kind: .literal, literal: "Ready", foreground: .black, background: .green)
    ]
}

enum NerdPromptColor: String, CaseIterable {
    case terminalBackground
    case black
    case white
    case silver
    case blue
    case purple
    case gold
    case green
    case red

    var title: String {
        switch self {
        case .terminalBackground: return "Terminal"
        case .black: return "Black"
        case .white: return "White"
        case .silver: return "Silver"
        case .blue: return "Blue"
        case .purple: return "Purple"
        case .gold: return "Gold"
        case .green: return "Green"
        case .red: return "Red"
        }
    }

    var ansiCode: Int {
        switch self {
        case .terminalBackground: return 0
        case .black: return 16
        case .white: return 15
        case .silver: return 250
        case .blue: return 57
        case .purple: return 99
        case .gold: return 142
        case .green: return 40
        case .red: return 196
        }
    }
}

enum NerdPromptSegmentEdge: String, CaseIterable {
    case match
    case rounded
    case angled
    case flat

    var title: String {
        switch self {
        case .match: return "Match"
        case .rounded: return "Rounded"
        case .angled: return "Angled"
        case .flat: return "Flat"
        }
    }

    static let leftChoices: [NerdPromptSegmentEdge] = [.match, .rounded, .angled, .flat]
    static let rightChoices: [NerdPromptSegmentEdge] = [.rounded, .angled, .flat]

    var leftGlyph: String? {
        switch self {
        case .match: return nil
        case .rounded: return ""
        case .angled: return ""
        case .flat: return nil
        }
    }

    var rightGlyph: String? {
        switch self {
        case .match: return nil
        case .rounded: return ""
        case .angled: return ""
        case .flat: return nil
        }
    }

    func matchedLeftGlyph(previousRightEdge: NerdPromptSegmentEdge?) -> String? {
        guard self == .match else { return nil }
        return previousRightEdge?.rightGlyph
    }
}

enum NerdPromptTemplateBuilder {
    static func template(for segments: [NerdPromptSegment]) -> String {
        guard !segments.isEmpty else { return BASICSession.defaultPromptTemplate }
        var output = ""
        for index in segments.indices {
            let segment = segments[index]
            if segment.kind == .newline {
                output += "%nl"
                continue
            }

            let previousSegment = segments[safe: index - 1]
            if let matchedGlyph = segment.leftEdge.matchedLeftGlyph(previousRightEdge: previousSegment?.rightEdge),
               let previousSegment {
                output += sgr(foreground: previousSegment.background, background: segment.background)
                output += matchedGlyph
            } else if let leftGlyph = segment.leftEdge.leftGlyph {
                let leftBackground = segment.leftEdge == .match ? previousSegment?.background : nil
                output += sgr(foreground: segment.background, background: leftBackground)
                output += leftGlyph
            }

            output += sgr(foreground: segment.foreground, background: segment.background)
            output += " \(segment.templateSource) "

            let nextSegment = segments[safe: index + 1]
            let hasAdjacentSegment = nextSegment?.kind != nil && nextSegment?.kind != .newline

            if nextSegment?.leftEdge != .match,
               let rightGlyph = segment.rightEdge.rightGlyph,
               let next = nextSegment,
               next.kind != .newline {
                output += sgr(foreground: segment.background, background: next.background)
                output += rightGlyph
            } else if nextSegment?.leftEdge != .match,
                      let rightGlyph = segment.rightEdge.rightGlyph {
                output += sgr(foreground: segment.background, background: nil)
                output += rightGlyph
            }

            if !hasAdjacentSegment {
                output += reset
                output += " "
            }
        }
        return output
    }

    private static var reset: String {
        "\u{001B}[0m"
    }

    private static func sgr(foreground: NerdPromptColor, background: NerdPromptColor?) -> String {
        var parts = ["38;5;\(foreground.ansiCode)"]
        if let background, background != .terminalBackground {
            parts.append("48;5;\(background.ansiCode)")
        } else {
            parts.append("49")
        }
        return "\u{001B}[\(parts.joined(separator: ";"))m"
    }
}

extension Array {
    subscript(safe index: Index) -> Element? {
        indices.contains(index) ? self[index] : nil
    }
}
