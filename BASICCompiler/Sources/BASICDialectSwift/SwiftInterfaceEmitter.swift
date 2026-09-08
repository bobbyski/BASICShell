import BASICCompilerKit
import Foundation

/// Generates the `.swiftinterface` for a BASIC program's classes, so Swift
/// code can see them — and inherit from them.
///
/// This is the second half of "BASIC objects are Swift objects". The first
/// half is ``SwiftClassMetadata``, which makes the class real to the *runtime*.
/// This makes it real to the *compiler*: `swiftc` needs a declaration before
/// it will let anyone write `class Ship: Sprite`, and a textual interface is
/// the supported way to hand it one without a `.swiftmodule` built from Swift
/// source that does not exist.
///
/// ```text
///   prog.bas ─► BIR ─┬─► SwiftClassMetadata ─► prog.o    the runtime's view
///                    └─► SwiftInterfaceEmitter ─► prog.swiftinterface
///                                                        the compiler's view
/// ```
///
/// ## Skips are reasoned, never silent
///
/// A BASIC member whose type has no Swift spelling yet is left out *and
/// listed* in ``Interface/skipped``. A binding layer that quietly drops
/// members rots without anyone noticing; this is the same rule R4.8 sets for
/// importing frameworks, applied in the other direction.
public struct SwiftInterfaceEmitter {
    /// What the emitter produced.
    public struct Interface: Sendable {
        /// The `.swiftinterface` text.
        public let text: String
        /// Members left out, each with the reason — never dropped silently.
        public let skipped: [Skip]

        /// One member that could not be projected into Swift.
        public struct Skip: Sendable {
            /// The class it belongs to.
            public let owner: String
            /// The member's name.
            public let member: String
            /// Why it was left out, in one line.
            public let reason: String
        }
    }

    /// The program.
    public let module: BIRModule
    /// The class every BASIC class descends from when it names no base.
    public let rootClass: String
    /// The module that root class lives in, imported by the interface.
    public let rootModule: String

    /// Creates an interface emitter.
    public init(module: BIRModule, rootClass: String = "BASICObject", rootModule: String = "BASICRTSwift") {
        self.module = module
        self.rootClass = rootClass
        self.rootModule = rootModule
    }

    /// Every `CLASS` in the program, in declaration order. `TYPE` records are
    /// value types and are not projected as classes.
    public var classes: [BIRCompositeType] {
        module.types.filter(\.isClass)
    }

    /// Renders the interface.
    ///
    /// - Parameter target: the triple, which must match the one the client is
    ///   compiled for. A mismatch is reported by `swiftc` as "no such module",
    ///   which reads like a missing file and is not one.
    public func render(target: String) -> Interface {
        var skipped: [Interface.Skip] = []
        var lines = [
            "// swift-interface-format-version: 1.0",
            // Without this line the frontend refuses the SDK, complaining that
            // it was "built with (unspecified, file possibly handwritten)".
            "// swift-compiler-version: \(Self.compilerVersion)",
            "// swift-module-flags: -target \(target) -module-name \(module.name)",
            "import \(rootModule)",
            "import Swift",
        ]
        for composite in classes {
            let base = composite.base.flatMap { index in
                module.types.first { $0.index == index }?.displayName
            } ?? "\(rootModule).\(rootClass)"
            lines.append("open class \(composite.displayName) : \(base) {")
            // `override`, because the root class declares `init()` and Swift
            // requires a subclass redeclaring it to say so.
            // `override`, because the root class declares `init()` and Swift
            // requires a subclass redeclaring it to say so.
            lines.append("  override public init()")
            // Declared `final` and in declaration order, so Swift's model of
            // the instance layout is the one basicc emitted.
            for field in composite.fields {
                guard let type = swiftType(field.type) else {
                    skipped.append(.init(
                        owner: composite.displayName, member: field.displayName,
                        reason: "\(field.type.name) fields have no Swift spelling yet"
                    ))
                    continue
                }
                lines.append("  final public var \(swiftIdentifier(field.displayName)): \(type)")
            }
            for method in methods(of: composite) {
                switch signature(of: method, in: composite) {
                case .declared(let text):
                    lines.append("  " + text)
                case .unrepresentable(let reason):
                    skipped.append(.init(owner: composite.displayName, member: method.name, reason: reason))
                }
            }
            lines.append("}")
        }
        return Interface(text: lines.joined(separator: "\n") + "\n", skipped: skipped)
    }

