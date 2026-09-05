' RichSwift from a compiled program: markdown, a panel, a table, a bar.
'
' ANSI is turned off on every object so the comparison is the text, not the
' terminal: a colour escape depends on where the output is going, and both
' engines are being asked the same question here.
LET md = RichMarkdown()
md.width(60)
md.ansi(FALSE)
PRINT md.render$("# Title" + CHR$(10) + CHR$(10) + "Some **bold** text.")
LET panel = RichPanel()
panel.width(40)
panel.ansi(FALSE)
PRINT panel.render$("Panel body", "A Title")
LET t = RichTable()
t.ansi(FALSE)
t.width(40)
t.column("Suite")
t.column("Tests")
t.addrow("BASICCore", 395)
PRINT t.render$()
LET bar = RichProgress()
bar.ansi(FALSE)
bar.width(30)
bar.label("Building")
bar.value(40)
PRINT bar.render$()
