import BASICRecipes
import Foundation

/// `basicc new` — starter projects.
///
/// The starters are the BASIC recipes every tool shares (BASICRecipes,
/// BASIC-24), so a project born at the terminal and one born in a wizard
/// are the same project:
///
/// ```text
///   MyApp.basproj/
///     project.json      names the program: "entry": "src/main.bas"
///     Makefile          build · run · clean (BASICC ?= basicc)
///     .gitignore        Build/
///     README.md         where basicc comes from
///     src/main.bas      the program
/// ```
public enum ProjectScaffold {
    /// The starters `basicc new --kind` knows, by short name: `console`,
    /// `structured`, `game`, `tui`, `activeui`, …
    public static var kinds: [String] {
        BASICRecipes.builtIn.map(BASICRecipes.shortName)
    }

    /// One line for `basicc new --help`.
    public static func summary(of kind: String) -> String? {
        BASICRecipes.builtIn(named: kind)?.definition.summary
    }

    /// Something about the request the scaffold cannot honor.
    public struct Failure: Error, CustomStringConvertible {
        public let description: String
    }

    /// Creates the project `name` from the starter `kind` in `destination`;
    /// returns its root directory, `<destination>/<name>.basproj`.
    @discardableResult
    public static func generate(named name: String, into destination: String, kind: String = "console") throws -> String {
        guard let recipe = BASICRecipes.builtIn(named: kind) else {
            throw Failure(description: "unknown kind '\(kind)' — one of: \(kinds.joined(separator: ", "))")
        }
        do {
            return try recipe.create(named: name, in: URL(fileURLWithPath: destination, isDirectory: true)).path
        } catch let failure as BASICRecipe.Failure {
            throw Failure(description: failure.description)
        }
    }
}
