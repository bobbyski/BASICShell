import Foundation

/// Swift symbol names, as the Swift runtime and `swiftc` spell them.
///
/// Rev 2's classes are real Swift classes, so every symbol they publish has to
/// match what `swiftc` would emit for the same declaration — byte for byte. A
/// near-miss is not a near-miss: a Swift subclass of a BASIC class fails to
/// link, and `type(of:)` prints the wrong name.
///
/// ## The part that is not just length-prefixing
///
/// Swift compresses *words* that repeat within a mangling. Measured against
/// the 6.3.1 toolchain, for classes in a module named `Roids`:
///
/// | Declaration          | Symbol                       |
/// |----------------------|------------------------------|
/// | `Sprite`             | `$s5Roids6SpriteC`           |
/// | `RoidsSprite`        | `$s5Roids0A6SpriteC`         |
/// | `VectorSpriteVector` | `$s5Roids012VectorSpriteB0C` |
///
/// Only the first is plain. ``mangleClass(module:name:)`` emits the plain form
/// and *refuses* the rest rather than emitting a name that would silently fail
/// to link — see ``NeedsWordSubstitution``. Closing that gap is a tracked Rev 2
/// slice with three candidate answers, in preference order:
///
/// 1. Implement Swift's word-substitution algorithm from `Mangling.rst`.
/// 2. Read the canonical names back out of the `.swiftinterface` Rev 2 already
///    has to generate, letting `swiftc` be the authority.
/// 3. Keep the refusal and rename the class.
public enum SwiftMangling {
    /// A name whose mangling needs word substitution, which is not implemented.
    public struct NeedsWordSubstitution: Error, CustomStringConvertible {
        /// The module the class is in.
        public let module: String
        /// The class name that would need substitution.
        public let name: String
        /// The repeated word that triggers it.
        public let word: String

        public var description: String {
            "CLASS \(name) in module \(module) cannot be named as a Swift class yet: "
            + "'\(word)' repeats, and Swift's mangler compresses repeated words in a form "
            + "basicc does not emit yet. Rename the class so no word repeats between it "
            + "and the module name."
        }
    }

    /// The mangled name of a BASIC class compiled as a Swift class:
    /// `$s<len><module><len><name>C`.
    public static func mangleClass(module: String, name: String) throws -> String {
        if let repeated = repeatedWord(module: module, name: name) {
            throw NeedsWordSubstitution(module: module, name: name, word: repeated)
        }
        return "$s\(module.utf8.count)\(module)\(name.utf8.count)\(name)C"
    }

    /// The symbol for a class's type metadata (the address point).
    public static func typeMetadata(module: String, name: String) throws -> String {
        try mangleClass(module: module, name: name) + "N"
    }

    /// The symbol for a class's nominal type descriptor.
    public static func nominalTypeDescriptor(module: String, name: String) throws -> String {
        try mangleClass(module: module, name: name) + "Mn"
    }

    /// The first word that repeats between the module name and the class name,
    /// or within the class name — the condition under which Swift substitutes.
    ///
    /// Words are the capitalised segments Swift's mangler splits on, and only
    /// segments of two characters or more take part.
    static func repeatedWord(module: String, name: String) -> String? {
        var seen = Set(words(in: module))
        for word in words(in: name) {
            if seen.contains(word) { return word }
            seen.insert(word)
        }
        return nil
    }

    /// Splits an identifier the way Swift's mangler does: at each transition
    /// into an uppercase letter.
    static func words(in identifier: String) -> [String] {
        var words: [String] = []
        var current = ""
        for character in identifier {
            if character.isUppercase, !current.isEmpty {
                if current.count >= 2 { words.append(current) }
                current = ""
            }
            current.append(character)
        }
        if current.count >= 2 { words.append(current) }
        return words
    }
}

extension SwiftMangling {
    /// The types a method signature can name so far, and their mangling.
    ///
    /// BASIC numbers are `Double` because that is what the interpreter keeps
    /// them as; projecting them as `Int` would make Swift's view of a BASIC
    /// object disagree with the oracle's.
    public enum SignatureType: String, Sendable, Equatable {
        /// `Swift.Double` — a BASIC number.
        case number = "Sd"
        /// `Swift.Void`.
        case void = "y"
    }

    /// A method's symbol.
    ///
    /// ## Only shapes that have been checked against the toolchain
    ///
    /// Swift's mangler substitutes repeated *types* as well as repeated
    /// words, so a signature's encoding is not a simple concatenation.
    /// Measured on 6.3.1, for methods of a class:
    ///
    /// | Swift declaration | Mangled | Emitted here |
    /// |---|---|---|
    /// | `func area() -> Double` | `4areaSdyF` | ✅ |
    /// | `func setX(_: Double)` | `4setXyySdF` | ✅ |
    /// | `func scaled(_: Double) -> Double` | `6scaledyS2dF` — `Sd` twice, compressed | ❌ refused |
    /// | `func setSize(_: Double, _: Double)` | `7setSizeyySd_SdtF` — a tuple | ❌ refused |
    ///
    /// The last two are refused rather than approximated. A symbol that is
    /// nearly right is a link error at best and the wrong function at worst,
    /// and neither is worth guessing for.
    public static func mangleMethod(
        module: String,
        className: String,
        method: String,
        returns: SignatureType,
        parameters: [SignatureType] = []
    ) throws -> String {
        if let repeated = repeatedWord(module: module, name: className + method) {
            throw NeedsWordSubstitution(module: module, name: "\(className).\(method)", word: repeated)
        }
        let owner = try mangleClass(module: module, name: className)
        let encoded: String
        switch (returns, parameters.count) {
        case (.number, 0):
            encoded = "Sdy"
        case (.void, 1) where parameters[0] == .number:
            encoded = "yySd"
        default:
            throw UnverifiedSignature(
                className: className,
                method: method,
                signature: "\(parameters.count) parameter(s) returning \(returns == .void ? "nothing" : "a number")"
            )
        }
        return "\(owner)\(method.utf8.count)\(method)\(encoded)F"
    }

    /// A signature whose mangling has not been checked against the toolchain.
    public struct UnverifiedSignature: Error, CustomStringConvertible {
        /// The class the method belongs to.
        public let className: String
        /// The method's name.
        public let method: String
        /// The shape that is not spelled yet.
        public let signature: String

        public var description: String {
            "\(className).\(method) takes \(signature), and that signature's Swift symbol has not been "
            + "verified against the toolchain — Swift compresses repeated types in a form basicc does not "
            + "emit yet. Methods that take nothing and return a number, or take one number and return "
            + "nothing, are supported."
        }
    }

    /// The symbol of a class's no-argument initializer.
    ///
    /// Swift emits two halves. The *allocating* half (`C`) is what a caller
    /// invokes: it allocates with the dynamic type it is handed, then chains
    /// to the *initializing* half (`c`), which sets the fields up. A subclass
    /// written in Swift calls the initializing half through `super.init()`,
    /// so both have to exist as real symbols.
    public static func mangleInitializer(
        module: String,
        className: String,
        allocating: Bool
    ) throws -> String {
        try mangleClass(module: module, name: className) + "ACycf" + (allocating ? "C" : "c")
    }

    /// The symbol of a class's destructor: the deallocating half (`fD`), or
    /// the destroying half (`fd`) that releases what the object owns.
    public static func mangleDestructor(
        module: String,
        className: String,
        deallocating: Bool
    ) throws -> String {
        try mangleClass(module: module, name: className) + "f" + (deallocating ? "D" : "d")
    }
}
