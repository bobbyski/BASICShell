# ON ERROR GOTO Statement

![BASICStudio](https://img.shields.io/badge/BASICStudio-supported-brightgreen) ![BASICShell](https://img.shields.io/badge/BASICShell-supported-brightgreen)

Installs or clears a runtime error handler. When a runtime error occurs and a handler is active, execution jumps to the target instead of reporting the error directly. `ON ERROR GOTO 0` clears the handler.

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
