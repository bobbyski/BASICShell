# SYSTEM Statement and SYSTEM$() Function

![BASICStudio](https://img.shields.io/badge/BASICStudio-supported-brightgreen) ![BASICShell](https://img.shields.io/badge/BASICShell-supported-brightgreen)

Runs a command through the host shell. `SYSTEM` writes the command output to the console. `SYSTEM$()` runs the command and returns its output as a string.

```basic
system "pwd"
print system$("date")
```

`SYSTEM$()` can be combined with other string expressions.

```basic
print "Files:"
print system$("ls")
```
