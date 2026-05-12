# NEW Operator

![BASICStudio](https://img.shields.io/badge/BASICStudio-supported-brightgreen) ![Shell](https://img.shields.io/badge/Shell-supported-brightgreen)

Creates a default instance of a `CLASS`. Constructor arguments are not supported yet, but empty parentheses are accepted.

```basic
class Report
    Title as string
end class

dim report as Report
report = new Report
report.Title = "Status"
print report.Title
```
