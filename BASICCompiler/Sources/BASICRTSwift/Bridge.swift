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

    /// How many elements the BASIC array in a boxed value has.
    ///
    /// A `[T]` crosses as a BASIC array carried in a VARIANT (R4.7), which is
    /// the shape BASIC already has for an array a function hands back — so
    /// `LEN(v)` and `v(i)` walk one with nothing new in the language.
    public nonisolated(unsafe) static var arrayCount: (UnsafeMutableRawPointer?) -> Int = { _ in
        fatalError("the BASIC array bridge was not installed: basic_rt_start did not run")
    }

    /// One element, read as the kind the imported signature says it is. The
    /// element type is known at compile time, so there is no dynamic case to
    /// get wrong here — a `[String]` parameter only ever asks for strings.
    public nonisolated(unsafe) static var arrayNumber: (UnsafeMutableRawPointer?, Int) -> Double = { _, _ in 0 }
    public nonisolated(unsafe) static var arrayBoolean: (UnsafeMutableRawPointer?, Int) -> Bool = { _, _ in false }
    public nonisolated(unsafe) static var arrayString: (UnsafeMutableRawPointer?, Int) -> String = { _, _ in "" }

    /// A new owned (+1) boxed value holding a BASIC array of these elements.
    ///
    /// Whole-array rather than allocate-then-fill: the shim has the Swift
    /// array in hand, and one call cannot leave a half-built array behind if
    /// something in the middle raises.
    public nonisolated(unsafe) static var makeNumberArray: ([Double]) -> UnsafeMutableRawPointer = { _ in
        fatalError("the BASIC array bridge was not installed: basic_rt_start did not run")
    }
    public nonisolated(unsafe) static var makeBooleanArray: ([Bool]) -> UnsafeMutableRawPointer = { _ in
        fatalError("the BASIC array bridge was not installed: basic_rt_start did not run")
    }
    public nonisolated(unsafe) static var makeStringArray: ([String]) -> UnsafeMutableRawPointer = { _ in
        fatalError("the BASIC array bridge was not installed: basic_rt_start did not run")
    }

    /// Installs the hooks. Called by `basic_rt_start`.
    public static func install(
        readString: @escaping (UnsafeMutableRawPointer?) -> String,
        makeString: @escaping (String) -> UnsafeMutableRawPointer,
        fail: @escaping (String) -> Never,
        arrayCount: @escaping (UnsafeMutableRawPointer?) -> Int,
        arrayNumber: @escaping (UnsafeMutableRawPointer?, Int) -> Double,
        arrayBoolean: @escaping (UnsafeMutableRawPointer?, Int) -> Bool,
        arrayString: @escaping (UnsafeMutableRawPointer?, Int) -> String,
        makeNumberArray: @escaping ([Double]) -> UnsafeMutableRawPointer,
        makeBooleanArray: @escaping ([Bool]) -> UnsafeMutableRawPointer,
        makeStringArray: @escaping ([String]) -> UnsafeMutableRawPointer
    ) {
        Self.readString = readString
        Self.makeString = makeString
        Self.fail = fail
        Self.arrayCount = arrayCount
        Self.arrayNumber = arrayNumber
        Self.arrayBoolean = arrayBoolean
        Self.arrayString = arrayString
        Self.makeNumberArray = makeNumberArray
        Self.makeBooleanArray = makeBooleanArray
        Self.makeStringArray = makeStringArray
    }
}

/// The array side of the boundary (R4.7).
///
/// `@_silgen_name` for the same reason the string entry points use it: these
/// deal in `Swift.String` and `Swift.Array`, which have no C representation.
/// A generated shim declares them by name and never sees the runtime's
/// module, so a shim compiled against a framework needs nothing on its
/// search path but the framework.
@_silgen_name("basic_rt_swift_array_count")
public func basicRTSwiftArrayCount(_ pointer: UnsafeMutableRawPointer?) -> Int {
    BASICRTSwiftBridge.arrayCount(pointer)
}

@_silgen_name("basic_rt_swift_array_number")
public func basicRTSwiftArrayNumber(_ pointer: UnsafeMutableRawPointer?, _ index: Int) -> Double {
    BASICRTSwiftBridge.arrayNumber(pointer, index)
}

@_silgen_name("basic_rt_swift_array_boolean")
public func basicRTSwiftArrayBoolean(_ pointer: UnsafeMutableRawPointer?, _ index: Int) -> Bool {
    BASICRTSwiftBridge.arrayBoolean(pointer, index)
}

@_silgen_name("basic_rt_swift_array_string")
public func basicRTSwiftArrayString(_ pointer: UnsafeMutableRawPointer?, _ index: Int) -> String {
    BASICRTSwiftBridge.arrayString(pointer, index)
}

@_silgen_name("basic_rt_swift_array_out_numbers")
public func basicRTSwiftArrayOutNumbers(_ values: [Double]) -> UnsafeMutableRawPointer {
    BASICRTSwiftBridge.makeNumberArray(values)
}

@_silgen_name("basic_rt_swift_array_out_booleans")
public func basicRTSwiftArrayOutBooleans(_ values: [Bool]) -> UnsafeMutableRawPointer {
    BASICRTSwiftBridge.makeBooleanArray(values)
}

@_silgen_name("basic_rt_swift_array_out_strings")
public func basicRTSwiftArrayOutStrings(_ values: [String]) -> UnsafeMutableRawPointer {
    BASICRTSwiftBridge.makeStringArray(values)
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
