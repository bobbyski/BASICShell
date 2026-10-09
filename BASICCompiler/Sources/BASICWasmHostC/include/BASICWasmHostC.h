#ifndef BASIC_WASM_HOST_C_H
#define BASIC_WASM_HOST_C_H

// The C half of the WebAssembly runner (BASIC-45): what Swift cannot write.
//
// - A protected call: every runtime function a module imports runs inside
//   `basic_wasm_protected`, which takes a setjmp. A runtime error in hosted
//   mode calls `basic_wasm_unwind`, which longjmps back to the innermost one,
//   skipping only runtime frames, as ON ERROR's longjmp already does natively.
// - Trampolines: the runtime calls event handlers, async bodies and the
//   globals capture through C function pointers, and a WebAssembly function has
//   no native address. Each shape has a pool of real C functions; slot N calls
//   the shape's dispatcher with N, and the runner maps N to the module's table.

#include <stddef.h>

typedef void (*basic_wasm_body)(void *context);

/// Runs body(context). Answers 0, or the code a `basic_wasm_unwind` gave.
int basic_wasm_protected(basic_wasm_body body, void *context);

/// Back to the innermost protected call, with `code` (never 0).
_Noreturn void basic_wasm_unwind(int code);

/// The number of trampolines of each shape.
#define BASIC_WASM_TRAMPOLINES 128

typedef enum {
    basic_wasm_shape_ptr_void = 0,   // void (*)(void *)   event handler, globals restore
    basic_wasm_shape_ptr_ptr = 1,    // void *(*)(void *)  async body
    basic_wasm_shape_void_ptr = 2,   // void *(*)(void)    globals capture
    basic_wasm_shape_ptr_double = 3, // double (*)(void *) closure body
} basic_wasm_shape;

typedef void (*basic_wasm_dispatch_ptr_void)(int slot, void *argument);
typedef void *(*basic_wasm_dispatch_ptr_ptr)(int slot, void *argument);
typedef void *(*basic_wasm_dispatch_void_ptr)(int slot);
typedef double (*basic_wasm_dispatch_ptr_double)(int slot, void *argument);

/// Where every trampoline of each shape sends its call.
void basic_wasm_set_dispatchers(basic_wasm_dispatch_ptr_void ptr_void,
                                basic_wasm_dispatch_ptr_ptr ptr_ptr,
                                basic_wasm_dispatch_void_ptr void_ptr,
                                basic_wasm_dispatch_ptr_double ptr_double);

/// The native address of trampoline `slot` of `shape`, or NULL out of range.
void *basic_wasm_trampoline(basic_wasm_shape shape, int slot);

#endif
