import BASICSyntax
import Foundation

/// Reads a `.bas` file into parsed statements through the interpreter's own
/// line splitter and statement flattener, so both engines agree on what
/// "line 12, statement 2" means — and expands `IMPORT` the way the
/// interpreter does:
///
/// - `IMPORT "lib.bas"` splices the file in place of the directive;
/// - `IMPORT "lib/"` splices every `.bas` under the directory, recursively,
///   in Finder order;
/// - relative paths resolve against the importing file's directory;
/// - a file is imported once, and a cycle is an error naming the chain.
///
/// Imported lines are marked `isImported`, which is what keeps their `DATA`
/// out of the program's DATA list, as in the interpreter.
public struct SourceLoader {
    /// Inside a `.basproj`, IMPORT paths resolve against the project root.
    private let projectRoot: String?
    private let libraries: LibraryIndex

    /// Creates a loader; give a project root to resolve imports against it,
    /// and the project's libraries for imports that name one.
    public init(projectRoot: String? = nil, libraries: LibraryIndex = LibraryIndex()) {
        self.projectRoot = projectRoot
        self.libraries = libraries
    }

    /// Loads, parses, and import-expands a program file.
    public func load(path: String) throws -> [ParsedLine] {
        let lines = try loadLines(path: path, isImported: false)
        var importedPaths: Set<String> = []
        var activeImports: [String] = []
        let expanded = try expand(lines, importedPaths: &importedPaths, activeImports: &activeImports)
        return try parse(expanded)
    }

    /// Parses program text as if it came from `fileName`, without imports.
    public func parse(_ source: String, fileName: String?) throws -> [ParsedLine] {
        try parse(ProgramLine.parse(source, fileName: fileName, isImported: false))
    }

    private func parse(_ lines: [ProgramLine]) throws -> [ParsedLine] {
        do {
            return try ProgramParser.parse(lines)
        } catch let failure as ProgramParser.Failure {
            throw CompileError([
                Diagnostic(severity: .error, file: failure.fileName, line: failure.lineNumber, message: failure.error.description)
            ])
        } catch let error as BASICError {
            throw CompileError(error.description, at: nil)
        }
    }

    private func loadLines(path: String, isImported: Bool) throws -> [ProgramLine] {
        let source: String
        do {
            source = try String(contentsOfFile: path, encoding: .utf8)
        } catch {
            throw CompileError("cannot read \(path): \(error.localizedDescription)", at: nil)
        }
        return ProgramLine.parse(source, fileName: path, isImported: isImported)
    }

    // MARK: - IMPORT

    private func expand(_ lines: [ProgramLine], importedPaths: inout Set<String>, activeImports: inout [String]) throws -> [ProgramLine] {
        var expanded: [ProgramLine] = []
        for line in lines {
            guard let path = Self.importPath(in: line) else {
                expanded.append(line)
                continue
            }
            let resolved = projectRoot.map { Self.normalizedImportPath($0 + "/" + path) }
                ?? Self.resolvedImportPath(path, relativeTo: line.fileName)
            let location = BIRLocation(file: line.fileName, line: line.sourceLineNumber ?? 0, statement: 0, lineNumber: line.number)
            let files: [String]
            if Self.isDirectoryImportPath(path) {
                files = try Self.basFiles(in: resolved, at: location)
            } else if let library = libraryDirectory(for: path, resolved: resolved) {
                // A library is a directory of sources, imported whole — the
                // interpreter's rule, so a program means the same thing to
                // both. The project's own files come first: this is only
                // reached when nothing under the root answered to the name.
                files = try Self.basFiles(in: library, at: location)
            } else {
                files = [resolved]
            }
            for file in files {
                let normalized = Self.normalizedImportPath(file)
                if activeImports.contains(normalized) {
                    throw CompileError("Import cycle detected: \((activeImports + [normalized]).joined(separator: " -> "))", at: location)
                }
                guard !importedPaths.contains(normalized) else { continue }
                importedPaths.insert(normalized)
                activeImports.append(normalized)
                defer { activeImports.removeLast() }
                guard FileManager.default.fileExists(atPath: normalized) else {
                    throw CompileError("IMPORT could not find \(path)", at: location)
                }
                let imported = try loadLines(path: normalized, isImported: true)
                expanded += try expand(imported, importedPaths: &importedPaths, activeImports: &activeImports)
            }
        }
        return expanded
    }

