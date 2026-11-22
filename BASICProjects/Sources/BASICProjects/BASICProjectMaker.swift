//
//  BASICProjectMaker.swift
//  BASICProjects
//
//  Making a project from a recipe, as a folder or a zip.
//

import Foundation
import BASICRecipes

extension BASICProjects {
    /// Makes the project `name` in `folder` from `recipe`, in `form`: by default a zip,
    /// as new BASIC projects are (ProjectKit PLAN D7); a folder when asked, for git.
    ///
    /// The recipe writes its files as it always has; a zip is those files packed into
    /// `Name.basproj`, with nothing left behind.
    ///
    /// - Returns: The new project: the zip, or the folder.
    /// - Throws: The recipe's `Failure` for a bad name, or when something is already
    ///   there; ProjectKit's error when the zip can't be written.
    @discardableResult
    public static func create(from recipe: BASICRecipe, named name: String, in folder: URL,
                              form: ProjectForm = ProjectType.basicProject.defaultForm,
                              options: [String: String] = [:]) throws -> URL {
        if form == .folder {
            return try recipe.create(named: name, in: folder, options: options)
        }
        let staging = FileManager.default.temporaryDirectory
            .appendingPathComponent("basic-new-project-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: staging, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: staging) }
        let made = try recipe.create(named: name, in: staging, options: options)
        let destination = folder.appendingPathComponent(made.lastPathComponent)
        guard !FileManager.default.fileExists(atPath: destination.path) else {
            throw BASICRecipe.Failure("\(destination.lastPathComponent) is already there.")
        }
        let project = try Project.open(at: made, as: types, options: ProjectOptions(saving: .manual, readOnly: true))
        defer { try? project.close() }
        try project.export(as: .zip, to: destination)
        return destination
    }
}
