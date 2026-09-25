// swift-tools-version: 6.0

import PackageDescription

let package = Package(
    name: "BASICCore",
    // macOS 16 is TUIKit's floor, inherited when BASICCore took the dependency
    // (TUIKIT_PLAN.md §5). Free today: BASICShell and BASICStudio are both
    // already .macOS("16.0"). It does close the door on a macOS 14 consumer.
    platforms: [.macOS("16.0")],
    products: [
        .library(name: "BASICCore", targets: ["BASICCore"]),
        // MongoDB, as its own product so a host opts in (DB11, D8). Linking
        // it is what makes `mongodb://` a connection string this process
        // recognizes; without it, a program naming one is told so by name.
        .library(name: "BASICMongo", targets: ["BASICMongo"]),
        // The shared front end: lexer, parser, AST, types, keywords,
        // diagnostics. The interpreter and basicc both consume it, so the
        // language stays one language (BASIC_COMPILER.md, decision D2).
        .library(name: "BASICSyntax", targets: ["BASICSyntax"]),
        // The linter: rules, profiles, and metrics over the same parser, so
        // a program lints exactly as it parses. Knows nothing about
        // CodeWatch — CodeWatch gets an adapter, not a copy.
        .library(name: "BASICLint", targets: ["BASICLint"]),
        // BASIC in CodeWatch: the front end, so CodeWatch's own rules run on
        // BASIC without a second parser existing anywhere.
        .library(name: "BASICLintCodeWatch", targets: ["BASICLintCodeWatch"]),
    ],
    dependencies: [
        // RichSwift renders rich *content* — markdown, tables, panels — and is
        // what the Rich* pseudo classes are made of. Chosen as the first piece
        // of TUIKIT_PLAN.md because it costs BASICCore nothing: RichSwift has
        // no dependencies of its own and declares no platform floor, so it adds
        // neither swift-syntax nor a macOS bump. TUIKit, which does both, comes
        // later and with its own measurement.
        .package(path: "../../../frameworks/RichSwift"),
        // The interactive layer. Unlike RichSwift this is not free: TUIKit's
        // @Bound macro pulls in swift-syntax, which SwiftPM rebuilds for the
        // release configuration. Measured before and after — see the commit.
        .package(path: "../../../frameworks/UILess/Code/TUIKit"),
        // The gallery's sibling pages. Kanban and node-graph views live in
        // their own packages because they depend on TUIKit rather than being
        // part of it — which is also why the Swift gallery cannot live inside
        // TUIKit either.
        .package(path: "../../../frameworks/UILess/Code/TUIBoards"),
        .package(path: "../../../frameworks/UILess/Code/TUIDiagram"),
        // CodeWatch's rule engine, for the BASIC front end. The dependency
        // points this way on purpose: CodeWatchLint's core is Foundation
        // only and is consumed by hosts that bring their own parser, which
        // is exactly what BASIC is.
        .package(path: "../../../../AIResearch/CodeWatch/Code/CodeWatchLint"),
        // MongoDB (DB13). The official driver was archived in 2023 and wraps
        // `libmongoc`, which does not travel to Windows the way pure Swift and
        // NIO do; MongoKitten is maintained, MIT, and does.
        //
        // The only *remote* dependency this package has, and it is deliberately
        // not a dependency of `BASICCore`: it belongs to the `BASICMongo`
        // target alone, which a host links only if it wants Mongo. It brings
        // thirteen packages with it, and BASICCore is linked by everything.
        .package(url: "https://github.com/orlandos-nl/MongoKitten.git", from: "7.16.3")
    ],
    targets: [
        .target(name: "BASICSyntax"),
        .target(name: "BASICLint", dependencies: ["BASICSyntax"]),
        .target(
            name: "BASICLintCodeWatch",
            dependencies: ["BASICLint", .product(name: "CodeWatchLint", package: "CodeWatchLint")]
        ),
        .target(
            name: "BASICCore",
            dependencies: [
                "BASICSyntax",
                .product(name: "RichSwift", package: "RichSwift"),
                .product(name: "TUIKit", package: "TUIKit"),
                .product(name: "TUIBoards", package: "TUIBoards"),
                .product(name: "TUIDiagram", package: "TUIDiagram"),
            ]
        ),
        // The MongoDB driver (D8). Not in `BASICCore`'s own dependencies --
        // see the manifest note above.
        .target(
            name: "BASICMongo",
            dependencies: ["BASICCore", .product(name: "MongoKitten", package: "MongoKitten")]
        ),
        .testTarget(name: "BASICCoreTests", dependencies: ["BASICCore"]),
        .testTarget(name: "BASICMongoTests", dependencies: ["BASICMongo"]),
        .testTarget(name: "BASICLintTests", dependencies: ["BASICLint", "BASICLintCodeWatch"], resources: [.copy("Fixtures")])
    ]
)
