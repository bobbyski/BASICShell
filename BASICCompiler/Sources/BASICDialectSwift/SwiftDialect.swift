import BASICCompilerKit
import BASICDialectTraditional
import Foundation

/// Rev 2: the dialect whose objects *are* Swift objects.
///
/// The surface is the same BASIC. What changes is the substrate: a `CLASS`
/// compiles to a real Swift class — Swift class metadata, `swift_allocObject`,
/// ARC — so a BASIC object handed to Swift is a Swift object reference rather
/// than a proxy, and `IMPORT "TUIKit"` becomes a binding problem instead of a
/// bridging one.
///
/// ## Selected, never inferred from the source
///
/// `--dialect swift` picks it explicitly. A project carrying a SwiftPM
/// manifest picks it by default (``SwiftDialect/inferredFromPackageManifest``)
/// because a `Package.swift` is a statement that this program has Swift
/// dependencies to resolve — but an explicit `--dialect` always wins, and the
/// driver reports which dialect it chose either way.
///
/// ## How much of this is built
///
/// The object model is proved end to end (``SwiftClassMetadata``): a BASIC
/// class is a real Swift class, subclasses one, and is subclassed by one.
///
/// Everything that is *not* the object model — expressions, control flow,
/// strings, arrays, files — is still lowered by the traditional dialect,
/// which both dialects share as a starting point. That is deliberate
/// scaffolding, not the destination: it means `--dialect swift` compiles and
/// runs real programs today while the substrate is replaced a piece at a
/// time, instead of refusing everything until all of it is done. Each piece
/// that moves has a slice in `BASIC_COMPILER.md`:
///
/// | Still Rev 1's | Moves in |
/// |---|---|
/// | Strings (exact bytes, not `Swift.String`) | R2.1 |
/// | Arrays and dictionaries | R2.2, R2.3 |
/// | Errors (`ON ERROR` on runtime records) | R3.1 |
/// | `ASYNC`/`AWAIT` | R3.3 |
///
/// ``semantics`` therefore still reports what is *true today*, not what is
/// planned — a profile that lied about the substrate would make Sema emit
/// code the back end cannot honour.
public struct SwiftDialect: DialectCompiler {
    public static let identity = DialectIdentity(
        identifier: "swift",
        displayName: "Swift",
        summary: "BASIC objects are Swift objects — subclass Swift, be subclassed by it.",
        isDefault: false
    )

    /// Reports the substrate as it is, not as it is planned. Strings are
    /// still exact bytes because R2.1 has not landed; saying `.swiftString`
    /// here would have Sema assume a representation the lowering does not
    /// produce.
    public let semantics = SemanticProfile(
        strings: .exactBytes,
        importsSwiftFrameworks: true
    )

    /// Creates the Swift dialect.
    public init() {}

    public func lower(_ module: BIRModule, options: CompileOptions) throws -> LoweredModule {
        // Shared, not copied. A fork of Rev 1's lowering would drift from it
        // silently, and the two dialects are meant to compile the same
        // language — the divergence is the object model, and it is added
        // here rather than forked in.
        let objects = SwiftObjectModel(module: module)
        for note in objects.notes where ProcessInfo.processInfo.environment["BASICC_NOTES"] != nil {
            FileHandle.standardError.write(Data("basicc: note: \(note)\n".utf8))
        }
        let base = try TraditionalDialect().lower(module, options: options, objectModel: objects)
        return LoweredModule(name: base.name, llvmIR: base.llvmIR)
    }

    public func runtimeLibrary(for target: TargetTriple) -> RuntimeLibrary {
        // The same archive as Rev 1 — BASICRTSwift rides inside it — but only
        // the archive: every class's metadata names
        // `BASICRTSwift.BASICObject` by its mangled symbol, and the
        // compile-from-sources fallback cannot mint that name.
        RuntimeLibrary(
            name: "BASICRT",
            requiresArchiveBecause: "compiled classes descend from BASICRTSwift.BASICObject, whose symbol only the archive carries"
        )
    }

    /// Whether a source path is a project whose dependencies SwiftPM manages —
    /// the presence of a `Package.swift` beside it.
    ///
    /// This is the switch Bobby asked for: a package manifest means the
    /// program has Swift dependencies, and resolving those is the Swift
    /// dialect's job. Without one, a program links the runtime libraries
    /// built into the compiler and nothing is fetched.
    public static func inferredFromPackageManifest(
        at sourcePath: String,
        fileManager: FileManager = .default
    ) -> Bool {
        var directory = (sourcePath as NSString).standardizingPath
        var isDirectory: ObjCBool = false
        if fileManager.fileExists(atPath: directory, isDirectory: &isDirectory), !isDirectory.boolValue {
            directory = (directory as NSString).deletingLastPathComponent
        }
        // Only the program's own directory, never a walk upward: a .bas file
        // that happens to sit somewhere under an unrelated Swift package must
        // not silently change compilers.
        return fileManager.fileExists(atPath: (directory as NSString).appendingPathComponent("Package.swift"))
    }
}
