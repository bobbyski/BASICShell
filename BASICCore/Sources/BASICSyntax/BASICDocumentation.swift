//
//  BASICDocumentation.swift
//  BASICCore
//
//  Documentation comments: `///` above a declaration, read the way Swift
//  reads them.
//
//  ## Why Swift's rules
//
//  BASIC never had documentation comments. VB grew `'''` with XML inside it,
//  which nobody enjoys writing. This BASIC already reads `//` as a comment,
//  so `///` is a comment in every tool that exists today — the interpreter,
//  the compiler, every editor — and costs nothing to adopt. Swift's rules
//  for what a `///` block *means* are Markdown with a handful of callouts,
//  and the people writing this BASIC write Swift beside it. One set of
//  rules for both, so nobody learns a second.
//
//  ## The rules
//
//  ```basic
//  /// Squares a number.
//  ///
//  /// Multiplies the number by itself. A second paragraph is the
//  /// discussion, and it is Markdown: `code`, **bold**, lists.
//  ///
//  /// - Parameter n: The number to square.
//  /// - Returns: `n` times `n`.
//  FUNCTION Square(n AS DOUBLE) AS DOUBLE
//  ```
//
//  - A documentation comment is one or more lines that start with exactly
//    `///` (after indentation). `////` is an ordinary comment, as in Swift.
//  - It documents the declaration on the line **immediately** after it. A
//    blank line or any other line in between detaches it, and `basiclint`
//    says so (`doc.detached`) rather than letting it vanish.
//  - The first paragraph is the **summary**; the rest is the **discussion**.
//  - Callouts are list items: `- Parameter name: text`, or `- Parameters:`
//    with one nested `- name: text` per parameter; `- Returns: text`;
//    `- Throws: text` (the errors it raises); and Swift's others — `Note`,
//    `Warning`, `Important`, `Precondition`, `SeeAlso`, `ToDo` and the rest.
//    Keywords match without regard to case, as in Swift.
//  - Swift's `/** … */` block form has no BASIC equivalent: this BASIC has no
//    block comments at all, and adding one for this would be a language
//    change, not a documentation feature.
//
//  What can be documented: `FUNCTION` (and methods), `DEF FN`, `CLASS`,
//  `TYPE`, `RECORD`, `INTERFACE` and its signatures, `ENUM` and its cases,
//  `FUNCTION TYPE`, fields, and `GLOBAL`/`DIM` variables.
//
//  This file only reads. The shell's `HELP name` renders a symbol's
//  documentation, `basiclint` checks it against the declaration, and the
//  syntax tokenizer marks `///` lines so an editor can set them apart.

import Foundation

/// A parsed documentation comment.
public struct BASICDocComment: Equatable, Sendable {
    /// One documented parameter.
    public struct Parameter: Equatable, Sendable {
        /// The name as the comment spells it.
        public let name: String
        /// What it says about the parameter.
        public let text: String
        /// The comment line it is on, 0-based within the comment.
        public let line: Int

        public init(name: String, text: String, line: Int) {
            self.name = name
            self.text = text
            self.line = line
        }
    }

    /// One callout other than parameters and returns: `- Note: …`.
    public struct Callout: Equatable, Sendable {
        /// The keyword, capitalized the way Swift documents it: `Note`.
        public let kind: String
        public let text: String

        public init(kind: String, text: String) {
            self.kind = kind
            self.text = text
        }
    }

    /// The comment's text, `///` and one following space removed per line.
    public let lines: [String]
    /// The first paragraph.
    public let summary: String
    /// Everything after the summary that is not a callout, as Markdown.
    public let discussion: String
    public let parameters: [Parameter]
    public let returns: String?
    /// `- Throws:` — for BASIC, the errors a routine raises.
    public let throwsText: String?
    public let callouts: [Callout]

