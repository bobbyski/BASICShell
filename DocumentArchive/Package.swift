// swift-tools-version: 6.1

import PackageDescription

// DocumentArchive — reading documents out of a zip, in process.
//
// Deliberately dependency-free and deliberately read-only. It exists because
// an application that ships a manual wants the manual as one file it can put
// in its bundle, and wants a page out of it in microseconds without writing
// anything to disk. Unpacking to a temporary directory and shelling out to
// /usr/bin/unzip — which is what the compiler does for `.basproj` containers,
// where it is the right answer — is neither of those things.
let package = Package(
    name: "DocumentArchive",
    platforms: [.macOS(.v13)],
    products: [
        .library(name: "DocumentArchive", targets: ["DocumentArchive"])
    ],
    targets: [
        .target(name: "DocumentArchive"),
        .testTarget(name: "DocumentArchiveTests", dependencies: ["DocumentArchive"])
    ]
)
