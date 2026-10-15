# Closures and CAPTURES

![BASICStudio](https://img.shields.io/badge/BASICStudio-supported-brightgreen) ![BASICShell](https://img.shields.io/badge/BASICShell-supported-brightgreen)

A function can be a value. A *closure* is a function written where it is needed, kept in a variable, and called later like any function.

```basic
bonus = 5
score = function(v as integer) as string = "SCORE=" + str$(v + bonus)
bonus = 100
print score(7)
```

prints `SCORE= 107`. The closure uses `bonus`, so it **shares** that variable with the code around it, as a Visual Basic lambda does: when `bonus` changes, the closure sees the change.

## Two ways to write one

On one line, the body is a single expression after `=`:

```basic
twice = function(n as integer) as integer = n * 2
```

On several lines, the body is ordinary statements, ending with `END FUNCTION`:

```basic
total = 0
add = function(n as integer) as integer
    total = total + n
    return total
end function
x = add(5)
x = add(7)
print total
```

prints `12`. Sharing works both ways: what the closure assigns reaches the variable.

Every parameter needs `AS <type>`. On the one-line form, a missing return type means `VARIANT`.

## A closure outlives the function that made it

A closure keeps the variables it shares, even after the function that made them has returned. Each call of `MakeCounter` below makes a new `count`, and the closure it returns keeps that one:

```basic
function type Counter() as integer

function MakeCounter() as Counter
    local count as integer = 0
    local tick as Counter
    tick = function() as integer
        count = count + 1
        return count
    end function
    return tick
end function

c = MakeCounter()
d = MakeCounter()
print c(); c(); c(); d()
```

prints `1231`: `c` counts to 3 on its own, and `d` starts again at 1.

A `LOCAL` declared inside a loop is a new variable on each pass, so a closure made on each pass keeps its own.

## CAPTURES: when sharing is not what you want

A `CAPTURES` list after the return type says how particular variables are held. Every variable the body uses that the list does not name is shared.

```basic
prefix$ = "LOCKED="
bonus = 5
score = function(v as integer) as string captures readonly prefix$ = prefix$ + str$(v + bonus)
prefix$ = "LIVE="
bonus = 20
print score(2)
```

prints `LOCKED= 22`: `prefix$` was frozen when the closure was made, and `bonus` is shared, so the closure sees 20.

| Word | Meaning |
| --- | --- |
| `MUTABLE` | Share the variable. This is what every variable gets anyway; `MUTABLE` says so. A name listed with no word is shared too. |
| `STRONG` | The closure's own copy, taken when it is made. The closure may change it, and its changes are kept from one call to the next, but they never reach the variable outside. |
| `READONLY` | A copy frozen when the closure is made. Assigning it inside the closure stops with `X is captured READONLY`, which `ON ERROR` can trap. |
| `READ-ONLY` | The same as `READONLY`. |
| `WEAK` | For an object an `IMPORT`ed framework made (an ActiveUI label, a TUIKit window): the closure does not keep it alive, and once nothing else holds it, the closure sees `NULL`. On anything else, `WEAK` stops with `WEAK needs an imported object`. |

Separate several with commas: `captures readonly a$, strong b`.

```basic
n = 10
own = function() as integer captures strong n
    n = n + 1
    return n
end function
print own(); own(); n
```

prints `111210`: the closure counts its own copy, and `n` is still 10.

```basic
import "ActiveUI"
dim caption as AUILabel
caption = new AUILabel("Hello")
look = function() as string captures weak caption
    if caption = NULL then return "gone"
    return caption.text
end function
print look()
caption = NULL
print look()
```

prints `Hello`, then `gone`: once `caption` lets go, nothing holds the label.

Objects and records are values in BASIC, so inside a class method a closure that uses `ME` gets its own copy of the object, as with `STRONG`. It can change that copy, but the changes never reach the object itself.

## Function types

`FUNCTION TYPE` names the shape of a function, so a variable, a parameter or a result can be declared to hold one:

```basic
function type Formatter(value as integer) as string

function Apply$(f as Formatter, n as integer) as string
    return "[" + f(n) + "]"
end function

print Apply$(function(v as integer) as string = "N=" + str$(v), 4)
```

prints `[N= 4]`. A closure fits a function type when its parameter types and its return type are the same; the parameter names do not matter. One that does not fit is a `Type Mismatch`.

Assign `NULL` to a closure variable to clear it. Calling a cleared one stops with `Closure was never set`.

## Compiled programs

`basicc` compiles closures, with the same sharing and `CAPTURES` rules, for native binaries and WebAssembly. It needs the return type: a closure with no `AS`, or `AS VARIANT`, is not compiled yet.
