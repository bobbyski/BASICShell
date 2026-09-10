import Foundation

/// Everything a dialect needs to know about one compilation besides the code.
public struct CompileOptions: Sendable {
    /// The target being lowered for.
    public var target: TargetTriple

    /// Optimization level, as clang spells it: `0`…`3`.
    public var optimizationLevel: Int

    /// Whether to emit DWARF debug information (decision D10).
    public var emitDebugInfo: Bool

    /// Emit everything *except* the program's entry point.
    ///
    /// A `.bas` that exists to declare classes for Swift is not a program to
    /// run — it is a library to link — and a `main` in it would collide with
    /// the Swift program's own. `basicc swift-class` sets this; a build never
    /// does.
    public var omitsEntryPoint: Bool = false

    /// Creates compile options; the defaults are a debug build for the host.
    public init(
        target: TargetTriple = .host,
        optimizationLevel: Int = 0,
        emitDebugInfo: Bool = true,
        omitsEntryPoint: Bool = false
    ) {
        self.target = target
        self.optimizationLevel = optimizationLevel
        self.emitDebugInfo = emitDebugInfo
        self.omitsEntryPoint = omitsEntryPoint
    }
}
