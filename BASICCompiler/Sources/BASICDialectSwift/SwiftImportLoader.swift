import BASICCompilerKit
import BASICSyntax
import Foundation

/// Reads a program whose `IMPORT`s may name Swift frameworks (R4).
///
/// One pass does both halves, because they are the same question asked twice:
/// an import that names no BASIC file is offered to SwiftPM, and if a
/// dependency answers to it the framework's API becomes generated BASIC
/// (``SwiftInterfaceUnit``) *and* is remembered for lowering.
///
/// ```text
///   IMPORT "Shapes"
///        │
///        ├─ no .bas, no directory, no library
///        ▼
///   SwiftPackageResolver ─► swift build ─► swift package dump-symbol-graph
///        │                                        │
///        ▼                                        ▼
///   objects to link                        SwiftAPI ─┬─► generated BASIC
///                                                    └─► symbols to call
/// ```
public struct SwiftImportLoader {
    /// What a program's imports came to.
    public struct Result {
        /// The program, imports expanded.
        public let lines: [ParsedLine]
        /// Frameworks by module name, for lowering.
        public let imports: [String: SwiftAPI]
        /// Imported classes by normalized BASIC name, mapped to their module.
        public let externalClasses: [String: String]
        /// Objects the link must include.
        public let objects: [String]
        /// Members on imported enums, for the front end (E5).
        public var enumMembers: [String: [String: SemanticModel.EnumMemberRef]] = [:]
        /// Free functions whose bodies the object model supplies (E5).
        public var externalFunctions: Set<String> = []
    }

    /// Where the program lives; its `Package.swift` names the dependencies.
    public let programDirectory: String

    public init(programDirectory: String) {
        self.programDirectory = programDirectory
    }

    /// Loads a program, resolving Swift imports as they are met.
    public func load(path: String, projectRoot: String? = nil, libraries: LibraryIndex = LibraryIndex()) throws -> Result {
        var loader = SourceLoader(projectRoot: projectRoot, libraries: libraries)
        let resolver = SwiftPackageResolver(programDirectory: programDirectory)
        // Boxed so the escaping hook can write to them.
        final class Collected: @unchecked Sendable {
            var imports: [String: SwiftAPI] = [:]
            var externalClasses: [String: String] = [:]
            var objects: [String] = []
            var enumMembers: [String: [String: SemanticModel.EnumMemberRef]] = [:]
            var externalFunctions: Set<String> = []
        }
        let collected = Collected()
        loader.resolveForeignImport = { name, location in
            // Only a name that could be a module — not a path, not a file.
            guard !name.contains("/"), (name as NSString).pathExtension.isEmpty else { return nil }
            do {
                let package = try resolver.resolve(name)
                var api = try SwiftAPI.read(fileAt: package.symbolGraph)
                // What the binary exports decides what can be called (R4.3).
                api.keepOnly(exported: package.exported)
                collected.imports[api.module] = api
                collected.objects += package.objects
                // Async methods need a compiled shim (R3.3); see
                // `SwiftAsyncShim` for why these alone are not plain calls.
                if let shim = try resolver.buildAsyncShim(for: api, package: package) {
                    collected.objects.append(shim)
                }
                let unit = SwiftInterfaceUnit(api: api)
                collected.enumMembers.merge(unit.enumMembers) { $1 }
                collected.externalFunctions.formUnion(unit.enumMemberFunctionNames)
                for className in unit.externalClassNames {
                    collected.externalClasses[className] = api.module
                }
                let text = unit.render()
                // `BASICC_DUMP_UNITS=<dir>` writes the generated BASIC for
                // each import. The unit is real source the compiler parses,
                // and when it will not compile the first question is always
                // what it actually says.
                if let directory = ProcessInfo.processInfo.environment["BASICC_DUMP_UNITS"] {
                    try? FileManager.default.createDirectory(atPath: directory, withIntermediateDirectories: true)
                    try? text.write(toFile: (directory as NSString).appendingPathComponent("\(api.module).bas"),
                                    atomically: true, encoding: .utf8)
                }
                return text
            } catch let failure as SwiftPackageResolver.Failure {
                // A name that is not a dependency is not our business: let
                // the ordinary "IMPORT could not find" say so, which is the
                // right message for a mistyped file name.
                if failure.problem.hasPrefix("the program's Package.swift names no dependency") { return nil }
                throw CompileError(failure.description, at: location)
            } catch {
                throw CompileError("IMPORT \"\(name)\": \(error)", at: location)
            }
        }
        let lines = try loader.load(path: path)
        return Result(lines: lines, imports: collected.imports,
                      externalClasses: collected.externalClasses, objects: collected.objects,
                      enumMembers: collected.enumMembers, externalFunctions: collected.externalFunctions)
    }
}
