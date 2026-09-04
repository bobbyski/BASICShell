import Foundation

// BASICRT — the runtime library every program compiled by basicc links.
//
// Entry points are `@_cdecl` so the generated LLVM IR calls them as plain C
// symbols; the naming convention is `basic_rt_<area>_<verb>`. Semantics must
// match the interpreter's — the interpreter is the oracle (prime directive).
//
// Phase 2 of BASIC_COMPILER.md fills this out; today it holds the two calls
// the toolchain spike makes.

/// Prints a NUL-terminated string followed by a newline.
@_cdecl("basic_rt_print_cstring")
public func basic_rt_print_cstring(_ text: UnsafePointer<CChar>) {
    print(String(cString: text))
}

/// Prints a number the way BASIC's `PRINT` does for a positive value: a
/// leading space, then the digits, then a trailing space.
///
/// Placeholder formatting — Phase 2.2 replaces this with the interpreter's
/// exact numeric formatting.
@_cdecl("basic_rt_print_double")
public func basic_rt_print_double(_ value: Double) {
    print(" \(value) ")
}
