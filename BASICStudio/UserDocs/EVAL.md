# EVAL Function

![BASICStudio](https://img.shields.io/badge/BASICStudio-supported-brightgreen) ![BASICShell](https://img.shields.io/badge/BASICShell-supported-brightgreen)

`EVAL(s$)` evaluates an expression written in a string, while the program runs, and returns its value: a number, a string or a truth value. BBC BASIC has it, and VBScript spells it `Eval`.

```basic
input "f(x) = "; formula$
for x = 0 to 3
    print x, eval(formula$)
next x
```

Typed as `x * x + 1`, that prints the formula's value for each `x`.

- **It is an expression, never a statement.** `=` compares, as in an `IF`: `eval("a = 2")` asks whether `a` is 2 and changes nothing.
- **It sees what the line it is on sees:** the program's variables, and inside a `FUNCTION` that function's locals and parameters. It can call the program's own functions.
- **It is pure by default.** Arithmetic, text, conversions and reading the clock are allowed. Anything that reaches outside the program, such as `SYSTEM$`, `ENVIRON$`, files, HTTP, the keyboard, methods and `NEW`, needs [OPTION EVAL FULL](OPTION.md). An `EVAL` of something a user typed should stay pure. `AWAIT` is never allowed.
- **A string that does not parse** is a runtime error, `Syntax error in EVAL`, numbered 2, on the `EVAL`'s line. [ON ERROR](ON_ERROR.md) traps it.

BBC programs also use it to read a variable whose name is built while the program runs:

```basic
score1 = 10: score2 = 20
for i = 1 to 2
    print eval("score" + mid$(str$(i), 2))
next i
```

A compiled program does the same: `basicc` hands the string, with every variable in scope, to the interpreter's own evaluator. Under `OPTION EVAL FULL` a compiled program's `EVAL` cannot reach the shell, files or HTTP, and it cannot call a function that takes an array.
