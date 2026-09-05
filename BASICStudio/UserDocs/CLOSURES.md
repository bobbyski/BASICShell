# Closures and CAPTURES

![BASICStudio](https://img.shields.io/badge/BASICStudio-supported-brightgreen) ![BASICShell](https://img.shields.io/badge/BASICShell-supported-brightgreen)

A function can be a value. Written inline it is one expression, and it can be kept in a variable and called later.

```basic
prefix$ = "LOCKED="
bonus = 5
score = function(v as integer) as string captures readonly prefix$ = prefix$ + str$(v + bonus)
prefix$ = "LIVE="
bonus = 20
print score(2)
```

prints `LOCKED= 22`, and the two halves of that answer are the whole point:

- `prefix$` was **captured**, so the closure kept the value it had when the closure was made — `LOCKED=`, not the `LIVE=` assigned afterwards.
- `bonus` was not captured, so it is read when the closure is *called* — 20, not the 5 it held at the time.

The form is `FUNCTION(parameters) AS Type CAPTURES <how> name, ... = expression`. Everything after the `=` is the body.

## How a variable is captured

| Word | Meaning |
| --- | --- |
| `READONLY` | The closure reads the captured value and cannot change it. This is what you get if you name a variable and say nothing else. |
| `READ-ONLY` | The same thing, spelled with the hyphen. |
| `STRONG` | The closure holds the value and keeps it alive. |
| `MUTABLE` | The same as `STRONG`. |
| `WEAK` | The closure holds the value without keeping it alive. |

Separate several captures with commas: `captures readonly a$, strong b`.

Naming captures explicitly is worth the words when it matters which value the closure ends up with. Without a `CAPTURES` list the closure works out for itself which variables its body uses.
