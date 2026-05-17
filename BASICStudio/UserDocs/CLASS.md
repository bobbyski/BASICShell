# CLASS Statement

![BASICStudio](https://img.shields.io/badge/BASICStudio-supported-brightgreen) ![Shell](https://img.shields.io/badge/Shell-supported-brightgreen)

Defines an object type. Classes support public/private/protected fields and methods, `IMPLEMENTS`, `INHERITS`, `OVERRIDES`, `NEW ClassName`, `NEW ClassName()`, and dotted field/method access. `ME` refers to the current object inside a method.

Fields may include literal defaults and opt-in JSON metadata. `JSON NAME "fieldName"` includes that field in `ToJsonString()` output with the given case-sensitive JSON name. Fields without JSON metadata are excluded from class JSON output.

Class fields can also use dynamic array ranks for JSON payloads. Use `(*)` for a one-dimensional array and `(*, *)` for nested JSON arrays.

```basic
interface Printable
    function Title() as string
    function ToText$() as string
end interface

class Report
    implements Printable
    public Title as string
    private InternalCode as string
    Count as integer

    function Title() as string
        return ME.Title
    end function

    function Summary$() as string
        return ME.Title + " READY"
    end function

    function Text$() as string implements Printable.ToText$
        return ME.Title
    end function
end class

class FancyReport
    inherits Report
    public Badge as string json name "badge" = "defaultBadge"
    public Scores(*) as integer json name "scores"
    public localOnly as integer = 0

    function New(title as string, badge as string)
        ME.Title = title
        ME.Badge = badge
    end function

    overrides function Summary$() as string
        return ME.Title + " " + ME.Badge
    end function

    function Rename$(title as string) as string
        ME.Title = title
        return ME.Title
    end function
end class

dim report as Report
report = new Report()
report.Title = "Status"
report.Count = 12

print report.Title
print report.Title()
print report.Summary$()
print report.Text$()
print report.Count

dim fancy as FancyReport
fancy = new FancyReport("Phase2", "OK")
print fancy.Summary$()
print fancy.Rename$("Phase2B")
print fancy.Summary$()
```
