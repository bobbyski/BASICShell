# Pseudo Variables

![BASICStudio](https://img.shields.io/badge/BASICStudio-supported-brightgreen) ![BASICShell](https://img.shields.io/badge/BASICShell-supported-brightgreen)

Names that are already set: read them like variables, but nothing assigns to them.

| Name | Answers |
| --- | --- |
| `ERRORLEVEL` | The exit status of the last command. 0 when it succeeded; non-zero from a command that failed, including a built-in like `CD`. |
| `CURRENT_FUNCTION$` | The name of the function this line is inside. |
| `CURRENT_TASK$` | The running task — `#1 Program` in an ordinary program, and the task's own name inside an `ASYNC` one. |
| `CURRENT_THREAD$` | Which thread is running the code. |

```basic
print Who$()

function Who$() as string
    return CURRENT_FUNCTION$
end function
```

prints `Who$`.

They are most useful in a message a person will read — a trace line, or an error that has to say where it came from without being told.
