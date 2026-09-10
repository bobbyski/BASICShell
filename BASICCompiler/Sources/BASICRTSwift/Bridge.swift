/// The boundary between a compiled BASIC program and an imported Swift
/// framework (ruling R2.0: convert where values cross, not at rest).
///
/// A BASIC string stays the runtime's own object for the whole life of the
/// program; it becomes a `Swift.String` on the way into a framework call and
/// comes back the same way. The cost is O(n) per crossing — the right trade
/// until a profile says otherwise, and the reason `IMPORT` works now rather
/// than after every string in the language has been rewritten.
public enum BASICRTSwiftBridge {
    /// Reads a runtime string pointer as text.
    ///
    /// Installed by `BASICRT` at start-up rather than implemented here:
    /// `BASICRTSwift` must not depend on `BASICRT`, because the compiler
    /// links both into one program and every compiled class names
    /// `BASICRTSwift.BASICObject` — putting that behind the runtime's module
    /// would make the root class depend on the world it is the root of.
    public nonisolated(unsafe) static var readString: (UnsafeMutableRawPointer?) -> String = { _ in
        fatalError("the BASIC string bridge was not installed: basic_rt_start did not run")
    }

    /// Makes an owned (+1) runtime string.
    public nonisolated(unsafe) static var makeString: (String) -> UnsafeMutableRawPointer = { _ in
        fatalError("the BASIC string bridge was not installed: basic_rt_start did not run")
    }

    /// Reports a runtime error the way the interpreter does, and does not
    /// return — the runtime longjmps to whatever `ON ERROR` installed.
    public nonisolated(unsafe) static var fail: (String) -> Never = { message in
        fatalError("the BASIC error bridge was not installed: \(message)")
    }

    /// Installs the hooks. Called by `basic_rt_start`.
    public static func install(
        readString: @escaping (UnsafeMutableRawPointer?) -> String,
        makeString: @escaping (String) -> UnsafeMutableRawPointer,
        fail: @escaping (String) -> Never
    ) {
        Self.readString = readString
        Self.makeString = makeString
        Self.fail = fail
    }
}

/// The `Swift.String` behind a runtime string pointer; null reads as "".
///
/// `@_silgen_name`, not `@_cdecl`: the result is a `Swift.String`, which has
/// no C representation — it comes back in Swift's own two-word form, which is
/// exactly what a framework call takes. Emitted IR calls this by name.
@_silgen_name("basic_rt_swift_string_in")
public func basicRTSwiftStringIn(_ pointer: UnsafeMutableRawPointer?) -> String {
    BASICRTSwiftBridge.readString(pointer)
}

/// A new owned (+1) runtime string holding `text`.
@_silgen_name("basic_rt_swift_string_out")
public func basicRTSwiftStringOut(_ text: String) -> UnsafeMutableRawPointer {
    BASICRTSwiftBridge.makeString(text)
}


/// Turns a thrown Swift error into a BASIC error and does not return (R4.6).
///
/// The whole round trip is: an imported `throws` method is called with the
/// `swifterror` register Swift's ABI requires; if it comes back non-null the
/// emitted thunk hands the error here, and this raises it the way any runtime
/// error is raised — so `ON ERROR` catches a Swift `throw` with no special
/// case anywhere in the language.
///
/// `Error` is a single refcounted pointer in Swift's ABI, which is why this
/// can be reached from emitted IR by name.
@_silgen_name("basic_rt_swift_error_raise")
public func basicRTSwiftErrorRaise(_ error: Error) -> Never {
    // `localizedDescription` would say "The operation couldn't be completed"
    // for a plain enum; interpolation gives the case name, which is what a
    // BASIC programmer needs to see.
    BASICRTSwiftBridge.fail("\(error)")
}
