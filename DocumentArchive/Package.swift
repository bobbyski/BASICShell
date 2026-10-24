// swift-tools-version: 6.1

import PackageDescription

// DocumentArchive — reading documents out of a zip, in process.
//
// Deliberately read-only. It exists because an application that ships a manual
// wants the manual as one file it can put in its bundle, and wants a page out of
// it in microseconds without writing anything to disk.
//
// The ZIP format is ZipIt's (`ZipItZIP`, BASIC-72), a sibling checkout as ProjectKit
// takes it, so `UserDocs.zip` reads the same on macOS, iOS, Linux and Windows.
// Apple's Compression framework, used before, has no Linux or Windows.
let package = Package(
    name: "DocumentArchive",
    platforms: [.macOS(.v15), .iOS(.v17)],
    products: [
        .library(name: "DocumentArchive", targets: ["DocumentArchive"]),
        // Reads a zip of documents and prints a digest: the same on every platform
        // when the zip reads the same (ProjectKit PLAN 10.6).
        .executable(name: "documentarchive-check", targets: ["documentarchive-check"]),
    ],
    dependencies: [
        .package(path: "../../../../AIResearch/ZipIt-ZipItGood/Code/ZipItKit"),
    ],
    targets: [
        .target(name: "DocumentArchive", dependencies: [.product(name: "ZipItZIP", package: "ZipItKit")]),
        .executableTarget(name: "documentarchive-check", dependencies: ["DocumentArchive"]),
        .testTarget(name: "DocumentArchiveTests", dependencies: ["DocumentArchive"])
    ]
)