    /// Parses the text of a comment, one entry per `///` line.
    public init(lines: [String]) {
        self.lines = lines
        var paragraphs: [[String]] = []
        var current: [String] = []
        var parameters: [Parameter] = []
        var returns: String?
        var throwsText: String?
        var callouts: [Callout] = []

        // Which callout continuation lines belong to, and the indentation
        // its bullet started at: a following line indented past the bullet
        // continues it, as a Markdown list item continues.
        enum Open { case parameter(Int), returns, throwsText, callout(Int) }
        var open: (what: Open, indent: Int)?
        // While a `- Parameters:` list is open, the indentation of its bullet;
        // items indented past it are parameters.
        var parameterListIndent: Int?

        func append(_ text: String, to target: Open) {
            let piece = text.trimmingCharacters(in: .whitespaces)
            guard !piece.isEmpty else { return }
            func joined(_ existing: String) -> String { existing.isEmpty ? piece : existing + " " + piece }
            switch target {
            case .parameter(let index):
                let old = parameters[index]
                parameters[index] = Parameter(name: old.name, text: joined(old.text), line: old.line)
            case .returns: returns = joined(returns ?? "")
            case .throwsText: throwsText = joined(throwsText ?? "")
            case .callout(let index):
                let old = callouts[index]
                callouts[index] = Callout(kind: old.kind, text: joined(old.text))
            }
        }

        func flushParagraph() {
            if !current.isEmpty { paragraphs.append(current) }
            current = []
        }

        for (number, line) in lines.enumerated() {
            let indent = line.prefix { $0 == " " || $0 == "\t" }.count
            let trimmed = line.trimmingCharacters(in: .whitespaces)

            if trimmed.isEmpty {
                flushParagraph()
                open = nil
                parameterListIndent = nil
                continue
            }

            if let item = Self.listItem(trimmed) {
                // An item nested under `- Parameters:` names one parameter.
                if let listIndent = parameterListIndent, indent > listIndent {
                    if let (name, text) = Self.nameAndText(item) {
                        parameters.append(Parameter(name: name, text: text, line: number))
                        open = (.parameter(parameters.count - 1), indent)
                    }
                    continue
                }
                parameterListIndent = nil

                if let (keyword, rest) = Self.nameAndText(item) {
                    let words = keyword.split(separator: " ", maxSplits: 1).map(String.init)
                    let head = words[0].lowercased()
                    var handled = true
                    if head == "parameter", words.count == 2 {
                        parameters.append(Parameter(name: words[1], text: rest, line: number))
                        open = (.parameter(parameters.count - 1), indent)
                    } else if words.count == 1, head == "parameters" {
                        parameterListIndent = indent
                        open = nil
                    } else if words.count == 1, head == "returns" || head == "return" {
                        returns = rest
                        open = (.returns, indent)
                    } else if words.count == 1, head == "throws" {
                        throwsText = rest
                        open = (.throwsText, indent)
                    } else if words.count == 1, let kind = Self.calloutKinds[head] {
                        callouts.append(Callout(kind: kind, text: rest))
                        open = (.callout(callouts.count - 1), indent)
                    } else {
                        handled = false
                    }
                    if handled {
                        flushParagraph()
                        continue
                    }
                }
            }

            // Not a callout: a continuation of the open one when indented
            // past its bullet, otherwise ordinary Markdown.
            if let (what, openIndent) = open, indent > openIndent {
                append(trimmed, to: what)
                continue
            }
            open = nil
            parameterListIndent = nil
            current.append(line)
        }
        flushParagraph()

        let first = paragraphs.first ?? []
        summary = first.map { $0.trimmingCharacters(in: .whitespaces) }.joined(separator: " ")
        discussion = paragraphs.dropFirst()
            .map { $0.joined(separator: "\n") }
            .joined(separator: "\n\n")
        self.parameters = parameters
        self.returns = returns
        self.throwsText = throwsText
        self.callouts = callouts
    }

