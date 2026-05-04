# SELECT CASE

![BASICStudio](https://img.shields.io/badge/BASICStudio-supported-brightgreen) ![BASICShell](https://img.shields.io/badge/BASICShell-supported-brightgreen)

Runs the first matching `CASE` block for a test expression. Cases can list exact values, ranges with `TO`, and comparisons with `IS`. `CASE ELSE` runs when no other case matches. `EXIT SELECT` jumps to the statement after `END SELECT`.

```basic
select case score
case 1 to 5
print "LOW"
case 6, 7, 8
print "MATCH"
case is > 10
print "HIGH"
case else
print "OTHER"
end select
```
