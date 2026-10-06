// swift-tools-version: 6.0

import PackageDescription

// The recipes BASIC projects start from (BASIC-24), in one place for every
// tool that makes them: BASICStudio's New Project wizard, `basicc new`,
// OmniClide and Freebird Studio.
//
// Foundation only, on purpose: the IDEs take this package without taking
// BASICCore's dependencies (TUIKit, CodeWatch, MongoKitten) with it.
//
//   Recipes/<recipe>/recipe.json + files    the recipes, as edited
//   Sources/BASICRecipes                     the model, the loader, creating
//                                            a project, and the catalog
//                                            generated from Recipes/
//   Sources/basic-recipe-catalog             writes that catalog:
//                                            swift run basic-recipe-catalog
let package = Package(
    name: "BASICRecipes",
    platforms: [.macOS(.v14), .iOS(.v17)],
    products: [
        .library(name: "BASICRecipes", targets: ["BASICRecipes"]),
    ],
    targets: [
        .target(name: "BASICRecipes"),
        .executableTarget(name: "basic-recipe-catalog", dependencies: ["BASICRecipes"]),
        // `Recipes` in the test target is a link to the package's Recipes
        // folder, so the tests read the recipes as edited and can tell when
        // the generated catalog no longer matches them.
        .testTarget(name: "BASICRecipesTests", dependencies: ["BASICRecipes"], resources: [.copy("Recipes")]),
    ]
)
