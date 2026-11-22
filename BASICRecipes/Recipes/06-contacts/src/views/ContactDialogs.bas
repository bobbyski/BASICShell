' ContactDialogs.bas - the dialogs, and the unsaved-changes gate.
'
' The interesting one is the gate. Quitting and opening a different file
' both throw away edits, so both have to ask first, and asking is not a
' question a BASIC function can wait for an answer to: app.show puts the
' dialog up and returns immediately, and the answer arrives later as a call
' to whichever button's handler was pressed.
'
' That shape - ask now, continue later - is what PendingAction$ is for:
'
'   ConfirmFirst("quit")        remembers "quit", puts the dialog up
'   UnsavedSave                 saves, then does the remembered thing
'   UnsavedDiscard              does the remembered thing
'   UnsavedCancel               forgets it
'
' Written any other way this turns into a flag per command and a tangle of
' IFs. One remembered action, three buttons, one function that carries it
' out - and adding a fifth command that discards edits means adding one
' CASE below, not another dialog.

/// Runs an action, or asks about unsaved edits and runs it afterwards.
///
/// action$ is a name this file understands: "quit" or "open". Anything that
/// can lose edits should come through here.
///
/// - Parameter action$: The action to run: "quit" or "open".
/// - Returns: 1 when it ran the action now, 0 when it put the dialog up.
FUNCTION ConfirmFirst(action$ AS STRING) AS INTEGER
    IF NOT IsDirty THEN
        ' Nothing to lose: do it now, and never put up a dialog that has
        ' only one sensible answer. A program that asks needlessly trains
        ' people to dismiss its questions without reading them.
        PendingAction$ = action$
        PerformPendingAction()
        RETURN 1
    END IF

    ' Remember the action for whichever button is pressed, then ask.
    PendingAction$ = action$

    LOCAL ask = TUIDialog("Unsaved Changes")
    ask.message("You have unsaved changes to " + CurrentPath$ + "." + CHR$(10) + "Save them before you " + action$ + "?")

    ' The first button added is the default and takes the focus, so the
    ' order here is a decision, not a list: Enter saves. Cancel is last,
    ' because the safe-but-useless answer should not be the easy one.
    ask.addbutton("Save", "UnsavedSave")
    ask.addbutton("Discard", "UnsavedDiscard")
    ask.addbutton("Cancel", "UnsavedCancel")

    app.show(ask)
    RETURN 0
END FUNCTION

/// The dialog's Save button: saves, then does the remembered action.
///
/// - Returns: Always 0.
FUNCTION UnsavedSave() AS VARIANT
    IF NOT SaveContacts(CurrentPath$) THEN
        ' The save failed and said why in LastMessage$. The remembered
        ' action is dropped: quitting now would throw away the edits the
        ' person just asked to keep.
        PendingAction$ = ""
        RefreshEverything()
        RETURN 0
    END IF

    ' Saved: the edits are safe, so the remembered action can go ahead.
    PerformPendingAction()
    RETURN 0
END FUNCTION

/// The dialog's Discard button: does the remembered action, losing the edits.
///
/// - Returns: Always 0.
FUNCTION UnsavedDiscard() AS VARIANT
    ' Discarding is only a decision about the edits; the action itself is
    ' the one that was already asked for.
    IsDirty = 0
    PerformPendingAction()
    RETURN 0
END FUNCTION

/// The dialog's Cancel button: forgets the remembered action.
///
/// - Returns: Always 0.
FUNCTION UnsavedCancel() AS VARIANT
    ' Nothing is saved, nothing is lost, and the status line says so.
    PendingAction$ = ""
    LastMessage$ = "canceled - nothing was saved or lost"
    RefreshEverything()
    RETURN 0
END FUNCTION

/// Carries out whatever was waiting on the dialog, and forgets it.
///
/// SELECT CASE rather than a chain of IFs: one statement says "these are all
/// the things that can be waiting", and an unknown name falls into CASE ELSE
/// instead of quietly doing nothing.
///
/// - Returns: 1 when an action was carried out, 0 when nothing was waiting.
FUNCTION PerformPendingAction() AS INTEGER
    ' Forget the action before doing it, so it can never run twice.
    LOCAL action$ = PendingAction$
    PendingAction$ = ""

    SELECT CASE action$
        CASE "quit"
            app.stop()
            RETURN 1

        CASE "open"
            LoadContacts(pathField.value$())
            RefreshEverything()
            RETURN 1

        CASE ELSE
            ' Nothing was pending. Reached when a dialog is dismissed by
            ' Esc rather than by a button, which is a normal thing to do.
            RETURN 0
    END SELECT
END FUNCTION

' ------------------------------------------------------------------ About

/// Puts up the About dialog.
///
/// - Returns: Always 0.
FUNCTION ShowAbout() AS VARIANT
    LOCAL about = TUIDialog("About Contact Book")
    about.message("A contact book in BASIC, on TUIKit." + CHR$(10) + CHR$(10) + "Contacts are held in a JSON file you can open in any editor. Seven source files in models, views and app, no GOTO, and every handler is a named FUNCTION." + CHR$(10) + CHR$(10) + "Reading order: main.bas, models/ContactModel.bas, models/ContactStorage.bas, views/ContactWindow.bas, app/ContactApp.bas, views/ContactDialogs.bas, app/DataFolder.bas.")
    about.addbutton("Close", "AboutClosed")
    app.show(about)
    RETURN 0
END FUNCTION

/// The About dialog's Close button.
///
/// - Returns: Always 0.
FUNCTION AboutClosed() AS VARIANT
    ' A dialog button needs a handler even when there is nothing to do:
    ' without one the button still dismisses, but naming the function is
    ' where a "don't show this again" would go later.
    RETURN 0
END FUNCTION
