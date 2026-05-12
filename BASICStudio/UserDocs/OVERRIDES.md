# OVERRIDES Modifier

![BASICStudio](https://img.shields.io/badge/BASICStudio-supported-brightgreen) ![Shell](https://img.shields.io/badge/Shell-supported-brightgreen)

Marks a class method as replacing an inherited method. A method with the same name as an inherited method must use `OVERRIDES`.

```basic
class FancyReport
    inherits Report

    overrides function Summary$() as string
        return ME.Title + " READY"
    end function
end class
```
