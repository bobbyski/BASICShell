//
//  BASICArithmetic.swift
//  BASICCore
//
//  The operators BASIC has beyond + - * /, and the checks that keep a number
//  from turning into something that crashes the process.
//

import Foundation

/// `^`, `MOD` and `\` on numbers, plus the two checks every numeric result
/// needs: that it is finite, and that it fits a whole number when one is wanted.
///
/// The rules are GW-BASIC's (User's Guide §6.4.1):
///
/// ```text
///   a ^ b      pow(a, b)
///              0 ^ negative            → Division by zero
///              not a number            → Illegal function call   (-8 ^ 0.5)
///              too big to hold         → Overflow                (10 ^ 400)
///
///   a MOD b    round both to whole numbers, then the remainder,
///              with the dividend's sign:  -7 MOD 3 = -1,  25.68 MOD 6.99 = 5
///
///   a \ b      round both to whole numbers, then the quotient,
///              truncated toward zero:     -7 \ 2 = -3
/// ```
///
/// Kept out of `BASICInterpreter` so the rules sit in one small place, and so
/// the compiled runtime's copy (`RTArithmetic.swift` in BASICRT) has one thing
/// to match line for line. The interpreter is the oracle; that file follows
/// this one.
enum BASICArithmetic {
    /// The largest magnitude a whole number may have here: just under 2⁶³, so
    /// the conversion to `Int` can never trap. The compiled runtime prints
    /// numbers with the same bound.
    static let wholeNumberLimit = 9.2e18

    /// `base ^ exponent`.
    static func power(_ base: Double, _ exponent: Double) throws -> Double {
        if base == 0 && exponent < 0 {
            throw BASICError.runtime("Division by zero")
        }
        let result = pow(base, exponent)
        try requireFinite(result)
        return result
    }

    /// `dividend MOD divisor`, on the operands rounded to whole numbers.
    static func modulo(_ dividend: Double, _ divisor: Double) throws -> Double {
        let (left, right) = try wholeOperands(dividend, divisor)
        return Double(left % right)
    }

    /// `dividend \ divisor`, on the operands rounded to whole numbers.
    static func integerDivide(_ dividend: Double, _ divisor: Double) throws -> Double {
        let (left, right) = try wholeOperands(dividend, divisor)
        return Double(left / right)
    }

    /// Refuses a result that is not a finite number (decision B4 in
    /// BBC_ADINS.md): the error is raised where the value is made, rather than
    /// letting `inf` or `nan` travel on and print.
    static func requireFinite(_ value: Double) throws {
        if value.isNaN {
            throw BASICError.runtime("Illegal function call")
        }
        if value.isInfinite {
            throw BASICError.runtime("Overflow")
        }
    }

    /// `value` rounded to a whole number, as every integer argument is read.
    ///
    /// `Int(value.rounded())` traps on infinity and on anything past 2⁶³, and
    /// a trap takes the whole shell down with it. This reports the same case
    /// as a BASIC error instead.
    static func wholeNumber(_ value: Double) throws -> Int {
        let rounded = value.rounded()
        try requireFinite(rounded)
        guard abs(rounded) < wholeNumberLimit else {
            throw BASICError.runtime("Overflow")
        }
        return Int(rounded)
    }

    /// Both operands of `MOD` or `\` as whole numbers, refusing a zero divisor.
    ///
    /// The divisor is checked after rounding, as GW checks it: `5 MOD 0.4` is
    /// `5 MOD 0`, a division by zero.
    private static func wholeOperands(_ dividend: Double, _ divisor: Double) throws -> (Int, Int) {
        let left = try wholeNumber(dividend)
        let right = try wholeNumber(divisor)
        guard right != 0 else {
            throw BASICError.runtime("Division by zero")
        }
        return (left, right)
    }
}
