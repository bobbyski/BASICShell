# Math Functions

![BASICStudio](https://img.shields.io/badge/BASICStudio-supported-brightgreen) ![BASICShell](https://img.shields.io/badge/BASICShell-supported-brightgreen)

The numeric library. Every one takes a number and returns a number.

| Function | Answers |
| --- | --- |
| `ABS(x)` | The size of `x`, without its sign. |
| `SGN(x)` | -1, 0 or 1 as `x` is negative, zero or positive. `SCN` is the same function. |
| `INT(x)` | The largest whole number no greater than `x` — it rounds *down*, so `INT(-2.5)` is -3. |
| `FIX(x)` | `x` with its fraction dropped, toward zero, so `FIX(-2.5)` is -2. |
| `CINT(x)` | `x` rounded to the nearest whole number, halves away from zero. |
| `SQR(x)` | The square root. |
| `EXP(x)` | e raised to `x`. |
| `LOG(x)` | The natural logarithm. |
| `LCT(x)` | The logarithm base 10. |
| `LTW(x)` | The logarithm base 2. |
| `RND()` | A random number from 0 up to but not including 1. |
| `RANDOMIZE n` | Starts the random sequence from a known place. |

The three that cut a number down to a whole one differ only in which way they go, which is the sort of thing that is obvious until it costs an afternoon:

```basic
print int(-2.5), fix(-2.5), cint(-2.5)
print int(2.5), fix(2.5), cint(2.5)
```

prints `-3`, `-2`, `-3` on one line and `2`, `2`, `3` on the next: `INT` goes down, `FIX` goes toward zero, and `CINT` goes to the nearest.

## Random numbers

`RND()` answers a number from 0 up to but not including 1. `RANDOMIZE` with a value starts the sequence from a known place, which is what makes a program that uses random numbers testable.

```basic
randomize 42
print rnd(); rnd()
```

Given the same seed that prints the same two numbers every time. Without `RANDOMIZE` the sequence starts where it likes.
