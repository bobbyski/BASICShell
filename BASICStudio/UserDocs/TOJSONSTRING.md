# ToJsonString() Function

![BASICStudio](https://img.shields.io/badge/BASICStudio-supported-brightgreen) ![BASICShell](https://img.shields.io/badge/BASICShell-supported-brightgreen)

Converts a BASIC value to a JSON string. The second argument controls pretty printing.

Records and classes use opt-in JSON fields. Add `JSON NAME "fieldName"` after a field type to include that field in the payload with a case-sensitive JSON name. Fields without JSON metadata are excluded.

```basic
class FancyReport
    public Badge as string json name "badge" = "defaultBadge"
    public localOnly as integer = 0
end class

dim report as FancyReport
report = new FancyReport()
print ToJsonString(report, false)
```

```basic
dim payload as dictionary
payload("name") = "Ada"
payload("missing") = NULL
print ToJsonString(payload, true)
```
