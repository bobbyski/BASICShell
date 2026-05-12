# CLASS Statement

![BASICStudio](https://img.shields.io/badge/BASICStudio-supported-brightgreen) ![Shell](https://img.shields.io/badge/Shell-supported-brightgreen)

Defines a simple object type. Phase I supports public fields, optional `PUBLIC`, `IMPLEMENTS`, `NEW ClassName`, `NEW ClassName()`, and dotted field access.

```basic
interface Printable
    function Title() as string
end interface

class Report
    implements Printable
    public Title as string
    Count as integer
end class

dim report as Report
report = new Report()
report.Title = "Status"
report.Count = 12

print report.Title
print report.Count
```
