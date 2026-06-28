# FUNCTION Statement

![BASICStudio](https://img.shields.io/badge/BASICStudio-supported-brightgreen) ![BASICShell](https://img.shields.io/badge/BASICShell-supported-brightgreen)

Defines a top-level user function. Parameters must declare `AS <type>`. If the function has no `AS <type>` return clause, it defaults to `VOID` and cannot be used in an expression.

```basic
print Add(2, 3)
end

function Add(a as integer, b as integer) as integer
    return a + b
end function
```

Functions may also return by assigning to the function name.

```basic
print Title$()
end

function Title$() as string
    Title$ = "BASICSHELL"
end function
```

Use `AS VARIANT` explicitly for flexible scalar parameters.
