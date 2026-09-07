import BASICCompilerKit
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
/// ## Status
///
/// The seam, not the back end. `lower` refuses with a diagnostic that says so;
/// what is *proved* rather than planned lives in
/// ``SwiftClassMetadata`` and its tests.
public struct SwiftDialect: DialectCompiler {
    public static let identity = DialectIdentity(
        identifier: "swift",
        displayName: "Swift",
        summary: "BASIC objects are Swift objects — subclass Swift, be subclassed by it.",
        isDefault: false
    )

    public let semantics = SemanticProfile(
        strings: .swiftString,
        importsSwiftFrameworks: true
    )

    /// Creates the Swift dialect.
    public init() {}

    public func lower(_ module: BIRModule, options: CompileOptions) throws -> LoweredModule {
        throw CompileError([
            Diagnostic(
                severity: .error,
                file: module.name + ".bas",
                message: """
                the swift dialect cannot lower a whole module yet — its object model is proved \
                (see SwiftClassMetadata) but IRGen is not written. Build with the traditional \
                dialect meanwhile: omit --dialect, or pass --dialect traditional
                """
            )
        ])
    }

    public func runtimeLibrary(for target: TargetTriple) -> RuntimeLibrary {
        // Rev 2 adds its own runtime pieces (the root class every BASIC class
        // descends from, boxes, metadata helpers) on top of the same core.
        RuntimeLibrary(name: "BASICRT")
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
