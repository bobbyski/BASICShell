// swift-tools-version: 6.0

import PackageDescription

let package = Package(
    name: "BASICShell",
    platforms: [.macOS(.v14)],
    dependencies: [
        .package(path: "../BASICCore"),
        .package(url: "https://github.com/migueldeicaza/TermKit", branch: "main")
    ],
    targets: [
        .executableTarget(
            name: "BASICShell",
            dependencies: [
                "BASICCore",
            ]
        ),
        .executableTarget(
            name: "BASICEdit",
            dependencies: [
                "TermKit"
            ]
        )
    ]
)
