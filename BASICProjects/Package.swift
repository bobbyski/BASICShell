// swift-tools-version: 6.0

import PackageDescription

// BASIC's projects over ProjectKit (BASIC-72; ProjectKit PLAN, Phase 10): a project
// is a folder `Game.basproj/` or a zip with the same name, and every tool reads,
// recognizes and makes both the same way.
//
//   BASICProjects     BASIC's project types (`.basproj`, `.baslib`), recognizing either
//                     form, the entry point through any project, and making a project
//                     from a recipe in either form (zip by default)
//
// It sits above BASICRecipes, which stays Foundation-only for the IDEs that take it,
// and above ProjectKit, a sibling checkout (as ActiveUI and TUIKit are). basicc,
// BASICShell and BASICStudio depend on it.
let package = Package(
    name: "BASICProjects",
    platforms: [.macOS(.v15), .iOS(.v17)],
    products: [
        .library(name: "BASICProjects", targets: ["BASICProjects"]),
    ],
    dependencies: [
        .package(path: "../BASICRecipes"),
        .package(path: "../../../../AIResearch/Frameworks/ProjectKit/Code/ProjectKit"),
    ],
    targets: [
        .target(
            name: "BASICProjects",
            dependencies: [
                .product(name: "BASICRecipes", package: "BASICRecipes"),
                .product(name: "ProjectKit", package: "ProjectKit"),
            ]),
        .testTarget(name: "BASICProjectsTests", dependencies: ["BASICProjects"]),
    ]
)