    /// The text of a list item, or nil: `- x`, `* x`, `+ x`.
    static func listItem(_ trimmed: String) -> String? {
        guard let first = trimmed.first, "-*+".contains(first) else { return nil }
        let rest = trimmed.dropFirst()
        guard rest.first == " " else { return nil }
        return rest.trimmingCharacters(in: .whitespaces)
    }

    /// `Keyword: text` split at the first colon, or nil when there is none.
    static func nameAndText(_ item: String) -> (String, String)? {
        guard let colon = item.firstIndex(of: ":") else { return nil }
        let name = item[..<colon].trimmingCharacters(in: .whitespaces)
        guard !name.isEmpty, !name.contains("`") else { return nil }
        let text = item[item.index(after: colon)...].trimmingCharacters(in: .whitespaces)
        return (name, text)
    }

    /// Swift's callouts other than parameters, returns and throws, by their
    /// lowercased keyword, spelled as Swift's documentation spells them.
    static let calloutKinds: [String: String] = {
        let kinds = ["Attention", "Author", "Authors", "Bug", "Complexity", "Copyright", "Date",
                     "Experiment", "Important", "Invariant", "LocalizationKey", "MutatingVariant",
                     "NonMutatingVariant", "Note", "Postcondition", "Precondition", "Remark",
                     "Remarks", "Requires", "SeeAlso", "Since", "Tag", "ToDo", "Version", "Warning"]
        return Dictionary(uniqueKeysWithValues: kinds.map { ($0.lowercased(), $0) })
    }()
}

/// A declaration, with the documentation written above it when there is any.
public struct BASICDocumentedSymbol: Equatable, Sendable {
    /// What was declared.
    public enum Kind: String, Equatable, Sendable {
        case function, method, classType = "class", typeRecord = "type", interface, interfaceMethod = "interface method"
        case enumeration = "enum", enumCase = "enum case", functionType = "function type", field, variable
    }

    public let kind: Kind
    /// The name as written: `Square`.
    public let name: String
    /// The enclosing CLASS, TYPE, INTERFACE or ENUM, when there is one.
    public let container: String?
    /// The parameters, as written, for anything that takes them.
    public let parameters: [String]
    /// Whether the declaration returns something (a FUNCTION that is not void).
    public let returnsValue: Bool
    /// The declaration line, trimmed and without a trailing comment.
    public let declaration: String
    public let fileName: String?
    /// The declaration's line, 1-based.
    public let line: Int
    /// The comment above it, or nil when there is none.
    public let documentation: BASICDocComment?
    /// The line the comment starts on, 1-based.
    public let documentationLine: Int?

    /// `Container.Name`, or `Name` at the top level.
    public var qualifiedName: String {
        container.map { "\($0).\(name)" } ?? name
    }
}

/// A `///` block that documents nothing: nothing follows it, or something
/// other than a declaration does.
public struct BASICDetachedDocComment: Equatable, Sendable {
    public let line: Int
    /// Why it is detached, in a phrase: "a blank line follows it".
    public let reason: String
}

/// Reads documentation comments out of source text.
public enum BASICDocumentation {

    /// The text of a documentation comment line, or nil when the line is not
    /// one: exactly `///` after indentation, not `////`, as in Swift. One
    /// space after the slashes is part of the marker and is removed.
    public static func commentText(_ line: String) -> String? {
        let trimmed = line.drop { $0 == " " || $0 == "\t" }
        guard trimmed.hasPrefix("///"), !trimmed.hasPrefix("////") else { return nil }
        var text = trimmed.dropFirst(3)
        if text.first == " " { text = text.dropFirst() }
        return String(text)
    }

    /// Every declaration in `source`, documented or not, in source order.
    public static func symbols(in source: String, fileName: String? = nil) -> [BASICDocumentedSymbol] {
        scan(source, fileName: fileName).symbols
    }

