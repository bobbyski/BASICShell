# String Functions

![BASICStudio](https://img.shields.io/badge/BASICStudio-supported-brightgreen) ![BASICShell](https://img.shields.io/badge/BASICShell-supported-brightgreen)

| Function | Answers |
| --- | --- |
| `LEN(s)` | How many characters are in `s`. |
| `LEFT$(s, n)` | The first `n` characters. |
| `RIGHT$(s, n)` | The last `n` characters. |
| `MID$(s, start, n)` | `n` characters from `start`, counting from 1. |
| `INSTR(start, s, find)` | Where `find` first appears in `s` at or after `start`, or 0. |
| `SPACE$(n)` | A string of `n` spaces. |
| `STRING$(n, s)` | `s` repeated `n` times. |
| `HEX$(n)` | `n` in hexadecimal, in capitals. |
| `BINARY$(n)` | `n` in binary. |

```basic
print len("hello")
print left$("hello", 2); mid$("hello", 2, 3); right$("hello", 3)
print instr(1, "hello world", "o")
print hex$(255); " "; binary$(10)
```

prints `5`, `heellllo`, `5` and `FF 1010`.

`HEX$` and `BINARY$` want a whole number that is not negative; anything else is an error rather than a guess.

## SPC

`SPC(n)` is not quite a function — it belongs to `PRINT`, where it writes `n` spaces.

```basic
print "a"; spc(3); "b"
```
