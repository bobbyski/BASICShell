# RESUME NEXT Statement

![BASICStudio](https://img.shields.io/badge/BASICStudio-supported-brightgreen) ![BASICShell](https://img.shields.io/badge/BASICShell-supported-brightgreen)

Continues execution with the statement after the one that raised the most recent trapped error.

Current support is limited to `RESUME NEXT`. Classic `RESUME` and `RESUME line-or-label` are planned for a later compatibility pass.

```basic
on error goto Handler
print 10 / 0
print "CONTINUED"
end

Handler:
    print "ERROR "; ERR
    resume next
```
