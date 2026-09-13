/// A Swift value a BASIC program holds by reference (P1.3e).
///
/// Some structs are neither numbers nor a record BASIC can hold by value:
/// `AUIColor` wraps a platform color object, light and dark variants and all,
/// and no TYPE could stand for it. When such a struct is immutable, sharing
/// one box between BASIC variables is indistinguishable from copying the
/// value — so it crosses as a box, and BASIC reaches it the way it reaches an
/// imported class.
///
/// **One class for every boxed type.** The object model recognizes an object
/// by its metadata pointer, so a single class is a single probe; the BASIC
/// type a box holds travels in the box instead.
public final class BASICOpaque {
    public let value: Any
    /// The BASIC type index of what the box holds: its `CLASS`.
    public let typeIndex: Int

    public init(_ value: Any, typeIndex: Int) {
        self.value = value
        self.typeIndex = typeIndex
    }
}

/// A new owned (+1) box, for a shim handing a value to BASIC.
@_silgen_name("basic_rt_swift_opaque_make")
public func basicRTSwiftOpaqueMake(_ value: Any, _ typeIndex: Int) -> UnsafeMutableRawPointer {
    Unmanaged.passRetained(BASICOpaque(value, typeIndex: typeIndex)).toOpaque()
}

/// The value a box holds, for a shim handing it to Swift. A box BASIC never
/// set is a BASIC error, as an unset object is.
@_silgen_name("basic_rt_swift_opaque_value")
public func basicRTSwiftOpaqueValue(_ pointer: UnsafeMutableRawPointer?) -> Any {
    guard let pointer else { BASICRTSwiftBridge.fail("An imported value was never set") }
    return Unmanaged<BASICOpaque>.fromOpaque(pointer).takeUnretainedValue().value
}

/// The BASIC type index a box holds: what the object model's `typeIndex`
/// dispatcher answers for one, since every box shares one class.
@_cdecl("basic_rt_opaque_type_index")
public func basic_rt_opaque_type_index(_ pointer: UnsafeMutableRawPointer?) -> Int {
    guard let pointer else { return -1 }
    return Unmanaged<BASICOpaque>.fromOpaque(pointer).takeUnretainedValue().typeIndex
}

/// A box as text, owned (+1): the value's own description, which is what
/// PRINT shows for one.
@_cdecl("basic_rt_opaque_text")
public func basic_rt_opaque_text(_ pointer: UnsafeMutableRawPointer?) -> UnsafeMutableRawPointer {
    guard let pointer else { return BASICRTSwiftBridge.makeString("") }
    let value = Unmanaged<BASICOpaque>.fromOpaque(pointer).takeUnretainedValue().value
    return BASICRTSwiftBridge.makeString(String(describing: value))
}
