' MainWindowController.bas — the window, its toolbar, and every command.
'
'     toolbar Greet / Greeting ▸ Greet ──► Greet ──► the banner
'     toolbar Quit  / File ▸ Quit / Esc ──► Quit ──► the app stops
'     a language picked                ──► PickLanguage ──► the status line
'
' It is the only part that knows both the words (models/) and the screen
' (views/). Each command is one method, which the toolbar and the menu both
' reach through the same handler.
'
' Where this differs from the Swift TUI starters, because BASIC's TUIKit
' classes cannot do it yet: a toolbar item cannot be grayed out, so Greet
' stays enabled with no name typed and says what to do instead.

/// The window and its toolbar, over the app's view and status line.
///
/// It works on `theApp`, `theGreetingView` and `theStatusLine`, the parts
/// main.bas makes (see there for why they are GLOBALs). Every control names
/// a plain FUNCTION as its handler (the handlers at the end of this file),
/// because TUIKit calls a handler by name and a method has none it can
/// call. Each handler hands its command to `theWindow`, this controller.
CLASS MainWindowController
    /// The shell: the backdrop that holds the menu bar and the status line.
    PUBLIC Shell AS VARIANT
    /// The window in front of it.
    PUBLIC Window AS VARIANT
    /// What the status line said last, printed once the program ends.
    PUBLIC LastStatus AS STRING

    /// Builds the shell, the menu bar, the status line and the window.
    ///
    /// - Parameter title: The window's title: the app's name.
    /// - Parameter languages: The languages to list.
    FUNCTION Start(title AS STRING, languages AS LanguageList) AS VOID
        ' The shell first: menus across the top, status along the bottom.
        ME.Shell = TUIShell()
        ' Esc in the shell itself quits too, through the same Quit.
        ME.Shell.onquit("QuitPressed")
        ME.Shell.add(BuildMenuBar())
        ME.Shell.add(theStatusLine.Build())

        ' Then the window, with its toolbar and the view inside.
        ME.Window = TUIFloatWindow(title)
        ' Esc and the close box close the window; it is the app's only one,
        ' so closing it is Quit.
        ME.Window.onclose("QuitPressed")
        ME.BuildToolbar()
        ME.Window.add(theGreetingView.Build(languages))

        ' Who handles what.
        theGreetingView.Choices.onselect("LanguagePicked")
    END FUNCTION

    /// Makes the toolbar: Greet, then Quit.
    FUNCTION BuildToolbar() AS VOID
        LOCAL bar = TUIToolbar()
        ' "both" draws the symbol over the title, so nothing is a guess.
        bar.displaymode("both")
        bar.additem("Greet", ">", "GreetPressed")
        bar.divider()
        bar.additem("Quit", "x", "QuitPressed")
        ME.Window.toolbar(bar)
    END FUNCTION

    /// Shows the window and runs until Quit.
    FUNCTION Run() AS VOID
        theApp.present(ME.Window)
        theApp.run(ME.Shell)
    END FUNCTION

    /// The Greet command: greets the name in the field.
    FUNCTION Greet() AS VOID
        theGreetingView.Say(GreetingFor$(theGreetingView.TypedName$()))
    END FUNCTION

    /// A language was picked: the status line says which.
    FUNCTION PickLanguage() AS VOID
        ME.LastStatus = LanguageText$(theGreetingView.PickedLanguage$())
        theStatusLine.Show(ME.LastStatus)
    END FUNCTION

    /// The Quit command: stops the app, which ends Run.
    FUNCTION Quit() AS VOID
        theApp.stop()
    END FUNCTION
END CLASS

' ================================================================ handlers
'
' What each control and menu item calls. Each one hands its command to the
' controller, so a command is carried out in one place.

/// Greet, in the toolbar or the Greeting menu.
FUNCTION GreetPressed() AS VOID
    theWindow.Greet()
END FUNCTION

/// Quit, in the toolbar or the File menu.
FUNCTION QuitPressed() AS VOID
    theWindow.Quit()
END FUNCTION

/// A language was picked in the list.
FUNCTION LanguagePicked() AS VOID
    theWindow.PickLanguage()
END FUNCTION
