' CounterWindowController.bas — the window, its Reset command, and each count.
'
'     Click me ──► Count      ──► Counter.Increment ──► Refresh
'     Reset    ──► ResetCount ──► Counter.Reset     ──► Refresh
'                                          Refresh ──► the label, Reset grayed at zero
'
' It is the only part that knows both the counter and the view. Each
' command is one method, and Reset is grayed out while the count is zero.
'
' Where this differs from Swift's Click Counter, because BASIC's ActiveUI
' classes cannot do it yet:
' - Reset is a button above the count, in the toolbar's place: an AUIWindow
'   has no toolbar.
' - There is no Counter menu: built with basicc, the program has the menu
'   bar every Mac app has (the app menu, File with Close and Quit, Edit,
'   Window), and BASIC cannot add to it yet. When it can, Counter ▸ Count
'   and Counter ▸ Reset name the same handlers the buttons name.
' - A BASIC window's column fills its width, so Click me is as wide as the
'   window, where Swift's keeps its own width.

/// The window and its Reset command, over the app's counter and view.
///
/// It works on `theCounter` and `theCounterView`, the parts main.bas makes
/// (see there for why they are GLOBALs). Every control names a plain
/// FUNCTION as its handler (the handlers at the end of this file), because
/// ActiveUI calls a handler by name and a method has none it can call. Each
/// handler hands its command to `theWindow`, this controller.
CLASS CounterWindowController
    /// The window.
    PUBLIC Window AS VARIANT
    /// Reset: back to zero.
    PUBLIC ResetButton AS VARIANT

    /// Builds the window, at zero.
    ///
    /// - Parameter title: The window's title: the app's name.
    FUNCTION Start(title AS STRING) AS VOID
        ' Top to bottom: the command, the count, the button.
        ME.Window = AUIWindow(title)
        ME.BuildCommands()
        theCounterView.Build(ME.Window)

        ' Who handles what.
        theCounterView.ClickButton.onclick("Clicked")

        ' Swift's window is 320 by 200 points.
        ME.Window.size(320, 200)

        ' A button starts enabled, and nothing asks again until the first
        ' count, so everything is brought up to date before the window
        ' opens: Reset starts grayed out, at zero.
        ME.Refresh()
    END FUNCTION

    /// Makes the Reset button, in the toolbar's place across the top.
    FUNCTION BuildCommands() AS VOID
        ME.ResetButton = AUIButton("Reset")
        ME.Window.add(ME.ResetButton)
        ME.ResetButton.onclick("ResetPressed")
    END FUNCTION

    /// Shows the window and waits until it is closed.
    FUNCTION Run() AS VOID
        ME.Window.run()
    END FUNCTION

    /// The Count command: one more.
    FUNCTION Count() AS VOID
        theCounter.Increment()
        ME.Refresh()
    END FUNCTION

    /// The Reset command: back to zero.
    FUNCTION ResetCount() AS VOID
        IF NOT theCounter.CanReset() THEN RETURN
        theCounter.Reset()
        ME.Refresh()
    END FUNCTION

    /// Shows the count, and grays Reset out at zero.
    FUNCTION Refresh() AS VOID
        theCounterView.Show(theCounter)
        ME.ResetButton.enabled(theCounter.CanReset())
    END FUNCTION
END CLASS

' ================================================================ handlers
'
' What each control calls. Each one hands its command to the controller,
' so a command is carried out in one place, whichever control asked.

/// Click me.
FUNCTION Clicked() AS VOID
    theWindow.Count()
END FUNCTION

/// Reset.
FUNCTION ResetPressed() AS VOID
    theWindow.ResetCount()
END FUNCTION
