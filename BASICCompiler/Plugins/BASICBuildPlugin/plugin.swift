import Foundation
import PackagePlugin

/// Compiles a target's BASIC source during an ordinary `swift build`.
///
/// The mechanics, because SwiftPM's constraints shape them (the same ones
/// ActivePascal's APCBuildPlugin lives with): a build-tool plugin cannot hand
/// object files to a target, but a C-family target assembles *generated `.s`
/// sources* like anything else. So this plugin runs `basicc build --emit-asm`
/// over the target's `main.bas` and emits one assembly file; SwiftPM
/// assembles and links it, and the runtime comes in as the BASICRT product
/// dependency.
///
/// Use it from a C executable target:
///
/// ```swift
/// .executableTarget(
///     name: "Hello",
///     dependencies: [.product(name: "BASICRT", package: "BASICCompiler")],
///     exclude: ["main.bas"],          // .bas files are the plugin's, not clang's
///     plugins: [.plugin(name: "BASICBuildPlugin", package: "BASICCompiler")]
/// )
/// ```
///
/// One program per target: `main.bas` is the entry point and may IMPORT the
/// other `.bas` files beside it, which count as inputs so edits rebuild.
@main
struct BASICBuildPlugin: BuildToolPlugin {
    func createBuildCommands(context: PluginContext, target: Target) async throws -> [Command] {
        let sources = basicSources(under: target.directoryURL)
        guard let main = sources.first(where: { $0.lastPathComponent.lowercased() == "main.bas" }) else { return [] }
        let output = context.pluginWorkDirectoryURL.appending(path: "basic-program.s")
        let basicc = try context.tool(named: "basicc")
        return [
            .buildCommand(
                displayName: "Compiling BASIC (\(sources.count) file(s)) in \(target.name)",
                executable: basicc.url,
                arguments: ["build", main.path, "--emit-asm", "-o", output.path],
                inputFiles: sources,
                outputFiles: [output]
            )
        ]
    }

    /// Every `.bas` file under the target directory, sorted for stable builds.
    private func basicSources(under directory: URL) -> [URL] {
        guard let enumerator = FileManager.default.enumerator(at: directory, includingPropertiesForKeys: nil) else { return [] }
        var found: [URL] = []
        for case let url as URL in enumerator where url.pathExtension.lowercased() == "bas" {
            found.append(url)
        }
        return found.sorted { $0.path < $1.path }
    }
}
