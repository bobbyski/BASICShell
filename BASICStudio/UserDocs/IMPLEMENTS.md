# IMPLEMENTS Statement And Modifier

![BASICStudio](https://img.shields.io/badge/BASICStudio-supported-brightgreen) ![Shell](https://img.shields.io/badge/Shell-supported-brightgreen)

Inside a class body, `IMPLEMENTS InterfaceName` declares that the class satisfies an interface.

A method can also use an explicit implementation mapping when its BASIC name differs from the interface member name.

```basic
interface Printable
    function ToText$() as string
end interface

class Report
    implements Printable
    public Title as string

    function Text$() as string implements Printable.ToText$
        return ME.Title
    end function
end class
```
