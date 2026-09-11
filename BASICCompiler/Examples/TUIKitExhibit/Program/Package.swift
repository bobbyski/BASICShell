// swift-tools-version: 5.9
// The TUIKit exhibit's own manifest. It names TUIKit as a dependency, and its
// presence is what selects the Swift dialect (D11); basicc asks SwiftPM where
// TUIKit is rather than knowing itself.
import PackageDescription

let package = Package(
    name: "TUIKitExhibit",
    platforms: [.macOS(.v14)],
    dependencies: [.package(path: "../../../../../../frameworks/UILess/Code/TUIKit")],
    targets: []
)
