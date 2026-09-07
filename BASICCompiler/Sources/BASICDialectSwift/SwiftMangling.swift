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
