import Foundation

/// The LLVM target a module is lowered for.
///
/// Rev 1 targets the host only; the type exists so the dialect protocol and
/// the runtime lookup are already shaped for `--target wasm32` later.
public struct TargetTriple: Sendable, Hashable, CustomStringConvertible {
    /// The triple as LLVM spells it, e.g. `arm64-apple-macosx16.0`.
    public let rawValue: String

    /// Creates a triple from its LLVM spelling.
    public init(_ rawValue: String) {
        self.rawValue = rawValue
    }

    /// The machine this compiler is running on.
    ///
    /// Pinned to the package's deployment floor rather than read from
    /// `clang -print-target-triple`, so the IR is the same on every machine
    /// that builds it — golden-IR tests depend on that.
    public static let host = TargetTriple("arm64-apple-macosx16.0")

    public var description: String { rawValue }
}