    /// The comments in `source` that document nothing.
    public static func detachedComments(in source: String) -> [BASICDetachedDocComment] {
        scan(source, fileName: nil).detached
    }

    /// The symbol a name refers to: `Square`, or `Shape.Area` for a member.
    /// Matched without regard to case, because BASIC names are.
    public static func symbol(named query: String, in symbols: [BASICDocumentedSymbol]) -> BASICDocumentedSymbol? {
        let wanted = query.uppercased()
        return symbols.first { $0.qualifiedName.uppercased() == wanted }
            ?? symbols.first { $0.name.uppercased() == wanted }
    }

    // MARK: - Scanning

    private static func scan(_ source: String, fileName: String?) -> (symbols: [BASICDocumentedSymbol], detached: [BASICDetachedDocComment]) {
        var symbols: [BASICDocumentedSymbol] = []
        var detached: [BASICDetachedDocComment] = []
        var pending: (line: Int, text: [String])?
        // The CLASS/TYPE/INTERFACE/ENUM being read, innermost last.
        var containers: [(kind: String, name: String)] = []

        func detach(_ reason: String) {
            if let pending { detached.append(BASICDetachedDocComment(line: pending.line, reason: reason)) }
            pending = nil
        }

        let lines = source.split(separator: "\n", omittingEmptySubsequences: false).map {
            $0.hasSuffix("\r") ? String($0.dropLast()) : String($0)
        }
        for (index, raw) in lines.enumerated() {
            let lineNumber = index + 1
            if let text = commentText(raw) {
                if pending == nil { pending = (lineNumber, []) }
                pending!.text.append(text)
                continue
            }
            let code = stripComment(raw).trimmingCharacters(in: .whitespaces)
            if code.isEmpty {
                detach(raw.trimmingCharacters(in: .whitespaces).isEmpty
                       ? "a blank line separates it from what follows"
                       : "an ordinary comment separates it from what follows")
                continue
            }

            let words = code.split(whereSeparator: { $0 == " " || $0 == "\t" }).map { $0.uppercased() }

            // The end of a block: members after it belong to the one outside.
            if words.first == "END", words.count >= 2,
               ["CLASS", "TYPE", "RECORD", "INTERFACE", "ENUM"].contains(words[1]) {
                if !containers.isEmpty { containers.removeLast() }
                detach("it is above an END \(words[1]), which declares nothing")
                continue
            }

            let doc = pending.map { BASICDocComment(lines: $0.text) }
            let docLine = pending?.line
            let enclosing = containers.last?.name
            func add(_ kind: BASICDocumentedSymbol.Kind, _ name: String, parameters: [String] = [], returnsValue: Bool = false, topLevel: Bool = false) {
                symbols.append(BASICDocumentedSymbol(
                    kind: kind, name: name, container: topLevel ? nil : enclosing, parameters: parameters,
                    returnsValue: returnsValue, declaration: code, fileName: fileName, line: lineNumber,
                    documentation: doc, documentationLine: docLine
                ))
                pending = nil
            }

            // Inside an ENUM, a bare name is a case; the parser only knows that
            // when it reads the whole block, so it is recognized here.
            if containers.last?.kind == "ENUM" {
                let name = code.prefix { $0.isLetter || $0.isNumber || $0 == "_" }
                if !name.isEmpty { add(.enumCase, String(name)); continue }
            }

            // An ENUM header on its own is not a statement the line parser
            // accepts — it gathers the block — so it is recognized by its words.
            if let enumAt = words.firstIndex(of: "ENUM"), enumAt + 1 < words.count,
               words[..<enumAt].allSatisfy({ ["PUBLIC", "PRIVATE"].contains($0) }) {
                let name = code.split(whereSeparator: { $0 == " " || $0 == "\t" })[enumAt + 1]
                add(.enumeration, String(name))
                containers.append(("ENUM", String(name)))
                continue
            }

            guard let statement = firstStatement(of: code) else {
                detach("the line after it is not a declaration")
                continue
            }
            let inClass = containers.last.map { $0.kind == "CLASS" } ?? false
            switch statement {
            case .functionDeclaration(let name, let parameters, let returnType, _, _, _, _):
                add(inClass ? .method : .function, name.name,
                    parameters: parameters.map(\.variable.name), returnsValue: returnType != .void)
            case .defFunction(let name, let parameter, _, _):
                add(.function, name.name, parameters: [parameter.variable.name], returnsValue: true)
            case .classDeclaration(let name):
                add(.classType, name)
                containers.append(("CLASS", name))
            case .typeDeclaration(let name):
                add(.typeRecord, name)
                containers.append((words.first == "RECORD" ? "RECORD" : "TYPE", name))
            case .interfaceDeclaration(let name):
                add(.interface, name)
                containers.append(("INTERFACE", name))
            case .interfaceFunctionSignature(let name, let parameters, let returnType):
                add(.interfaceMethod, name.name,
                    parameters: parameters.map(\.variable.name), returnsValue: returnType != .void)
            case .functionTypeDeclaration(let name, let parameters, let returnType, _):
                add(.functionType, name,
                    parameters: parameters.map(\.variable.name), returnsValue: returnType != .void)
            case .classField(let name, _, _, _, _, _, _), .typeField(let name, _, _, _, _, _, _):
                add(.field, name)
            case .assignment(.global, let name, _, _), .dim(_, let name, _, _):
                add(.variable, name.name, topLevel: true)
            default:
                detach("the line after it is not a declaration")
            }
        }
        detach("nothing follows it")
        return (symbols, detached)
    }

