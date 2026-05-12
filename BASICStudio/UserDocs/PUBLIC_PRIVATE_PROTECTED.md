# PUBLIC PRIVATE PROTECTED Modifiers

![BASICStudio](https://img.shields.io/badge/BASICStudio-supported-brightgreen) ![Shell](https://img.shields.io/badge/Shell-supported-brightgreen)

Controls field and method visibility in class bodies.

`PUBLIC` members are visible anywhere.
`PRIVATE` members are visible only inside the declaring class.
`PROTECTED` members are visible inside the declaring class and derived classes.

```basic
class Vault
    private Code as string

    function Reveal$() as string
        return ME.Code
    end function
end class
```
