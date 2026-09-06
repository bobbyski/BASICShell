# ASC, CHR$, VAL and STR$ Functions

![BASICStudio](https://img.shields.io/badge/BASICStudio-supported-brightgreen) ![BASICShell](https://img.shields.io/badge/BASICShell-supported-brightgreen)

Moving between text and the things text can stand for.

| Function | Answers |
| --- | --- |
| `ASC(s)` | The character code of the first character of `s`. |
| `CHR$(n)` | The character with code `n`. |
| `VAL(s)` | The number `s` spells, or 0 when it spells none. |
| `STR$(n)` | `n` written out. |

```basic
print asc("A"); chr$(66)
print val("3.5")
print "["; str$(42); "]"
```

prints `65`, `B`, then `3.5`, then `[ 42]`.

That leading space in `STR$` is not a mistake and not ours: BASIC has always left room in front of a number for the minus sign it might have needed.

There is no `LTRIM$` in this BASIC. Where the space is in the way — building a coordinate list, say — take it off:

```basic
FUNCTION Trimmed$(value AS STRING) AS STRING
    LOCAL text$ = value
    WHILE LEFT$(text$, 1) = " "
        text$ = MID$(text$, 2)
    WEND
    RETURN text$
END FUNCTION

print "["; Trimmed$(STR$(42)); "]"
```

prints `[42]`.

See also [CHR$](CHR.md) and [String Functions](STRING_FUNCTIONS.md).
