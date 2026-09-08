' sprite.bas — a BASIC class, compiled by basicc into a real Swift class.
'
' Build it with the Rev 2 compiler and Swift sees an ordinary open class: it
' can hold one, call its methods, and inherit from it. There is no wrapper
' object and no bridge — the pointer Swift holds IS the object BASIC
' allocated, with metadata basicc emitted.
'
'   basicc swift-class sprite.bas -o Build
'
' See run.sh, which builds this together with a Swift program that
' subclasses it.

CLASS Sprite
    PUBLIC X AS DOUBLE
    PUBLIC Y AS DOUBLE

    ' No AS clause, so these return nothing — Swift sees them as
    ' `func SetX(_ v: Double)`.
    FUNCTION SetX(v AS DOUBLE)
        ME.X = v
    END FUNCTION

    FUNCTION SetY(v AS DOUBLE)
        ME.Y = v
    END FUNCTION

    ' These land in the class's vtable, so a Swift subclass can override
    ' them and BASIC's own callers reach the override.
    FUNCTION Area() AS DOUBLE
        RETURN ME.X * ME.Y
    END FUNCTION

    FUNCTION Perimeter() AS DOUBLE
        RETURN 2 * ME.X + 2 * ME.Y
    END FUNCTION
END CLASS