    /// The sources of the library an import names, when the project's own
    /// files do not answer to it. `IMPORT "charts"` finds it by name and
    /// `IMPORT "Libraries/charts.baslib"` by path; both mean the library.
    private func libraryDirectory(for path: String, resolved: String) -> String? {
        guard !libraries.isEmpty else { return nil }
        let extensionName = (path as NSString).pathExtension.lowercased()
        guard extensionName.isEmpty || extensionName == "baslib" else { return nil }
        // A `.baslib` is a container even though the path exists: it is not
        // a file of source to be read.
        if extensionName.isEmpty, FileManager.default.fileExists(atPath: resolved) { return nil }
        return libraries.sources(forLibraryNamed: path)
    }

    /// The path an `IMPORT` line names, or nil for any other line.
    private static func importPath(in line: ProgramLine) -> String? {
        guard var parser = try? Parser(source: line.source),
              let statement = try? parser.parseStatement(),
              case .importDirective(let path) = statement else { return nil }
        return path
    }

    static func isDirectoryImportPath(_ path: String) -> Bool {
        path.hasSuffix("/") || path.hasSuffix("\\")
    }

    /// Every `.bas` under a directory, recursively, in Finder order.
    private static func basFiles(in directory: String, at location: BIRLocation) throws -> [String] {
        var root = directory.replacingOccurrences(of: "\\", with: "/")
        while root.hasSuffix("/") { root.removeLast() }
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: root, isDirectory: &isDirectory), isDirectory.boolValue,
              let enumerator = FileManager.default.enumerator(at: URL(fileURLWithPath: root), includingPropertiesForKeys: [.isRegularFileKey], options: [.skipsHiddenFiles]) else {
            throw CompileError("IMPORT could not find directory \(directory)", at: location)
        }
        return enumerator
            .compactMap { $0 as? URL }
            .filter { (try? $0.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true }
            .map { String($0.standardizedFileURL.path.dropFirst(URL(fileURLWithPath: root).standardizedFileURL.path.count + 1)) }
            .filter { $0.lowercased().hasSuffix(".bas") }
            .sorted { $0.localizedStandardCompare($1) == .orderedAscending }
            .map { root + "/" + $0.trimmingCharacters(in: CharacterSet(charactersIn: "/\\")) }
    }

    static func resolvedImportPath(_ path: String, relativeTo importer: String?) -> String {
        let normalized = normalizedImportPath(path)
        guard !normalized.hasPrefix("/"), let importer, let separator = normalizedImportPath(importer).lastIndex(of: "/") else {
            return normalized
        }
        let base = String(normalizedImportPath(importer)[..<separator])
        return base.isEmpty ? normalized : normalizedImportPath(base + "/" + normalized)
    }

    /// Collapses `.` and `..` the way the interpreter does, keeping a
    /// trailing slash for directory imports.
    static func normalizedImportPath(_ path: String) -> String {
        let usesTrailingSlash = path.hasSuffix("/") || path.hasSuffix("\\")
        let isAbsolute = path.hasPrefix("/") || path.hasPrefix("\\")
        var stack: [String] = []
        for component in path.replacingOccurrences(of: "\\", with: "/").split(separator: "/", omittingEmptySubsequences: true).map(String.init) {
            switch component {
            case ".": continue
            case "..":
                if let last = stack.last, last != ".." { stack.removeLast() } else if !isAbsolute { stack.append(component) }
            default: stack.append(component)
            }
        }
        var result = (isAbsolute ? "/" : "") + stack.joined(separator: "/")
        if usesTrailingSlash, !result.hasSuffix("/") { result += "/" }
        return result
    }
}
