import Foundation

// BASICRT cells — a variable a closure shares (Documents/CLOSURES.md, ruling
// C1) or holds its own changeable copy of (C2).
//
// A cell is eight bytes the compiled code loads and stores exactly as it would
// a frame slot: a function whose local a closure shares points that local's
// slot at the cell, and the closure body points its own slot at the same cell,
// so both read and write one variable. Every holder retains the cell — the
// frame for its run, a closure's environment for the closure's life — and the
// last release lets go of what the cell holds, by the kind it was made with.
//
// Under WebAssembly the module's loads and stores reach only its own memory,
// so there the eight bytes come from an arena the runner sets aside in it
// (`RTCell.useArena`); natively they are ordinary heap memory.

/// The runtime's cell.
package final class RTCell {
    /// How to let go of what the cell holds: the variable's managed kind.
    enum Kind: Int {
        case plain = 0
        case string
        case closure
        case composite
        case value
        case dictionary
        case array
        /// Released by the function the compiler passed (an object model's own).
        case custom
        /// A BOOLEAN: nothing to release, read as one byte.
        case boolean
    }

    private(set) var storage: UnsafeMutableRawPointer
    let kind: Kind
    let release: UnsafeRawPointer?

    init(kind: Kind, release: UnsafeRawPointer?, storage given: UnsafeMutableRawPointer? = nil) {
        storage = given ?? RTCell.allocate()
        if given == nil { storage.storeBytes(of: 0, as: UInt64.self) }
        self.kind = kind
        self.release = release
    }

    /// `LOCAL` ran again for a variable closures share: they keep its value,
    /// moved to new storage, and the frame keeps its storage, at the address
    /// its code already uses, for the new variable — in a new cell, which
    /// this answers, owned (Documents/CLOSURES.md C7).
    func refresh() -> RTCell {
        let kept = RTCell.allocate()
        kept.copyMemory(from: storage, byteCount: 8)
        let frames = storage
        storage = kept
        frames.storeBytes(of: 0, as: UInt64.self)
        return RTCell(kind: kind, release: release, storage: frames)
    }

    deinit {
        let held = storage.load(as: UnsafeMutableRawPointer?.self)
        if let held {
            switch kind {
            case .plain, .boolean: break
            case .string: basic_rt_string_release(held)
            case .closure: basic_rt_closure_release(held)
            // A runtime record or a Swift object of an object model's (an
            // imported one, or a CLASS laid out as Swift's): both are Swift
            // objects, released the same way.
            case .composite: Unmanaged<AnyObject>.fromOpaque(held).release()
            case .value: basic_rt_value_release(held)
            case .dictionary: basic_rt_dictionary_release(held)
            case .array: basic_rt_array_release(held)
            case .custom:
                if let release {
                    typealias Release = @convention(c) (UnsafeMutableRawPointer?) -> Void
                    unsafeBitCast(release, to: Release.self)(held)
                }
            }
        }
        RTCell.free(storage)
    }

    /// What the cell holds, for a debugger (Documents/CLOSURES.md 4.8): a
    /// number or a truth value read as one, anything else as the runtime
    /// object its eight bytes point at.
    func debugValue(name: String, typeName: String) -> RTDebugValue {
        switch kind {
        case .plain: return RTDebugValue(name: name, typeName: typeName.isEmpty ? "DOUBLE" : typeName,
                                         value: RTDebug.number(storage.load(as: Double.self)))
        case .boolean: return RTDebugValue(name: name, typeName: "BOOLEAN", value: storage.load(as: UInt8.self) & 1 == 1 ? "TRUE" : "FALSE")
        default: return RTDebug.describe(name: name, typeName: typeName, pointer: storage.load(as: UnsafeMutableRawPointer?.self))
        }
    }

    // MARK: Storage

    /// The WebAssembly module's arena, while one runs: eight-byte slots from
    /// `base`, `size` bytes in all.
    nonisolated(unsafe) private static var arena: (base: UnsafeMutableRawPointer, size: Int)?
    nonisolated(unsafe) private static var arenaUsed = 0
    nonisolated(unsafe) private static var arenaFree: [UnsafeMutableRawPointer] = []

    /// Cells come from `base` for `size` bytes, inside a WebAssembly module's
    /// memory, until `endArena`.
    package static func useArena(base: UnsafeMutableRawPointer, size: Int) {
        arena = (base, size)
        arenaUsed = 0
        arenaFree = []
    }

    /// Cells are heap memory again.
    package static func endArena() {
        arena = nil
        arenaUsed = 0
        arenaFree = []
    }

    private static func allocate() -> UnsafeMutableRawPointer {
        guard let arena else { return UnsafeMutableRawPointer.allocate(byteCount: 8, alignment: 8) }
        if let slot = arenaFree.popLast() { return slot }
        guard arenaUsed + 8 <= arena.size else { basic_rt_fail("Out of memory: too many variables shared with closures") }
        defer { arenaUsed += 8 }
        return arena.base + arenaUsed
    }

    private static func free(_ storage: UnsafeMutableRawPointer) {
        guard let arena else { storage.deallocate(); return }
        if storage >= arena.base, storage < arena.base + arena.size {
            arenaFree.append(storage)
        }
    }
}