    /// The first statement on a line, when it parses on its own.
    private static func firstStatement(of code: String) -> Statement? {
        guard let parsed = try? ProgramParser.parse(ProgramLine.parse(code, fileName: nil, isImported: false)),
              var statement = parsed.first?.statement else { return nil }
        while true {
            switch statement {
            case .labeled(_, let inner): statement = inner
            case .sequence(let parts) where !parts.isEmpty: statement = parts[0]
            default: return statement
            }
        }
    }

    /// A line without its trailing `'` or `//` comment, strings respected.
    private static func stripComment(_ line: String) -> String {
        var inString = false
        var previous: Character?
        for (offset, character) in line.enumerated() {
            if character == "\"" { inString.toggle() }
            if !inString {
                if character == "'" { return String(line.prefix(offset)) }
                if character == "/", previous == "/" { return String(line.prefix(offset - 1)) }
            }
            previous = character
        }
        // A whole-line `REM` or `#` comment declares nothing either.
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        if trimmed.uppercased().hasPrefix("REM ") || trimmed.uppercased() == "REM" || trimmed.hasPrefix("#") { return "" }
        return line
    }

    // MARK: - Rendering

    /// A symbol's documentation as Markdown: the declaration, the summary,
    /// the discussion, then the callouts — the order Xcode's Quick Help uses.
    public static func markdown(for symbol: BASICDocumentedSymbol) -> String {
        var parts = ["`\(symbol.declaration)`"]
        guard let doc = symbol.documentation else {
            parts.append("No documentation. Write `///` lines directly above the declaration.")
            return parts.joined(separator: "\n\n")
        }
        if !doc.summary.isEmpty { parts.append(doc.summary) }
        if !doc.discussion.isEmpty { parts.append(doc.discussion) }
        if !doc.parameters.isEmpty {
            parts.append("**Parameters**\n\n" + doc.parameters.map { "- `\($0.name)`: \($0.text)" }.joined(separator: "\n"))
        }
        if let returns = doc.returns { parts.append("**Returns** \(returns)") }
        if let throwsText = doc.throwsText { parts.append("**Throws** \(throwsText)") }
        for callout in doc.callouts { parts.append("**\(callout.kind)** \(callout.text)") }
        return parts.joined(separator: "\n\n")
    }
}
