' ContactApp.bas - the application: theme, menu bar, status strip, start-up.
'
' A TUIKit program is three things put together: an application (the run
' loop), a shell (the backdrop that owns the menu row and the status row),
' and windows that float in front of it. This file assembles all three and
' then hands control to app.run, which does not come back until something
' calls app.stop.
'
' The layout is OmegaCLIDE's, and it is worth copying: menus across the
' top, desktop in the middle, one line of status along the bottom.

/// Builds everything and runs.
///
/// Called from main.bas, and the only function in this program that blocks.
/// The book lives in contacts.json in the app's data folder:
/// ~/Library/Application Support/Contact Book, or $APP_DATA_DIR when that
/// is set (see DataFolder.bas).
///
/// - Returns: 0, once the program has quit.
FUNCTION RunContactBook() AS VARIANT
    ' Where the book lives, settled first: the toolbar's file field and the
    ' starting book both read CurrentPath$. An imported file's top-level
    ' statements never run, so this is set here rather than beside the
    ' GLOBAL. DataFolder$ makes the folder, so Save can write straight away.
    CurrentPath$ = DataFolder$("Contact Book") + "/contacts.json"

    shell = TUIShell()

    ' Esc quits from anywhere in a TUIKit shell. Left alone it stops the
    ' application outright, which would walk straight past the unsaved-
    ' changes dialog that File > Quit puts up - so Esc is pointed at the
    ' same gate. Three ways out of the program, one question asked.
    shell.onquit("RequestQuit")

    ' The menu bar next, so the shell knows which bar owns Esc while a
    ' dropdown is open: a menu is closed by Esc before the program is.
    shell.add(BuildMenuBar())

    ' The status strip: how many contacts on the left, what just happened
    ' in the middle. Both are plain labels that RefreshChrome rewrites, so
    ' the strip never has to be rebuilt.
    statusTitle = TUILabel(" 0 contacts")
    statusHint = TUILabel("")
    LOCAL strip = TUIStatus()
    strip.addsegment(statusTitle, 16)
    strip.addsegment(statusHint, 0, 100)
    shell.add(strip)

    ' Modern Turbo: the blue-and-white look this kit is named after. The
    ' theme is set before anything is presented, because a theme applied
    ' afterwards restyles controls that have already been drawn once.
    app.theme("Modern Turbo")
    StyleStatusStrip()

    ' The book, before the window: the window fills itself from the model
    ' when it refreshes, so the model has to be true first.
    LoadStartingBook()

    ' Show the window and fill it from the model.
    app.present(BuildContactWindow())
    RefreshEverything()

    ' The run loop: this line does not return until app.stop is called.
    app.run(shell)

    ' Anything printed while the app is up goes to a screen nobody can see -
    ' app.run owns the terminal until it returns. This is the first line
    ' after it returns, and so the first PRINT that can be read.
    PRINT "Contact Book closed. " + LastMessage$
    RETURN 0
END FUNCTION

/// Opens the default file when there is one, and seeds samples when not.
///
/// A starter program that begins with an empty list and no file teaches
/// nothing about either. This way the first run shows three contacts, the
/// second run shows whatever was saved. The default file is contacts.json
/// in the app's data folder, which RunContactBook puts in CurrentPath$.
///
/// - Returns: How many contacts the book starts with.
FUNCTION LoadStartingBook() AS INTEGER
    ' A saved book wins over the samples.
    IF FILEEXISTS(CurrentPath$) THEN
        LoadContacts(CurrentPath$)
        RETURN ContactCount
    END IF

    ' No file yet: seed the samples, and say where Save will put them.
    SeedSampleContacts()
    LastMessage$ = "new book - Save writes " + CurrentPath$
    RETURN ContactCount
END FUNCTION

/// Styles the status strip's labels from the theme.
///
/// The strip's labels take their colors from the theme by naming a role,
/// rather than by naming a color. Name a color and the strip stays that
/// color when the theme changes, which is how a themed program ends up
/// with one piece that does not match.
///
/// - Returns: Always 0.
FUNCTION StyleStatusStrip() AS INTEGER
    statusTitle.style("header")
    statusHint.style("headerplain")
    RETURN 0
END FUNCTION

' ------------------------------------------------------------ the menu bar

/// Builds the menu bar: File, Edit and Help.
///
/// Every menu item names a handler function, and each one calls exactly the
/// function the matching toolbar button calls. The menu is a second door
/// into the same room, not a second implementation.
///
/// "&" marks the Alt- mnemonic: "&Open..." is Alt-O.
///
/// - Returns: The menu bar, for the shell to add.
FUNCTION BuildMenuBar() AS VARIANT
    LOCAL bar = TUIMenu()

    ' Each bar.menu starts a menu; the items after it belong to it.

    bar.menu("&File")
    bar.item("&New Contact", "NewContactAction")
    bar.separator()
    bar.item("&Open...", "FileOpen")
    bar.item("&Save", "FileSave")
    bar.item("Save &As...", "FileSaveAs")
    bar.separator()
    bar.item("&Quit", "RequestQuit")

    bar.menu("&Edit")
    bar.item("&Apply Edits", "ApplyEdits")
    bar.item("&Revert Edits", "RevertEdits")
    bar.separator()
    bar.item("&Delete Contact", "DeleteContactAction")

    bar.menu("&Help")
    bar.item("&About Contact Book", "ShowAbout")

    RETURN bar
END FUNCTION

' ------------------------------------------------------------ the commands
'
' The four File commands. Each one is short because the deciding is done
' elsewhere: views/ContactDialogs.bas decides whether unsaved edits allow
' an Open, models/ContactStorage.bas decides whether a path can be written.

/// Open the file named in the toolbar - after asking about unsaved edits.
///
/// - Returns: Always 0.
FUNCTION FileOpen() AS VARIANT
    ' ConfirmFirst does not open anything. It either runs the action now,
    ' because there is nothing to lose, or puts up the Save / Discard /
    ' Cancel dialog and runs it later, or never. Either way this function
    ' is finished; see PerformPendingAction in views/ContactDialogs.bas.
    ConfirmFirst("open")
    RETURN 0
END FUNCTION

/// Save to the file that is open.
///
/// - Returns: Always 0.
FUNCTION FileSave() AS VARIANT
    SaveContacts(CurrentPath$)
    RefreshEverything()
    RETURN 0
END FUNCTION

/// Save to whatever the toolbar field says, and open that file from now on.
///
/// Save As and Save are one function apart, and the difference is only which
/// path they take - which is why CurrentPath$ is a variable and not a
/// constant buried in the save code.
///
/// - Returns: Always 0.
FUNCTION FileSaveAs() AS VARIANT
    SaveContacts(pathField.value$())
    RefreshEverything()
    RETURN 0
END FUNCTION

/// Quit - after asking about unsaved edits.
///
/// - Returns: Always 0.
FUNCTION RequestQuit() AS VARIANT
    ConfirmFirst("quit")
    RETURN 0
END FUNCTION
