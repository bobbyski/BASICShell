' {{NAME}} — a full-screen TUIKit application.
'
' Run it in a terminal: a window with a menu bar, a field, a list and
' buttons. Tab moves between controls, Enter presses one, and the File
' menu (Alt-F, then Q) closes the application.

GLOBAL app = TUIApp()
GLOBAL banner = TUILabel("Tab to move, Enter to press.")
GLOBAL who = TUIField("your name")
GLOBAL picks = TUIList()
GLOBAL report$ = ""

LET win = TUIWindow()

' `&` marks the mnemonic, here and everywhere in TUIKit.
LET bar = TUIMenu()
bar.menu("&File")
bar.item("&Quit", "Quit")
win.add(bar)

LET page = TUIStack("v")
page.add(banner)
page.add(TUILabel("Type a name, then press Greet"))
page.add(who)

picks.additem("BASIC")
picks.additem("Swift")
picks.onselect("Picked")
page.add(picks)

LET row = TUIStack("h")
LET greet = TUIButton("Greet")
greet.onclick("Greet")
LET done = TUIButton("Quit")
done.onclick("Quit")
row.add(greet)
row.add(done)
page.add(row)

win.add(page)

app.run(win)

PRINT "{{NAME}} closed."
IF report$ <> "" THEN PRINT report$

FUNCTION Greet()
  IF who.value$() = "" THEN
    banner.text("Type a name in the field first.")
  ELSE
    banner.text("Hello, " + who.value$() + "!")
  END IF
END FUNCTION

FUNCTION Picked()
  banner.text("Language: " + picks.selectedtext$())
END FUNCTION

FUNCTION Quit()
  report$ = "Last status: " + banner.value$()
  app.stop()
END FUNCTION