    /// The BIR functions that are methods of a class. BIR names a method
    /// `CLASS.METHOD` and passes the receiver as the first parameter, `ME`.
    public func methods(of composite: BIRCompositeType) -> [BIRFunction] {
        let prefix = composite.name + "."
        return module.functions.filter { $0.name.hasPrefix(prefix) }
    }

    /// One method's Swift declaration, or why it has none.
    public enum SignatureResult: Sendable {
        /// The declaration to put in the interface.
        case declared(String)
        /// Why the method has no Swift face yet.
        case unrepresentable(String)
    }

    /// One method's Swift declaration, or why it has none.
    func signature(of method: BIRFunction, in composite: BIRCompositeType) -> SignatureResult {
        let name = String(method.name.dropFirst(composite.name.count + 1))
        var parameters: [String] = []
        // The first parameter is the receiver, which Swift supplies itself.
        for parameter in method.parameters.dropFirst() {
            guard let type = swiftType(parameter.type) else {
                return .unrepresentable("parameter '\(parameter.name)' is \(parameter.type.name), which has no Swift spelling yet")
            }
            parameters.append("_ \(swiftIdentifier(parameter.name)): \(type)")
        }
        let returns: String
        if method.returnType == .void {
            returns = ""
        } else if let type = swiftType(method.returnType) {
            returns = " -> \(type)"
        } else {
            return .unrepresentable("returns \(method.returnType.name), which has no Swift spelling yet")
        }
        // Declared only if its symbol can actually be spelled. The interface
        // and the object file have to agree: a method declared here but not
        // emitted there is a link error at the far end of the build, blamed
        // on whoever was writing Swift at the time.
        do {
            _ = try SwiftMangling.mangleMethod(
                module: module.name,
                className: composite.displayName,
                method: name,
                returns: method.returnType == .void ? .void : .number,
                parameters: method.parameters.dropFirst().map { _ in .number }
            )
        } catch {
            return .unrepresentable("\(error)")
        }
        return .declared("open func \(swiftIdentifier(name))(\(parameters.joined(separator: ", ")))\(returns)")
    }

    /// A BASIC type as Swift spells it, or nil when it has no spelling yet.
    ///
    /// Numbers are `Double` because that is what BASIC numbers *are* — the
    /// interpreter keeps every one as a `Double`, and projecting them as `Int`
    /// would make Swift's view disagree with the oracle's.
    public func swiftType(_ type: BIRType) -> String? {
        switch type {
        case .number: return "Swift.Double"
        case .string: return "Swift.String"
        case .boolean: return "Swift.Bool"
        case .void: return "Swift.Void"
        case .composite(let name):
            guard let composite = module.types.first(where: { $0.name == name }), composite.isClass else { return nil }
            return composite.displayName
        // Arrays, dictionaries, variants, closures and system classes all
        // need the runtime types R2 introduces; none is projected yet.
        default: return nil
        }
    }

    /// A BASIC name that is safe as a Swift identifier. BASIC is
    /// case-insensitive and has its own keywords; Swift's are different, so a
    /// name that collides is backticked rather than renamed — a renamed
    /// member is one a BASIC programmer cannot find.
    public func swiftIdentifier(_ name: String) -> String {
        let reserved: Set<String> = [
            "class", "func", "var", "let", "init", "deinit", "self", "super",
            "return", "if", "else", "for", "while", "repeat", "switch", "case",
            "default", "break", "continue", "in", "is", "as", "try", "throw",
            "throws", "public", "open", "private", "internal", "static", "where",
        ]
        return reserved.contains(name.lowercased()) ? "`\(name)`" : name
    }
}

extension SwiftInterfaceEmitter {
    /// The compiler version string, as the interface header spells it.
    public static var compilerVersion: String {
        run(["swiftc", "-version"]).split(separator: "\n").first.map(String.init)
            ?? "Apple Swift version 6.3.1"
    }

    /// The triple this toolchain compiles for.
    ///
    /// Asked of `swiftc` rather than assumed: the compiler's own deployment
    /// target and the toolchain's default are different numbers, and a
    /// generated interface that names the wrong one produces a module
    /// `swiftc` reports as missing.
    /// Runs `xcrun` and returns its output, or "" if it could not be run.
    static func run(_ arguments: [String]) -> String {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/xcrun")
        process.arguments = arguments
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice
        guard (try? process.run()) != nil else { return "" }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return String(decoding: data, as: UTF8.self)
    }

    public static var hostTarget: String {
        let data = Data(run(["swiftc", "-print-target-info"]).utf8)
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let target = json["target"] as? [String: Any],
              let triple = target["triple"] as? String
        else { return TargetTriple.host.rawValue }
        return triple
    }
}
