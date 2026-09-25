//
//  BASICPseudoClassRoster.swift
//  BASICSyntax
//
//  One registration point for a pseudo-class family (D0.5).
//

import Foundation

/// One host-implemented class: what it is called, and how it is made.
///
/// Pseudo classes have historically had to be spelled out in several places —
/// the interpreter's construction switch, its method dispatch, the keyword
/// roster, `basic_rt_system_new`, the compiler's member table — and the
/// codebase carries a scar from exactly that. `BASICRuntime.swift` says it:
///
/// > *"Every TUI pseudo class, by rule rather than by list. This was a
/// > spelled-out roster of seventy names, which is a fourth place to remember
/// > when one is added — and the one that was forgotten: a class missing from
/// > here constructs, then reports 'has no method' for everything, which reads
/// > like a broken binding rather than a missing registration."*
///
/// That failure is worse for a database than it was for a TUI, because it looks
/// like a driver bug: the program builds, connects, and then reports that a
/// method does not exist.
public struct BASICPseudoClass: Equatable, Sendable {
    /// The name as the language spells it, and as `PRINT` shows it.
    public let displayName: String
    /// Its uppercased form, which is how every lookup is keyed.
    public var normalizedName: String { displayName.uppercased() }
    /// How many arguments the constructor takes, or nil when the class is
    /// produced rather than constructed.
    public let constructorArity: Int?
    /// What the constructor wants, for the message when the count is wrong.
    public let constructorDescription: String

    public init(displayName: String, constructorArity: Int?, constructorDescription: String) {
        self.displayName = displayName
        self.constructorArity = constructorArity
        self.constructorDescription = constructorDescription
    }

    /// Whether a program can write `Name(…)` for it.
    public var isConstructible: Bool { constructorArity != nil }
}

/// The database family (D1–D7), registered once.
///
/// Every site that needs to know these names reads them from here: the keyword
/// roster, the interpreter's construction and dispatch, and the compiler's
/// member table. `BASICRT` deliberately reads nothing — it asks the host whether
/// a name is one of these (`basic_rt_host_db_handles`), so the compiled runtime
/// is not a place a name can be forgotten.
public enum BASICDatabaseClasses {

    public static let all: [BASICPseudoClass] = [
        BASICPseudoClass(
            displayName: "SqlDatabase", constructorArity: 1,
            constructorDescription: "SqlDatabase wants a connection string"
        ),
        BASICPseudoClass(
            displayName: "DocumentDatabase", constructorArity: 1,
            constructorDescription: "DocumentDatabase wants a connection string"
        ),
        BASICPseudoClass(
            displayName: "DataStore", constructorArity: 1,
            constructorDescription: "DataStore wants a database"
        ),
        // Produced, never constructed: a cursor comes from `SqlDatabase.Query`.
        // Listed anyway, because its *methods* have to type and its name has to
        // be a keyword — being absent from the roster is how a produced class
        // ends up reporting "has no method" for everything.
        BASICPseudoClass(
            displayName: "Recordset", constructorArity: nil,
            constructorDescription: "A Recordset comes from SqlDatabase.Query, not from NEW"
        ),
    ]

    /// Every name, uppercased.
    public static let names: Set<String> = Set(all.map(\.normalizedName))

    /// The family member a name refers to, case-insensitively.
    public static func named(_ name: String) -> BASICPseudoClass? {
        let wanted = name.uppercased()
        return all.first { $0.normalizedName == wanted }
    }

    /// Whether a name is one of these at all.
    public static func handles(_ name: String) -> Bool {
        names.contains(name.uppercased())
    }
}
