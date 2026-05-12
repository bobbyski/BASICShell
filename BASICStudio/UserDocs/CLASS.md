# CLASS Statement

![BASICStudio](https://img.shields.io/badge/BASICStudio-supported-brightgreen) ![Shell](https://img.shields.io/badge/Shell-supported-brightgreen)

Defines an object type. Classes support public/private/protected fields and methods, `IMPLEMENTS`, `INHERITS`, `OVERRIDES`, `NEW ClassName`, `NEW ClassName()`, and dotted field/method access. `ME` refers to the current object inside a method.

```basic
interface Printable
    function Title() as string
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
end class

class FancyReport
    inherits Report
    public Badge as string

    overrides function Summary$() as string
        return ME.Title + " " + ME.Badge
    end function
end class

dim report as Report
report = new Report()
report.Title = "Status"
report.Count = 12

print report.Title
print report.Title()
print report.Summary$()
print report.Count

dim fancy as FancyReport
fancy = new FancyReport()
fancy.Title = "Phase2"
fancy.Badge = "OK"
print fancy.Summary$()
```
