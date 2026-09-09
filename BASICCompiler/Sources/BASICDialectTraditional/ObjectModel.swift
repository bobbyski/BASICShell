import BASICCompilerKit
import Foundation

/// Where a program's records and objects live, as the lowering sees it.
///
/// Rev 1 keeps every `TYPE` and `CLASS` in the runtime: an `RTComposite`
/// holding a slot list of values, reached through `basic_rt_composite_*`.
/// Rev 2 lays a `CLASS` out as a real Swift object. The emitter does not
/// care which — it asks this model **which symbol to call** at each of the
/// places it touches an object, and emits the same shape of code either
/// way. That is the whole seam: the traditional dialect answers with the
/// runtime's entry points and its IR is byte-for-byte what it was; the Swift
/// dialect answers with helpers it emits alongside.
///
/// Value semantics are the emitter's, not the model's. Assignment copies,
/// a method call copies the receiver in and writes it back, and the model
/// is asked for a `copy` and an `assign` in exactly those places — so a
/// class laid out as a Swift object behaves, observably, like one the
/// runtime holds. Ruling D13: internals may differ, running may not.
public protocol ObjectModel: Sendable {
    /// Whether `typeName` names a `CLASS` laid out as a Swift object. A
    /// `TYPE` record is never one; a class the model declined is not one.
    func isSwiftObject(_ typeName: String) -> Bool

    /// The whole-object operations. Each takes the same arguments as the
    /// runtime entry point it stands in for, and — when any class is a Swift
    /// object — decides *which representation it was handed* at run time,
    /// because an interface-typed variable may hold either.
    var symbols: ObjectSymbols { get }

    /// `NEW` for a class laid out as a Swift object, or nil for the runtime's
    /// `basic_rt_composite_new(index)`.
    func newSymbol(for typeName: String) -> String?

    /// Field access on a base whose *static* type is a Swift-object class,
    /// or nil for the runtime's `basic_rt_composite_get_*`/`set_*`. Same
    /// signatures as those: get takes `(ptr)`, set takes `(ptr, value)`.
    func fieldGetSymbol(for typeName: String, field index: Int) -> String?
    func fieldSetSymbol(for typeName: String, field index: Int) -> String?

    /// IR the module needs before the functions: `declare`s for the symbols
    /// above and any externals they use.
    var declarations: String { get }

    /// IR the module needs after the functions: the helpers' definitions,
    /// class metadata, accessors.
    func definitions(for module: BIRModule) -> String
}

/// The symbols for whole-object operations, by role.
public struct ObjectSymbols: Sendable {
    /// `(ptr) -> ptr`: a deep copy, owned.
    public var copy: String
    /// `(ptr dst, ptr src)`: take `src`'s contents into `dst`, keeping identity.
    public var assign: String
    /// `(ptr)`: drop one reference.
    public var release: String
    /// `(ptr) -> i64`: the runtime type index.
    public var typeIndex: String
    /// `(ptr) -> ptr`: the `<Name …>` text as a runtime string, owned.
    public var text: String
    /// `(ptr)`: `PRINT` it.
    public var print: String
    /// `(ptr) -> ptr`: box a copy as a VARIANT, owned.
    public var box: String
    /// `(ptr box, i64 typeIndex, ptr name) -> ptr`: unbox to an owned object.
    public var unbox: String

    public init(copy: String, assign: String, release: String, typeIndex: String,
                text: String, print: String, box: String, unbox: String) {
        self.copy = copy
        self.assign = assign
        self.release = release
        self.typeIndex = typeIndex
        self.text = text
        self.print = print
        self.box = box
        self.unbox = unbox
    }

    /// The runtime's own entry points.
    public static let runtime = ObjectSymbols(
        copy: "basic_rt_composite_copy",
        assign: "basic_rt_composite_assign",
        release: "basic_rt_composite_release",
        typeIndex: "basic_rt_composite_type",
        text: "basic_rt_composite_text",
        print: "basic_rt_print_composite",
        box: "basic_rt_value_from_composite",
        unbox: "basic_rt_value_composite"
    )
}

/// Rev 1's model: everything lives in the runtime.
public struct RuntimeObjectModel: ObjectModel {
    public init() {}
    public func isSwiftObject(_ typeName: String) -> Bool { false }
    public var symbols: ObjectSymbols { .runtime }
    public func newSymbol(for typeName: String) -> String? { nil }
    public func fieldGetSymbol(for typeName: String, field index: Int) -> String? { nil }
    public func fieldSetSymbol(for typeName: String, field index: Int) -> String? { nil }
    public var declarations: String { "" }
    public func definitions(for module: BIRModule) -> String { "" }
}
