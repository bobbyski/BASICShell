#!/usr/bin/env BASICShell
' Contact Book - a windowed BASIC program, in six files.
'
'   basicshell basicPrograms/demos/apps/contacts.basproj/main.bas
'
' WHAT IT DOES
'
' Keeps an address book in a JSON file. Open and Save are on the toolbar
' and in the File menu; the list on the left picks a contact, the form on
' the right edits it, and quitting with unsaved edits asks Save, Discard or
' Cancel before it goes.
'
' WHAT IT IS FOR
'
' This is a starter project, so it is also an argument about how to write
' BASIC. The language got its reputation from programs that were one file,
' one flat run of statements, and a GOTO every time a decision was made.
' None of that is required, and none of it is here:
'
'   * No GOTO and no GOSUB. Every decision is IF/END IF or SELECT CASE,
'     and every piece of work is a FUNCTION with a name that says what it
'     does. You can read any one of them without reading the others.
'
'   * Six files, not one. IMPORT brings them together, and each file is
'     about one thing, so "where does saving happen?" has an answer you can
'     point at rather than search for.
'
'   * The model does not know about the screen. ContactModel.bas could be
'     used by a program that prints a report and never opens a window.
'
'   * State is named and shared on purpose, not by accident. Every GLOBAL
'     in the program is declared below, in one list, with a comment.
'
'   * Everything else is declared LOCAL, loop counters included. A name
'     that is not declared is shared with the whole program, so an
'     undeclared counter in one function silently overwrites a variable of
'     the same name in the function that called it. That is the oldest bug
'     in BASIC, and the fix is one word: LOCAL.
'
' THE FILES, in the order worth reading them:
'
'   main.bas            you are here - the shared state, and the start
'   ContactModel.bas    what a contact IS, and the list of them
'   ContactStorage.bas  the JSON file, in and out
'   ContactWindow.bas   the window: toolbar, list, edit form
'   ContactApp.bas      theme, menu bar, status strip, start-up
'   ContactDialogs.bas  the dialogs, and the unsaved-changes gate

' ---------------------------------------------------------------- the files
'
' IMPORT reads another file's FUNCTIONs and TYPEs into this program. Paths
' are relative to this file, so the program runs from any directory.
'
' The order does not matter to BASIC - a function may call one that is
' imported further down - so these are listed in reading order instead.
IMPORT "ContactModel.bas"
IMPORT "ContactStorage.bas"
IMPORT "ContactWindow.bas"
IMPORT "ContactApp.bas"
IMPORT "ContactDialogs.bas"

' ----------------------------------------------------------------- the state
'
' Every GLOBAL the program has is HERE, and that is not a preference:
' functions cross the IMPORT boundary but state does not, so a GLOBAL
' declared inside an imported file cannot be seen by the file that imported
' it. Shared state has to be declared in the entry file to be shared at all.
'
' The list is short, and that is also on purpose. Anything only one
' function needs is a LOCAL inside that function.

' The book. This BASIC has no REDIM, so the array is DIMmed once at its
' largest and ContactCount says how much of it is real - the traditional
' arrangement, and the reason every function that takes a row number checks
' it against ContactCount first.
GLOBAL MaxContacts = 199
GLOBAL Contacts(199) AS Contact
GLOBAL ContactCount = 0

' Which contact the form is editing, or -1 for none. Held here rather than
' asked of the list, because a list that has just been refilled has no
' selection yet and the form still has to know what it is showing.
GLOBAL EditingRow = -1

' Are there edits that are not in the file? Set by the model, displayed as
' the asterisk in the window title, and asked about before quitting.
GLOBAL IsDirty = 0

' The file the book came from, and the file Save writes back to.
GLOBAL CurrentPath$ = "contacts.json"

' What the status strip says: the last thing that happened, good or bad.
' Failures are reported here instead of stopping the program.
GLOBAL LastMessage$ = ""

' What the unsaved-changes dialog is waiting to do - "quit", "open", or ""
' for nothing. See ContactDialogs.bas.
GLOBAL PendingAction$ = ""

' The application and its shell. TUIApp() is the run loop; everything the
' program shows lives inside the shell or in a window in front of it.
GLOBAL app = TUIApp()
GLOBAL shell AS VARIANT

' The controls the handlers reach for after the window is built. A handler
' is a named function with no arguments, so the controls it touches have to
' be findable by name - which is what these are.
GLOBAL mainWindow AS VARIANT
GLOBAL contactList AS VARIANT
GLOBAL pathField AS VARIANT
GLOBAL fullNameField AS VARIANT
GLOBAL emailField AS VARIANT
GLOBAL phoneField AS VARIANT
GLOBAL notesField AS VARIANT
GLOBAL statusTitle AS VARIANT
GLOBAL statusHint AS VARIANT

' ----------------------------------------------------------------- the start
'
' One call. Everything else is in ContactApp.bas, where it can be read as
' one piece: build the shell, dress it, load the book, show the window, run.
RunContactBook()
