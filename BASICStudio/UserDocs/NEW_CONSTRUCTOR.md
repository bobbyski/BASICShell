# NEW Constructor

![BASICStudio](https://img.shields.io/badge/BASICStudio-supported-brightgreen) ![Shell](https://img.shields.io/badge/Shell-supported-brightgreen)

Creates a class instance. If the class defines `function New(...)`, the constructor runs during object creation. Constructor functions default to `VOID`; set initial fields through `ME`.

```basic
class Report
    public Title as string

    function New(title as string)
        ME.Title = title
    end function
end class

dim report as Report
report = new Report("Initial")
print report.Title
```
