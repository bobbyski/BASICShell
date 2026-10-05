# ON ERROR GOTO Statement

![BASICStudio](https://img.shields.io/badge/BASICStudio-supported-brightgreen) ![BASICShell](https://img.shields.io/badge/BASICShell-supported-brightgreen)

Installs or clears a runtime error handler. When a runtime error occurs and a handler is active, execution jumps to the target instead of reporting the error directly. `ON ERROR GOTO 0` clears the handler.

Without a handler, the program stops and says where: the failing statement's source line, a caret under where that statement starts, and the error with its line number (the line `ERL` would report).

```text
    RETURN 10 / x
    ^
Runtime error: Division by zero at 2
```

If the debugger is open, runtime errors still go to the handler first. Set a breakpoint inside the handler when you want the debugger to stop there.

```basic
on error goto HandleError
print 10 / 0
print "AFTER"
end

HandleError:
    print "ERR ="; ERR
    print "ERL ="; ERL
    resume next
```

```basic
on error goto HandleError
on error goto 0
print 10 / 0
```