@inline(__always)
func rtCell(_ pointer: UnsafeMutableRawPointer?) -> RTCell {
    guard let pointer else { basic_rt_fail("A shared variable was never made") }
    return Unmanaged<RTCell>.fromOpaque(pointer).takeUnretainedValue()
}

/// A new cell holding nothing yet (zero), owned (+1). `kind` is
/// `RTCell.Kind`'s raw value; `release` is the function for `.custom`.
@_cdecl("basic_rt_cell_new")
public func basic_rt_cell_new(_ kind: Int, _ release: UnsafeRawPointer?) -> UnsafeMutableRawPointer {
    Unmanaged.passRetained(RTCell(kind: RTCell.Kind(rawValue: kind) ?? .plain, release: release)).toOpaque()
}

@_cdecl("basic_rt_cell_retain")
public func basic_rt_cell_retain(_ pointer: UnsafeMutableRawPointer?) {
    guard let pointer else { return }
    _ = Unmanaged<RTCell>.fromOpaque(pointer).retain()
}

@_cdecl("basic_rt_cell_release")
public func basic_rt_cell_release(_ pointer: UnsafeMutableRawPointer?) {
    guard let pointer else { return }
    Unmanaged<RTCell>.fromOpaque(pointer).release()
}

/// The cell's eight bytes, where the variable's value is loaded and stored.
@_cdecl("basic_rt_cell_storage")
public func basic_rt_cell_storage(_ pointer: UnsafeMutableRawPointer?) -> UnsafeMutableRawPointer {
    rtCell(pointer).storage
}

/// Puts a cell in a closure environment's field; the environment retains it.
@_cdecl("basic_rt_composite_set_cell")
public func basic_rt_composite_set_cell(_ pointer: UnsafeMutableRawPointer?, _ field: Int, _ cell: UnsafeMutableRawPointer?) {
    rtComposite(pointer).fields[field] = .cell(rtCell(cell))
}

/// The cell in a closure environment's field, borrowed.
@_cdecl("basic_rt_composite_get_cell")
public func basic_rt_composite_get_cell(_ pointer: UnsafeMutableRawPointer?, _ field: Int) -> UnsafeMutableRawPointer? {
    guard case .cell(let cell) = rtComposite(pointer).fields[field] else { basic_rt_fail("A shared variable was never made") }
    return Unmanaged.passUnretained(cell).toOpaque()
}

// MARK: - WEAK captures

/// A closure's `WEAK` capture of an imported object (Documents/CLOSURES.md,
/// ruling C5): it does not keep the object alive, and reads as `NULL` once
/// the object is gone. An imported object is a Swift object, so this is
/// Swift's own weak reference.
package final class RTWeak {
    weak var object: AnyObject?
    init(_ object: AnyObject?) { self.object = object }
}

/// Puts a weak reference to an imported object (borrowed; null is NULL) in a
/// closure environment's field.
@_cdecl("basic_rt_composite_set_weak")
public func basic_rt_composite_set_weak(_ pointer: UnsafeMutableRawPointer?, _ field: Int, _ object: UnsafeMutableRawPointer?) {
    let held = object.map { Unmanaged<AnyObject>.fromOpaque($0).takeUnretainedValue() }
    rtComposite(pointer).fields[field] = .system(RTSystemObject(typeName: "WEAK", payload: RTWeak(held)))
}

/// The object a closure environment's weak field refers to, owned (+1), or
/// null once it is gone.
@_cdecl("basic_rt_composite_get_weak")
public func basic_rt_composite_get_weak(_ pointer: UnsafeMutableRawPointer?, _ field: Int) -> UnsafeMutableRawPointer? {
    guard case .system(let box) = rtComposite(pointer).fields[field], let weak = box.payload as? RTWeak,
          let object = weak.object else { return nil }
    return Unmanaged.passRetained(object).toOpaque()
}

/// `LOCAL` ran for a variable closures share: the cell in `slot` (the
/// frame's) is handed to the closures, keeping its value, and the slot gets
/// a fresh cell over the frame's storage (Documents/CLOSURES.md C7).
@_cdecl("basic_rt_cell_fresh")
public func basic_rt_cell_fresh(_ slot: UnsafeMutableRawPointer?) {
    guard let slot, let old = slot.load(as: UnsafeMutableRawPointer?.self) else { return }
    let fresh = rtCell(old).refresh()
    slot.storeBytes(of: Unmanaged.passRetained(fresh).toOpaque(), as: UnsafeMutableRawPointer.self)
    Unmanaged<RTCell>.fromOpaque(old).release()
}
