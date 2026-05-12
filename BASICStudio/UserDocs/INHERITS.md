# INHERITS Statement

![BASICStudio](https://img.shields.io/badge/BASICStudio-supported-brightgreen) ![Shell](https://img.shields.io/badge/Shell-supported-brightgreen)

Declares a base class for a class. The derived class receives inherited public/protected fields and inherited methods. A derived method that replaces an inherited method must use `OVERRIDES`.

```basic
class Report
    public Title as string

    function Summary$() as string
        return ME.Title
    end function
end class

class FancyReport
    inherits Report
    public Badge as string

    overrides function Summary$() as string
        return ME.Title + " " + ME.Badge
    end function
end class

dim fancy as FancyReport
fancy = new FancyReport()
fancy.Title = "Phase2"
fancy.Badge = "OK"
print fancy.Summary$()
```
