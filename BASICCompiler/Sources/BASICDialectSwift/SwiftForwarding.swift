import Foundation

/// A BASIC class that inherits a framework class, where nothing can be
/// compiled for it (BASIC-45, slice 11d): a program BASICStudio runs.
///
/// Natively basicc writes such a class as Swift and compiles it (R1.5,
/// ``SwiftHostedClasses``). Studio has no swiftc, so the framework map
/// carries, for every `open` class, one Swift subclass compiled in advance —
/// a *forwarding* class:
///
/// ```text
///   final class BASICForward_AUIView: AUIView, BASICForwarding
///     inherits every initializer       NEW Gauge() makes one, and says it is a Gauge
///     override func refresh()          BASIC's REFRESH, if the BASIC class has one;
///                                      AUIView's own otherwise
/// ```
///
/// The BASIC class's own fields live in a runtime record the object carries,
/// and its methods are BASIC's, lowered as usual. Which BASIC body overrides
/// which method is set on each object as it is made, by slot: the position
/// in ``methods(of:in:)``, which the map's generator and the compiler both
/// ask, of the same API.
public enum SwiftForwarding {
    /// The forwarding class a map compiles for a framework class.
    public static func className(for base: String) -> String { "BASICForward_\(base)" }

    /// Whether the map has a forwarding class for `klass`: an `open` class,
    /// which Swift lets a class outside its module subclass, and that BASIC
    /// can make.
    public static func isForwardable(_ klass: SwiftAPI.Class) -> Bool {
        klass.isOpen && !klass.isOpaque && !klass.isActor && !klass.initializers.isEmpty
    }

    /// What crosses between an override and its BASIC body: numbers, truth
    /// values and strings, as R1.5's bridges take them.
    public enum Scalar: Sendable {
        case double, int, cgFloat, bool, string

        public var swiftSpelling: String {
            switch self {
            case .double: return "Double"
            case .int: return "Int"
            case .cgFloat: return "CGFloat"
            case .bool: return "Bool"
            case .string: return "String"
            }
        }
    }

    public static func scalar(_ type: SwiftAPI.ValueType) -> Scalar? {
        switch type {
        case .double: return .double
        case .int: return .int
        case .cgFloat: return .cgFloat
        case .bool: return .bool
        case .string: return .string
        default: return nil
        }
    }

    /// The methods of `klass` a BASIC class may override, in slot order: the
    /// class's own and its bases', the nearest of each name, each `open`, not
    /// declared in an extension (Swift does not let one be overridden), not
    /// awaited or throwing, taking and answering only scalars.
    public static func methods(of klass: SwiftAPI.Class, in api: SwiftAPI) -> [SwiftAPI.Function] {
        var seen = Set<String>()
        var out: [SwiftAPI.Function] = []
        var walk: SwiftAPI.Class? = klass
        while let here = walk {
            for method in here.methods where seen.insert(method.name.uppercased()).inserted {
                guard method.isOverridable, !method.isAsync, !method.isThrowing, !method.isFromExtension,
                      !method.discardsResult, method.passed.count == method.parameters.count,
                      method.parameters.allSatisfy({ scalar($0.type) != nil }),
                      method.returns == .void || scalar(method.returns) != nil
                else { continue }
                out.append(method)
            }
            walk = here.superclassPrecise.flatMap { api.class(precise: $0) }
        }
        return out
    }

    /// The forwarding classes' Swift source, for a map's shim file. Each
    /// override asks the object whether its BASIC class overrides the slot,
    /// and calls BASIC if so (``BASICForwardCall``, in the map's own
    /// sources); otherwise `super`, as if there were no override at all.
    public static func source(for api: SwiftAPI) -> [String] {
        var lines: [String] = []
        for klass in api.classes where isForwardable(klass) {
            lines.append("final class \(className(for: klass.name)): \(klass.name), BASICForwarding {")
            lines.append("    nonisolated let basicForward = BASICForwardState()")
            for (slot, method) in methods(of: klass, in: api).enumerated() {
                let kinds = method.parameters.map { scalar($0.type)! }
                let declared = zip(method.parameters, kinds).enumerated().map { index, pair in
                    "\(pair.0.label ?? "_") a\(index): \(pair.1.swiftSpelling)"
                }
                let forwarded = method.parameters.enumerated().map { index, parameter in
                    (parameter.label.map { "\($0): " } ?? "") + "a\(index)"
                }
                let values = kinds.enumerated().map { index, kind -> String in
                    switch kind {
                    case .double: return ".number(a\(index))"
                    case .int, .cgFloat: return ".number(Double(a\(index)))"
                    case .bool: return ".boolean(a\(index))"
                    case .string: return ".string(a\(index))"
                    }
                }
                let call = "target, self, [\(values.joined(separator: ", "))]"
                let superCall = "super.`\(method.name)`(\(forwarded.joined(separator: ", ")))"
                let result = scalar(method.returns)
                lines.append("    override func `\(method.name)`(\(declared.joined(separator: ", ")))"
                    + (result.map { " -> \($0.swiftSpelling)" } ?? "") + " {")
                switch result {
                case nil:
                    lines.append("        if let target = basicForward.target(\(slot)), BASICForwardCall.void(\(call)) { return }")
                    lines.append("        \(superCall)")
                case .double?:
                    lines.append("        if let target = basicForward.target(\(slot)), let value = BASICForwardCall.number(\(call)) { return value }")
                    lines.append("        return \(superCall)")
                case .int?, .cgFloat?:
                    lines.append("        if let target = basicForward.target(\(slot)), let value = BASICForwardCall.number(\(call)) { return \(result!.swiftSpelling)(value) }")
                    lines.append("        return \(superCall)")
                case .bool?:
                    lines.append("        if let target = basicForward.target(\(slot)), let value = BASICForwardCall.boolean(\(call)) { return value }")
                    lines.append("        return \(superCall)")
                case .string?:
                    lines.append("        if let target = basicForward.target(\(slot)), let value = BASICForwardCall.string(\(call)) { return value }")
                    lines.append("        return \(superCall)")
                }
                lines.append("    }")
            }
            lines.append("}")
            lines.append("")
        }
        return lines
    }
}
