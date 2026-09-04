import Foundation

/// Everything a dialect needs to know about one compilation besides the code.
public struct CompileOptions: Sendable {
    /// The target being lowered for.
    public var target: TargetTriple

    /// Optimization level, as clang spells it: `0`…`3`.
    public var optimizationLevel: Int

    /// Whether to emit DWARF debug information (decision D10).
    public var emitDebugInfo: Bool

    /// Creates compile options; the defaults are a debug build for the host.
    public init(
        target: TargetTriple = .host,
        optimizationLevel: Int = 0,
        emitDebugInfo: Bool = true
    ) {
        self.target = target
        self.optimizationLevel = optimizationLevel
        self.emitDebugInfo = emitDebugInfo
    }
}
