//
//  BASICRecipes.swift
//  BASICRecipes
//
//  The recipes a tool offers: the built-in ones, and folders of the user's.
//

import Foundation

/// Every recipe a tool offers when it makes a BASIC project.
///
/// The built-in ones come from `Recipes/` in this package, compiled in (see
/// `BASICRecipeCatalog`), so no tool has a resource bundle to find. A user's
/// own are folders like those, read when asked for.
public enum BASICRecipes {
    /// The recipes every tool ships, in the order a wizard lists them.
    public static var builtIn: [BASICRecipe] {
        BASICRecipeCatalog.recipes
    }

    /// The built-in recipes, then the user's from each of `folders`. A user's
    /// recipe with a built-in one's identifier is left out.
    public static func all(userFolders folders: [URL] = []) -> [BASICRecipe] {
        var recipes = builtIn
        var taken = Set(recipes.map(\.id))
        for folder in folders {
            for recipe in (try? load(folder: folder)) ?? [] where !taken.contains(recipe.id) {
                recipes.append(recipe)
                taken.insert(recipe.id)
            }
        }
        return recipes
    }

    /// The built-in recipe `name` names: `basic.game`, or just `game`.
    public static func builtIn(named name: String) -> BASICRecipe? {
        let wanted = name.lowercased()
        return builtIn.first { $0.id.lowercased() == wanted || $0.id.lowercased() == "basic." + wanted }
    }

    /// The short name `basicc new --kind` takes: `game` for `basic.game`.
    public static func shortName(of recipe: BASICRecipe) -> String {
        let id = recipe.id
        return id.hasPrefix("basic.") ? String(id.dropFirst("basic.".count)) : id
    }

    // MARK: - Reading recipe folders

    /// The folder in a folder of recipes whose files every recipe in it
    /// gets, unless a recipe has a file at the same path itself.
    public static let sharedFolderName = "_shared"

    /// The recipes in `folder`: each folder in it with a `recipe.json`, in
    /// name order, given the files in `_shared` as well.
    public static func load(folder: URL) throws -> [BASICRecipe] {
        let fileManager = FileManager.default
        let entries = try fileManager.contentsOfDirectory(at: folder, includingPropertiesForKeys: [.isDirectoryKey])
            .filter { (try? $0.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true }
            .sorted { $0.lastPathComponent < $1.lastPathComponent }
        let shared = entries.first { $0.lastPathComponent == sharedFolderName }.map(files(in:)) ?? []
        return try entries
            .filter { fileManager.fileExists(atPath: $0.appendingPathComponent("recipe.json").path) }
            .map { try loadRecipe(folder: $0, shared: shared) }
    }

    /// One recipe folder: its `recipe.json`, and every other file in it.
    public static func loadRecipe(folder: URL, shared: [BASICRecipe.File] = []) throws -> BASICRecipe {
        let json = try String(contentsOf: folder.appendingPathComponent("recipe.json"), encoding: .utf8)
        var files = Self.files(in: folder).filter { $0.path != "recipe.json" }
        let own = Set(files.map(\.path))
        files += shared.filter { !own.contains($0.path) }
        do {
            return try BASICRecipe(json: json, files: files)
        } catch {
            throw BASICRecipe.Failure("\(folder.lastPathComponent)/recipe.json: \(error)")
        }
    }

    /// Every text file under `folder`, by its path inside it. Dotfiles count
    /// (`.gitignore`); `.DS_Store` and anything that is not UTF-8 do not.
    static func files(in folder: URL) -> [BASICRecipe.File] {
        guard let walker = FileManager.default.enumerator(at: folder, includingPropertiesForKeys: [.isRegularFileKey]) else {
            return []
        }
        let root = folder.standardizedFileURL.resolvingSymlinksInPath().path + "/"
        var files: [BASICRecipe.File] = []
        for case let url as URL in walker {
            guard (try? url.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true,
                  url.lastPathComponent != ".DS_Store",
                  let text = try? String(contentsOf: url, encoding: .utf8) else { continue }
            let path = url.standardizedFileURL.resolvingSymlinksInPath().path
            guard path.hasPrefix(root) else { continue }
            files.append(BASICRecipe.File(path: String(path.dropFirst(root.count)), contents: text))
        }
        return files.sorted { $0.path < $1.path }
    }
}
