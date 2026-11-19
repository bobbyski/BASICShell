' StatusLine.bas — the line along the bottom of the screen.
'
'     Language: BASIC

/// The status line: what was picked last.
CLASS StatusLine
    /// The label the status is written in.
    PUBLIC StatusLabel AS VARIANT

    /// Makes the status strip, along the bottom of the shell.
    ///
    /// - Returns: The strip, for the shell to hold.
    FUNCTION Build() AS VARIANT
        ME.StatusLabel = TUILabel("No language picked yet.")
        LOCAL strip = TUIStatus()
        strip.addsegment(ME.StatusLabel, 0, 100)
        RETURN strip
    END FUNCTION

    /// Shows a status.
    ///
    /// - Parameter message: What to show.
    FUNCTION Show(message AS STRING) AS VOID
        ME.StatusLabel.text(message)
    END FUNCTION
END CLASS
