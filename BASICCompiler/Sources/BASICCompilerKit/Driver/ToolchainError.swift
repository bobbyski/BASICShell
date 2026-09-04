import Foundation

/// A tool the driver ran did not succeed.
public struct ToolchainError: Error, CustomStringConvertible {
    /// Which step failed: `"clang"`, `"swiftc (runtime)"`, `"swiftc (link)"`.
    public let stage: String

    /// The tool's exit code.
    public let exitCode: Int32

    /// What the tool printed to stderr, verbatim.
    public let stderr: String

    public var description: String {
        "\(stage) failed (exit \(exitCode)):\n\(stderr)"
    }
}
