# SLEEP() Function

![BASICStudio](https://img.shields.io/badge/BASICStudio-supported-brightgreen) ![Shell](https://img.shields.io/badge/Shell-supported-brightgreen)

`SLEEP(milliseconds)` starts a timer host task and returns a task handle. Use `AWAIT` to wait for the timer without blocking the host callback path.

The awaited result is the number of milliseconds requested.

```basic
print "BEFORE"
slept = await Sleep(250)
print "AFTER "; slept
```

You can also keep the handle and wait later:

```basic
timer = Sleep(100)
print "timer started"
slept = await timer
print "done "; slept
```
