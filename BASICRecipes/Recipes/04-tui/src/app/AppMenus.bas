' AppMenus.bas — the menu bar across the top of the screen.
'
'     File      Quit
'     Greeting  Greet
'
' Every menu item names the handler its toolbar button names, so a command
' is carried out in one place whichever way it is asked for.

/// The menu bar: File ▸ Quit, and Greeting ▸ Greet.
///
/// `&` marks the mnemonic, here and everywhere in TUIKit: Alt-F opens File.
///
/// - Returns: The menu bar, for the shell to hold.
FUNCTION BuildMenuBar() AS VARIANT
    LOCAL bar = TUIMenu()
    bar.menu("&File")
    bar.item("&Quit", "QuitPressed")
    bar.menu("&Greeting")
    bar.item("&Greet", "GreetPressed")
    RETURN bar
END FUNCTION
