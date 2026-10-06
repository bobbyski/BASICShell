' ContactStorage.bas - the JSON file, in and out.
'
' Two functions do the work, LoadContacts and SaveContacts, and both answer
' 1 for success and 0 for failure rather than stopping the program. Between
' them sits one rule worth stating out loud:
'
'   CHECK BEFORE YOU OPEN.
'
' BASIC's only error trap is ON ERROR GOTO, and a trap is a poor fit for a
' windowed program: the label it jumps to is somewhere else, and the window
' it jumped out of is still on the screen. Every failure this program can
' have is one it can ask about first - does the file exist, does the folder
' exist - so it asks, reports in the status strip, and carries on. No GOTO,
' and no run that ends in a stack of red text over the desktop.

' The folder part of a path: everything before the last "/".
'
' Answers "." for a bare file name, because "the folder of contacts.json"
' is the current directory and the caller should not have to special-case
' it. MID$ walks backwards rather than using a search function, since the
' last separator is the one that matters and INSTR finds the first.
FUNCTION FolderOf$(path AS STRING) AS STRING
    LOCAL at = LEN(path)
    WHILE at > 0
        IF MID$(path, at, 1) = "/" THEN
            ' A leading "/" means the root folder, which is "/" and not "".
            IF at = 1 THEN
                RETURN "/"
            END IF
            RETURN LEFT$(path, at - 1)
        END IF
        at = at - 1
    WEND
    RETURN "."
END FUNCTION

' Can this path be written to? Checks the name and the folder, not the file.
'
' The file itself is allowed not to exist - that is what Save As does. What
' must exist is somewhere to put it.
FUNCTION PathIsWritable(path AS STRING) AS INTEGER
    IF path = "" THEN
        LastMessage$ = "no file name - type one in the toolbar"
        RETURN 0
    END IF

    LOCAL folder$ = FolderOf$(path)
    IF NOT FILEEXISTS(folder$) THEN
        LastMessage$ = "no folder called " + folder$
        RETURN 0
    END IF
    RETURN 1
END FUNCTION

' The book as one value, ready for the JSON writer.
'
' People(*) is a growable array and Contacts() is a fixed one with a count,
' so the two cannot be handed straight across: staging is DIMmed to exactly
' the contacts that are real and assigned whole. DIM takes an expression,
' which is what makes "exactly this many" possible.
FUNCTION BookSnapshot() AS VARIANT
    LOCAL book AS ContactBook
    book.Version = 1

    IF ContactCount = 0 THEN
        ' An empty book writes {"version":1} and reads back as no contacts,
        ' which is the right answer for a file someone emptied on purpose.
        RETURN book
    END IF

    DIM staging(ContactCount - 1) AS Contact
    LOCAL row
    FOR row = 0 TO ContactCount - 1
        staging(row) = Contacts(row)
    NEXT row

    book.People = staging
    RETURN book
END FUNCTION

' Writes the book to a JSON file. Answers 1 when it wrote.
FUNCTION SaveContacts(path AS STRING) AS INTEGER
    IF NOT PathIsWritable(path) THEN
        RETURN 0
    END IF

    LOCAL book AS ContactBook
    book = BookSnapshot()

    ' File(name, access, type, requireNew) and writeJson(value, pretty).
    ' Pretty is on because a contact book is a file a person might open in
    ' an editor, and a format nobody can read is a format nobody checks.
    LOCAL writer = File()
    writer.open(path, WRITE, JSON, false)
    writer.writeJson(book, true)
    writer.close

    CurrentPath$ = path
    IsDirty = 0
    LastMessage$ = "saved " + Number$(ContactCount) + " contacts to " + path
    RETURN 1
END FUNCTION

' Reads a JSON file into the book, replacing what was there.
'
' The caller is responsible for asking about unsaved edits FIRST - see
' ContactDialogs.bas. This function is the part that has no opinion.
FUNCTION LoadContacts(path AS STRING) AS INTEGER
    IF path = "" THEN
        LastMessage$ = "no file name - type one in the toolbar"
        RETURN 0
    END IF

    IF NOT FILEEXISTS(path) THEN
        LastMessage$ = "no file called " + path
        RETURN 0
    END IF

    LOCAL reader = File(path, READ, JSON, false)
    LOCAL book AS ContactBook
    book = reader.json()
    reader.close

    ' Nothing is disturbed until the file has been read, so a file that
    ' turns out to be unreadable leaves the book you already had.
    ResetContacts()

    LOCAL loaded = LEN(book.People)
    IF loaded > MaxContacts + 1 THEN
        ' More contacts than the array holds: take what fits and say so,
        ' rather than writing past the end.
        LastMessage$ = "file holds " + Number$(loaded) + " contacts; reading the first " + Number$(MaxContacts + 1)
        loaded = MaxContacts + 1
    ELSE
        LastMessage$ = "opened " + path
    END IF

    LOCAL row
    FOR row = 0 TO loaded - 1
        Contacts(row) = book.People(row)
    NEXT row
    ContactCount = loaded

    CurrentPath$ = path
    IsDirty = 0
    RETURN 1
END FUNCTION
