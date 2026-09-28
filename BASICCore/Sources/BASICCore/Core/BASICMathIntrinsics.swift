//
//  BASICMathIntrinsics.swift
//  BASICCore
//
//  The one-argument math functions, and the domain each one refuses.
//

import Foundation

/// The builtin math functions that take one number and answer one number.
///
/// Every one checks its domain the way GW-BASIC does, so a program gets a
/// BASIC error rather than `nan` or `inf` traveling on to print (decision B4
/// in BBC_ADINS.md):
///
/// ```text
///   SQR(-1)                   Illegal function call
///   LOG(0), LN(-1), LOG10(0)  Illegal function call
///   ACS(2), ASN(2)            Illegal function call
///   COT(0), CSC(0)            Division by zero
///   EXP(1000), HCS(1000)      Overflow
/// ```
///
/// The compiled runtime has the same rules, one entry point per function
/// (`basic_rt_acs` and the rest, in BASICRT/RTMath.swift), so a function added
/// here is added there too.
///
/// `LOG` is a natural log, as in every Microsoft BASIC and VB (decision B1);
/// `LN` is BBC's name for the same thing, and `LOG10` is VB.NET's for base 10.
/// `DEG` is BBC's name for `DEC`, which this language has always had.
enum BASICMathIntrinsic: String, CaseIterable {
    case acs = "ACS", asn = "ASN", atn = "ATN", cos = "COS", cot = "COT", csc = "CSC"
    case dec = "DEC", deg = "DEG", exp = "EXP", hcs = "HCS", hsn = "HSN", htn = "HTN"
    case lct = "LCT", ln = "LN", log = "LOG", log10 = "LOG10", ltw = "LTW", rad = "RAD"
    case sec = "SEC", sin = "SIN", sqr = "SQR", tan = "TAN"

    /// The function applied to `x`, or the BASIC error its domain calls for.
    func apply(_ x: Double) throws -> Double {
        let result: Double
        switch self {
        case .acs: result = Foundation.acos(x)
        case .asn: result = Foundation.asin(x)
        case .atn: result = Foundation.atan(x)
        case .cos: result = Foundation.cos(x)
        case .cot: result = try Self.reciprocal(Foundation.tan(x))
        case .csc: result = try Self.reciprocal(Foundation.sin(x))
        case .sec: result = try Self.reciprocal(Foundation.cos(x))
        case .dec, .deg: result = x * 180 / Double.pi
        case .rad: result = x * Double.pi / 180
        case .exp: result = Foundation.exp(x)
        case .hcs: result = Foundation.cosh(x)
        case .hsn: result = Foundation.sinh(x)
        case .htn: result = Foundation.tanh(x)
        case .log, .ln: result = Foundation.log(try Self.positive(x))
        case .lct, .log10: result = Foundation.log10(try Self.positive(x))
        case .ltw: result = Foundation.log2(try Self.positive(x))
        case .sin: result = Foundation.sin(x)
        case .sqr:
            guard x >= 0 else { throw BASICError.runtime("Illegal function call") }
            result = Foundation.sqrt(x)
        case .tan: result = Foundation.tan(x)
        }
        try BASICArithmetic.requireFinite(result)
        return result
    }

    /// `x`, when a logarithm can take it.
    private static func positive(_ x: Double) throws -> Double {
        guard x > 0 else { throw BASICError.runtime("Illegal function call") }
        return x
    }

    /// `1 / x`, refusing the zero that `COT`, `CSC` and `SEC` would divide by.
    private static func reciprocal(_ x: Double) throws -> Double {
        guard x != 0 else { throw BASICError.runtime("Division by zero") }
        return 1 / x
    }
}
