' {{NAME}} — the click counter, in a window of its own made with ActiveUI.
'
' Run it in BASICStudio: the window is the program's, opening beside
' Studio's, and the program runs until it closes. (BASICShell and basicc
' have no windows, and say so.)
'
' ActiveUI's smallest complete app: a label that counts, and a button.
' Press Click me and the count goes up.
'
' The button names the FUNCTION that handles it: clickButton.onclick("Clicked").
' A handler is always a named FUNCTION, not a closure, because a closure's
' changes would not get out of it. win.run() shows the window and waits,
' running handlers as you work, until the window closes.
'
' The same app as Swift's ActiveUI Click Counter, and where it differs:
' - Swift's label pulls its text from a closure, and the button asks it to
'   pull again. Here the handler sets the label's text: the same result,
'   pushed rather than pulled.
' - Swift's label is in the headline font. BASIC's AUILabel sets text only.
' - Swift's stack holds the label and button at their own widths. A BASIC
'   window's column fills its width, so the button is as wide as the window.
' - Swift gives the app a menu bar: the app menu, File ▸ Quit (⌘Q), Edit
'   and Window. A BASIC program's ActiveUI window has no menus of its own
'   yet; closing the window ends the program, and Studio's menus stay.

' How many times the button has been pressed.
GLOBAL clicks AS INTEGER

GLOBAL win = AUIWindow("{{NAME}}")
GLOBAL countLabel = AUILabel("Count: 0")

' The window, top to bottom: the count, then the button.
LET clickButton = AUIButton("Click me")
win.add(countLabel)
win.add(clickButton)

' Who handles what.
clickButton.onclick("Clicked")

' Swift's window is 320 by 200 points.
win.size(320, 200)
win.run()

' ================================================================= handlers

' Click me: one more, and the label says so. STR$ puts a space in front of
' a number, which is the one after "Count:".
FUNCTION Clicked()
    clicks = clicks + 1
    countLabel.text("Count:" + STR$(clicks))
END FUNCTION
