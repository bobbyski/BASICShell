# VIRTUAL Modifier

![BASICStudio](https://img.shields.io/badge/BASICStudio-supported-brightgreen) ![BASICShell](https://img.shields.io/badge/BASICShell-supported-brightgreen)

Marks a method that a derived class is allowed to replace. The replacement says `OVERRIDES`.

```basic
class Animal
    virtual function Speak$() as string
        return "..."
    end function
end class

class Dog
    inherits Animal
    overrides function Speak$() as string
        return "woof"
    end function
end class

dim d as Dog
print d.Speak$()
```

prints `woof`, while an `Animal` still answers `...`.

See [INHERITS](INHERITS.md) for the rest of what a derived class gets, and [PUBLIC, PRIVATE, PROTECTED](PUBLIC_PRIVATE_PROTECTED.md) for who can see it.
