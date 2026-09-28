import Foundation

// BASICRT math — the one-argument functions that lower to a runtime call
// rather than an LLVM intrinsic.
//
// The compiled copy of BASICCore's `BASICMathIntrinsic`, and it has to match
// that file: each function refuses its domain the way the interpreter does,
// so `ACS(2)` is Illegal function call and `COT(0)` is Division by zero in
// both engines. SQR, LOG, LN, EXP, SIN, COS, TAN and ATN keep their LLVM
// intrinsics, and LLVMLowering emits the same checks inline beside them.

/// `1 / x`, refusing the zero that `COT`, `CSC` and `SEC` would divide by.
private func rtReciprocal(_ x: Double) -> Double {
    guard x != 0 else { basic_rt_fail("Division by zero") }
    return 1 / x
}

/// `x`, when a logarithm can take it.
func rtPositive(_ x: Double) -> Double {
    guard x > 0 else { basic_rt_fail("Illegal function call") }
    return x
}

/// `value`, once it is known to be a finite number.
func rtFinite(_ value: Double) -> Double {
    RTArithmetic.requireFinite(value)
    return value
}

@_cdecl("basic_rt_acs")
public func basic_rt_acs(_ x: Double) -> Double { rtFinite(acos(x)) }

@_cdecl("basic_rt_asn")
public func basic_rt_asn(_ x: Double) -> Double { rtFinite(asin(x)) }

@_cdecl("basic_rt_cot")
public func basic_rt_cot(_ x: Double) -> Double { rtFinite(rtReciprocal(tan(x))) }

@_cdecl("basic_rt_csc")
public func basic_rt_csc(_ x: Double) -> Double { rtFinite(rtReciprocal(sin(x))) }

@_cdecl("basic_rt_sec")
public func basic_rt_sec(_ x: Double) -> Double { rtFinite(rtReciprocal(cos(x))) }

@_cdecl("basic_rt_hcs")
public func basic_rt_hcs(_ x: Double) -> Double { rtFinite(cosh(x)) }

@_cdecl("basic_rt_hsn")
public func basic_rt_hsn(_ x: Double) -> Double { rtFinite(sinh(x)) }

@_cdecl("basic_rt_htn")
public func basic_rt_htn(_ x: Double) -> Double { rtFinite(tanh(x)) }

/// `LCT`, the name this language has always had for a base-10 log.
@_cdecl("basic_rt_lct")
public func basic_rt_lct(_ x: Double) -> Double { rtFinite(log10(rtPositive(x))) }

/// `LOG10`, VB.NET's name for the same thing as `LCT`.
@_cdecl("basic_rt_log10")
public func basic_rt_log10(_ x: Double) -> Double { rtFinite(log10(rtPositive(x))) }

@_cdecl("basic_rt_ltw")
public func basic_rt_ltw(_ x: Double) -> Double { rtFinite(log2(rtPositive(x))) }

@_cdecl("basic_rt_rad")
public func basic_rt_rad(_ x: Double) -> Double { rtFinite(x * Double.pi / 180) }

/// `DEG`, and `DEC` as its older name.
@_cdecl("basic_rt_deg")
public func basic_rt_deg(_ x: Double) -> Double { rtFinite(x * 180 / Double.pi) }
