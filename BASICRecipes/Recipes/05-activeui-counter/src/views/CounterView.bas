' CounterView.bas — the count, and the one button that is the app.
'
'     ┌──────────────┐
'     │   Count: 2   │   what the counter says
'     │  [Click me]  │   reports each press
'     └──────────────┘
'
' A view shows what it is given and reports what the person does. It never
' changes the count itself: the controller decides what a press means. The
' button stays a button because pressing it is the app; the app's command
' (Reset) is with the window's commands.

/// The count's label, and the Click me button under it.
CLASS CounterView
    /// The label that says the count.
    PUBLIC CountLabel AS VARIANT
    /// The button that counts.
    PUBLIC ClickButton AS VARIANT

    /// Makes the label and the button, and puts them in a window.
    ///
    /// Swift's label is in the headline font; BASIC's AUILabel sets text
    /// only, so it is in the window's own font.
    ///
    /// - Parameter window: The window to add them to, top to bottom.
    FUNCTION Build(window AS VARIANT) AS VOID
        ME.CountLabel = AUILabel("Count: 0")
        ME.ClickButton = AUIButton("Click me")
        window.add(ME.CountLabel)
        window.add(ME.ClickButton)
    END FUNCTION

    /// Shows the count.
    ///
    /// - Parameter counter: The counter to show.
    FUNCTION Show(counter AS Counter) AS VOID
        ME.CountLabel.text(CountText$(counter))
    END FUNCTION
END CLASS

/// What the label says about a counter.
///
/// - Parameter counter: The counter.
/// - Returns: Such as "Count: 2".
FUNCTION CountText$(counter AS Counter) AS STRING
    ' STR$ puts a space in front of a number, which is the one after "Count:".
    RETURN "Count:" + STR$(counter.Value)
END FUNCTION
