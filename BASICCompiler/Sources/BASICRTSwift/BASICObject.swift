/// The root of the BASIC world in the Swift dialect.
///
/// Every BASIC `CLASS` compiled with `--dialect swift` descends from this,
/// directly or through its own bases. It is a plain Swift `open class` and
/// deliberately empty: it exists so that a BASIC class always has a real
/// Swift class above it, which is what makes the metadata `basicc` emits a
/// *sub*class rather than a root — and emitting a root class's metadata is a
/// materially harder job than emitting a subclass's.
///
/// The same trick ActivePascalRT uses for `TObject`, and for the same reason.
///
/// A BASIC program never names this type. It appears in the generated
/// `.swiftinterface` as the superclass of any class that declares no
/// `INHERITS`, so Swift code can hold and subclass BASIC objects.
open class BASICObject {
    /// Creates the object. BASIC's `NEW` lowers to an allocation with the
    /// class's own metadata followed by its constructor; this is what that
    /// constructor chains to.
    public init() {}
}

/// A BASIC runtime error, as Swift receives it (R4.6). Here, beside
/// `BASICObject`, because this is the file a Swift client compiles against. `number` is what the
/// program would have read as `ERR`; the text is what the runtime would
/// have printed had nothing caught it.
public struct BASICRuntimeError: Error, CustomStringConvertible, Sendable {
    public let number: Int
    public let message: String
    public var description: String { message }
}
