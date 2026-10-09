#include "BASICWasmHostC.h"

#include <setjmp.h>
#include <stdlib.h>

// MARK: - Protected calls

// The innermost protected call on this thread. A module runs on one thread,
// and calls nest only through callbacks, so a linked list on the C stack is
// enough.
static _Thread_local jmp_buf *basic_wasm_top = NULL;

int basic_wasm_protected(basic_wasm_body body, void *context) {
    jmp_buf here;
    jmp_buf *volatile previous = basic_wasm_top;
    basic_wasm_top = &here;
    int code = setjmp(here);
    if (code == 0) {
        body(context);
    }
    basic_wasm_top = previous;
    return code;
}

_Noreturn void basic_wasm_unwind(int code) {
    if (basic_wasm_top == NULL) {
        abort();
    }
    longjmp(*basic_wasm_top, code == 0 ? 1 : code);
}

// MARK: - Trampolines

static basic_wasm_dispatch_ptr_void dispatch_ptr_void = NULL;
static basic_wasm_dispatch_ptr_ptr dispatch_ptr_ptr = NULL;
static basic_wasm_dispatch_void_ptr dispatch_void_ptr = NULL;
static basic_wasm_dispatch_ptr_double dispatch_ptr_double = NULL;

void basic_wasm_set_dispatchers(basic_wasm_dispatch_ptr_void ptr_void,
                                basic_wasm_dispatch_ptr_ptr ptr_ptr,
                                basic_wasm_dispatch_void_ptr void_ptr,
                                basic_wasm_dispatch_ptr_double ptr_double) {
    dispatch_ptr_void = ptr_void;
    dispatch_ptr_ptr = ptr_ptr;
    dispatch_void_ptr = void_ptr;
    dispatch_ptr_double = ptr_double;
}

#define ONE(N) \
    static void tramp_ptr_void_##N(void *a) { dispatch_ptr_void(N, a); } \
    static void *tramp_ptr_ptr_##N(void *a) { return dispatch_ptr_ptr(N, a); } \
    static void *tramp_void_ptr_##N(void) { return dispatch_void_ptr(N); } \
    static double tramp_ptr_double_##N(void *a) { return dispatch_ptr_double(N, a); }
#define EIGHT(B) ONE(B##0) ONE(B##1) ONE(B##2) ONE(B##3) ONE(B##4) ONE(B##5) ONE(B##6) ONE(B##7)
// Slots 0 … 127, as octal digit pairs and triples (0, 1, … 017, 020, … 0177).
EIGHT(0) EIGHT(01) EIGHT(02) EIGHT(03) EIGHT(04) EIGHT(05) EIGHT(06) EIGHT(07)
EIGHT(010) EIGHT(011) EIGHT(012) EIGHT(013) EIGHT(014) EIGHT(015) EIGHT(016) EIGHT(017)

#define REF(S, N) (void *)tramp_##S##_##N
#define REF8(S, B) REF(S, B##0), REF(S, B##1), REF(S, B##2), REF(S, B##3), REF(S, B##4), REF(S, B##5), REF(S, B##6), REF(S, B##7)
#define TABLE(S) { REF8(S, 0), REF8(S, 01), REF8(S, 02), REF8(S, 03), REF8(S, 04), REF8(S, 05), REF8(S, 06), REF8(S, 07), \
                   REF8(S, 010), REF8(S, 011), REF8(S, 012), REF8(S, 013), REF8(S, 014), REF8(S, 015), REF8(S, 016), REF8(S, 017) }

static void *const table_ptr_void[BASIC_WASM_TRAMPOLINES] = TABLE(ptr_void);
static void *const table_ptr_ptr[BASIC_WASM_TRAMPOLINES] = TABLE(ptr_ptr);
static void *const table_void_ptr[BASIC_WASM_TRAMPOLINES] = TABLE(void_ptr);
static void *const table_ptr_double[BASIC_WASM_TRAMPOLINES] = TABLE(ptr_double);

void *basic_wasm_trampoline(basic_wasm_shape shape, int slot) {
    if (slot < 0 || slot >= BASIC_WASM_TRAMPOLINES) return NULL;
    switch (shape) {
    case basic_wasm_shape_ptr_void: return table_ptr_void[slot];
    case basic_wasm_shape_ptr_ptr: return table_ptr_ptr[slot];
    case basic_wasm_shape_void_ptr: return table_void_ptr[slot];
    case basic_wasm_shape_ptr_double: return table_ptr_double[slot];
    }
    return NULL;
}
