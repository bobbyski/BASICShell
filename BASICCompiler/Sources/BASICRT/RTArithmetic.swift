import Foundation

// BASICRT arithmetic — `^`, `MOD` and `\`, and the checks that keep a number
// from trapping on its way to an Int.
//
// This is the compiled copy of BASICCore's `BASICArithmetic`, and it has to
// match that file line for line: the interpreter is the oracle, and a program
// that says `-7 MOD 3` or `10 ^ 400` must get the same answer, or the same
// error, from both engines.
//
//   a ^ b     pow(a, b); 0 ^ negative is Division by zero, a result that is
//             not a number is Illegal function call, one too big is Overflow
//   a MOD b   both rounded to whole numbers, remainder with the dividend's sign
//   a \ b     both rounded to whole numbers, quotient truncated toward zero

enum RTArithmetic {
    /// Just under 2⁶³, so converting to `Int` can never trap. `rtNumberText`
    /// and the interpreter's number printing use the same bound.
    static let wholeNumberLimit = 9.2e18

    /// Fails on a result that is not a finite number, rather than letting
    /// `inf` or `nan` travel on (decision B4 in BBC_ADINS.md).
    static func requireFinite(_ value: Double) {
        if value.isNaN { basic_rt_fail("Illegal function call") }
        if value.isInfinite { basic_rt_fail("Overflow") }
    }

    /// `value` rounded to a whole number, as every integer argument is read,
    /// or Overflow when no `Int` can hold it.
    static func wholeNumber(_ value: Double) -> Int {
        let rounded = value.rounded()
        requireFinite(rounded)
        guard abs(rounded) < wholeNumberLimit else { basic_rt_fail("Overflow") }
        return Int(rounded)
    }

    /// Both operands of `MOD` or `\` as whole numbers, refusing a zero divisor
    /// after rounding, as GW does: `5 MOD 0.4` is `5 MOD 0`.
    static func wholeOperands(_ dividend: Double, _ divisor: Double) -> (Int, Int) {
        let left = wholeNumber(dividend)
        let right = wholeNumber(divisor)
        guard right != 0 else { basic_rt_fail("Division by zero") }
        return (left, right)
    }
}

/// `base ^ exponent`.
@_cdecl("basic_rt_power")
public func basic_rt_power(_ base: Double, _ exponent: Double) -> Double {
    if base == 0 && exponent < 0 { basic_rt_fail("Division by zero") }
    let result = pow(base, exponent)
    RTArithmetic.requireFinite(result)
    return result
}

/// `dividend MOD divisor`.
@_cdecl("basic_rt_modulo")
public func basic_rt_modulo(_ dividend: Double, _ divisor: Double) -> Double {
    let (left, right) = RTArithmetic.wholeOperands(dividend, divisor)
    return Double(left % right)
}

/// `dividend \ divisor`.
@_cdecl("basic_rt_integer_divide")
public func basic_rt_integer_divide(_ dividend: Double, _ divisor: Double) -> Double {
    let (left, right) = RTArithmetic.wholeOperands(dividend, divisor)
    return Double(left / right)
}
