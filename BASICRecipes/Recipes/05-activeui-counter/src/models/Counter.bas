' Counter.bas — the count, and nothing else.
'
' Plain BASIC: it knows nothing of windows, so the same counter works in a
' program with no screen at all.

/// A count that goes up one at a time and back to zero.
CLASS Counter
    /// How many times it has been counted.
    PUBLIC Value AS INTEGER

    /// Counts one more.
    FUNCTION Increment() AS VOID
        ME.Value = ME.Value + 1
    END FUNCTION

    /// Goes back to zero.
    FUNCTION Reset() AS VOID
        ME.Value = 0
    END FUNCTION

    /// Whether there is anything to reset.
    ///
    /// - Returns: TRUE once the count is above zero.
    FUNCTION CanReset() AS BOOLEAN
        IF ME.Value > 0 THEN RETURN TRUE
        RETURN FALSE
    END FUNCTION
END CLASS
