//
//  BASICRecipe.swift
//  BASICRecipes
//
//  A recipe for a new BASIC project, and making a project from one.
//

import Foundation

/// A recipe for a new project: what it is called, what it makes, and the
/// files it writes.
///
/// It is OmniClide's recipe, in the same `recipe.json` form, so a recipe
/// written for one tool works in the others:
///
/// ```text
///   game/
///     recipe.json        { "identifier": "basic.game", "name": "Game",
///                          "language": "BASIC", "summary": "…",
///                          "folderExtension": "basproj",
///                          "openFile": "src/main.bas" }
///     src/main.bas       every other file is a file the project gets,
///     Makefile           at the same path, with {{NAME}} and the options'
///     …                  {{KEY}}s filled in, in its path and its text
/// ```
public struct BASICRecipe: Equatable, Sendable, Identifiable {
    /// `recipe.json`.
    public struct Definition: Codable, Equatable, Sendable {
        /// Unique: `basic.game`.
        public var identifier: String
        /// Its name in a list of recipes.
        public var name: String
        /// The language a wizard groups it under.
        public var language: String
        /// A sentence or two on what it makes.
        public var summary: String
        /// Said once the project is made.
        public var postNote: String?
        /// Values the user is asked for, each filling a `{{KEY}}`.
        public var options: [Option]?
        /// An SF Symbol for the recipe, where a tool shows icons.
        public var icon: String?
        /// The project folder's extension: `basproj` makes `Name.basproj`.
        public var folderExtension: String?
        /// The file to open once the project is made, inside it.
        public var openFile: String?

        public init(
            identifier: String, name: String, language: String, summary: String,
            postNote: String? = nil, options: [Option]? = nil, icon: String? = nil,
            folderExtension: String? = nil, openFile: String? = nil
        ) {
            self.identifier = identifier
            self.name = name
            self.language = language
            self.summary = summary
            self.postNote = postNote
            self.options = options
            self.icon = icon
            self.folderExtension = folderExtension
            self.openFile = openFile
        }
    }

    /// A value the user is asked for. A text field, or, with `checkedValue`,
    /// a checkbox that fills its `{{KEY}}` with `checkedValue` when checked
    /// and with nothing when not.
    public struct Option: Codable, Equatable, Sendable {
        public var key: String
        public var prompt: String
        public var defaultValue: String?
        public var checkedValue: String?

        public var isCheckbox: Bool { checkedValue != nil }

        public init(key: String, prompt: String, defaultValue: String? = nil, checkedValue: String? = nil) {
            self.key = key
            self.prompt = prompt
            self.defaultValue = defaultValue
            self.checkedValue = checkedValue
        }
    }

    /// A file the project gets: its path inside the project, and its text.
    public struct File: Equatable, Sendable {
        public var path: String
        public var contents: String

        public init(path: String, contents: String) {
            self.path = path
            self.contents = contents
        }
    }

    public var definition: Definition
    /// In path order.
    public var files: [File]

    public var id: String { definition.identifier }

    public init(definition: Definition, files: [File]) {
        self.definition = definition
        self.files = files.sorted { $0.path < $1.path }
    }

    /// A recipe from the text of its `recipe.json` and its files.
    public init(json: String, files: [File]) throws {
        let definition = try JSONDecoder().decode(Definition.self, from: Data(json.utf8))
        self.init(definition: definition, files: files)
    }
}

// MARK: - Making a project

extension BASICRecipe {
    /// Why a project cannot be made.
    public struct Failure: Error, CustomStringConvertible, Equatable {
        public let description: String

        public init(_ description: String) {
            self.description = description
        }
    }

    /// What is wrong with `name` as a project's name, or nil when nothing is.
    ///
    /// The name is the program's too: the Makefile builds `Build/<name>`, so
    /// it is letters, digits, `-` and `_`, beginning with a letter or digit.
    public static func problem(withName name: String) -> String? {
        let name = name.trimmingCharacters(in: .whitespaces)
        if name.isEmpty {
            return "A project needs a name."
        }
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-_"))
        if name.unicodeScalars.contains(where: { !allowed.contains($0) }) {
            return "A project's name can have letters, digits, - and _, but no spaces or other characters."
        }
        if let first = name.unicodeScalars.first, !CharacterSet.alphanumerics.contains(first) {
            return "A project's name begins with a letter or a digit."
        }
        return nil
    }

    /// The project's folder: `Name.basproj`, or `Name` for a recipe that
    /// names no extension.
    public func folderName(for name: String) -> String {
        let name = name.trimmingCharacters(in: .whitespaces)
        guard let folderExtension = definition.folderExtension, !folderExtension.isEmpty else { return name }
        return name + "." + folderExtension
    }

    /// The values the options fill: what the user gave, else the defaults.
    /// A checkbox's value is its `checkedValue` when given anything but
    /// empty or "false", and nothing otherwise.
    public func optionValues(_ given: [String: String] = [:]) -> [String: String] {
        var values: [String: String] = [:]
        for option in definition.options ?? [] {
            let value = given[option.key] ?? option.defaultValue ?? ""
            if let checked = option.checkedValue {
                let on = !value.isEmpty && value.lowercased() != "false"
                values[option.key] = on ? checked : ""
            } else {
                values[option.key] = value
            }
        }
        return values
    }

    /// `text` with `{{NAME}}`, `{{NAME_LOWER}}` and each option's `{{KEY}}`
    /// filled in. Nothing else changes: an unknown `{{TOKEN}}` stays as it is.
    public static func substitute(_ text: String, name: String, values: [String: String]) -> String {
        var result = text
            .replacingOccurrences(of: "{{NAME}}", with: name)
            .replacingOccurrences(of: "{{NAME_LOWER}}", with: name.lowercased())
        for (key, value) in values {
            result = result.replacingOccurrences(of: "{{\(key)}}", with: value)
        }
        return result
    }

    /// Makes the project `name` in `parent`, and returns its folder.
    ///
    /// Refuses a bad name, and a folder that is already there: nothing that
    /// exists is ever written over.
    @discardableResult
    public func create(named rawName: String, in parent: URL, options given: [String: String] = [:]) throws -> URL {
        if let problem = Self.problem(withName: rawName) {
            throw Failure(problem)
        }
        let name = rawName.trimmingCharacters(in: .whitespaces)
        let fileManager = FileManager.default
        let root = parent.appendingPathComponent(folderName(for: name), isDirectory: true)
        guard !fileManager.fileExists(atPath: root.path) else {
            throw Failure("\(root.lastPathComponent) is already there.")
        }
        let values = optionValues(given)
        try fileManager.createDirectory(at: root, withIntermediateDirectories: true)
        for file in files {
            let path = Self.substitute(file.path, name: name, values: values)
            let url = root.appendingPathComponent(path)
            try fileManager.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try Self.substitute(file.contents, name: name, values: values).write(to: url, atomically: true, encoding: .utf8)
        }
        return root
    }

    /// The file to open in a project made from this recipe, if it names one.
    public func fileToOpen(in project: URL, name: String, options given: [String: String] = [:]) -> URL? {
        guard let openFile = definition.openFile else { return nil }
        return project.appendingPathComponent(Self.substitute(openFile, name: name, values: optionValues(given)))
    }
}
