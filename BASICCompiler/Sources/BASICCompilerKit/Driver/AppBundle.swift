import Foundation

/// A macOS application bundle around a compiled program.
///
/// A BASIC program that draws — VTG graphics, a TUIKit window — needs a
/// terminal to draw in, so the bundle is a launcher rather than a windowed
/// application: double-clicking it opens the user's terminal on the
/// program. That is what "a distributable graphics program" means for a
/// language whose surface is the terminal.
///
/// ```text
///   MyApp.app/
///     Contents/
///       Info.plist            CFBundleExecutable = MyApp-launch
///       MacOS/
///         MyApp               the compiled program
///         MyApp-launch        opens Terminal on it
/// ```
public enum AppBundle {
    /// Something about the request the bundle cannot honor.
    public struct Failure: Error, CustomStringConvertible {
        public let description: String
    }

    /// Wraps `program` in `<name>.app` beside it, or at `destination`.
    /// Returns the bundle's path.
    @discardableResult
    public static func wrap(program: String, named rawName: String? = nil, at destination: String? = nil) throws -> String {
        let fileManager = FileManager.default
        guard fileManager.isExecutableFile(atPath: program) else {
            throw Failure(description: "\(program) is not a program to wrap")
        }
        let name = rawName ?? ((program as NSString).lastPathComponent as NSString).deletingPathExtension
        guard !name.isEmpty else { throw Failure(description: "a bundle needs a name") }
        let bundle = destination ?? ((program as NSString).deletingLastPathComponent as NSString)
            .appendingPathComponent("\(name).app")
        if fileManager.fileExists(atPath: bundle) {
            try fileManager.removeItem(atPath: bundle)
        }
        let contents = (bundle as NSString).appendingPathComponent("Contents")
        let executables = (contents as NSString).appendingPathComponent("MacOS")
        try fileManager.createDirectory(atPath: executables, withIntermediateDirectories: true)

        let inner = (executables as NSString).appendingPathComponent(name)
        try fileManager.copyItem(atPath: program, toPath: inner)

        let launcher = (executables as NSString).appendingPathComponent("\(name)-launch")
        try launcherScript(name: name).write(toFile: launcher, atomically: true, encoding: .utf8)
        try fileManager.setAttributes([.posixPermissions: 0o755], ofItemAtPath: launcher)

        try infoPlist(name: name).write(
            toFile: (contents as NSString).appendingPathComponent("Info.plist"),
            atomically: true, encoding: .utf8
        )
        return bundle
    }

    /// Opens the user's terminal on the program beside it.
    static func launcherScript(name: String) -> String {
        """
        #!/bin/sh
        # Opens \(name) in a terminal. A BASIC program's screen is a terminal
        # screen — graphics and TUI windows are drawn with escape sequences —
        # so the bundle hands it one rather than opening a window of its own.
        program="$(cd "$(dirname "$0")" && pwd)/\(name)"
        open -a Terminal "$program"

        """
    }

    static func infoPlist(name: String) -> String {
        """
        <?xml version="1.0" encoding="UTF-8"?>
        <!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
        <plist version="1.0">
        <dict>
            <key>CFBundleDevelopmentRegion</key>
            <string>en</string>
            <key>CFBundleExecutable</key>
            <string>\(name)-launch</string>
            <key>CFBundleIdentifier</key>
            <string>org.aibasic.\(name.lowercased())</string>
            <key>CFBundleInfoDictionaryVersion</key>
            <string>6.0</string>
            <key>CFBundleName</key>
            <string>\(name)</string>
            <key>CFBundlePackageType</key>
            <string>APPL</string>
            <key>CFBundleShortVersionString</key>
            <string>1.0</string>
            <key>CFBundleVersion</key>
            <string>1</string>
            <key>LSMinimumSystemVersion</key>
            <string>13.0</string>
        </dict>
        </plist>

        """
    }
}
