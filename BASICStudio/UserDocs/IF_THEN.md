# IF THEN Statement

![BASICStudio](https://img.shields.io/badge/BASICStudio-supported-brightgreen) ![BASICShell](https://img.shields.io/badge/BASICShell-supported-brightgreen)

Branches to a line or label when an expression is true, or runs inline/block statement branches. Numeric zero is false; nonzero is true.

```basic
x = 3
if x >= 3 then BigEnough
print "TOO SMALL"
end
BigEnough:
print "OK"
```

```basic
if x = 5 then print "FIVE" else print "NOT FIVE"
```

```basic
if day = 3 then
print "WEDNESDAY"
elseif day = 4 then
print "THURSDAY"
else
print "OTHER"
end if
```
