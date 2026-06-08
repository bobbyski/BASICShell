# YIELD Statement

![BASICStudio](https://img.shields.io/badge/BASICStudio-supported-brightgreen)
![Shell](https://img.shields.io/badge/Shell-supported-brightgreen)

`YIELD` marks a cooperative task boundary.

In the current runtime slice, `YIELD` does not visibly pause execution because only one logical task runs at a time. It records a scheduler yield point on the current task and behaves like a no-op for program output.

Future async/thread slices will use `YIELD` as a safe place for the scheduler to let other ready BASIC tasks run.

```basic
print "before"
yield
print "after"
```

```basic
for i = 1 to 10
    print i
    yield
next i
```
