' ContactModel.bas - what a contact IS, and the list of them.
'
' There is not one window in this file, and that is the point. The model
' knows names, addresses and a dirty flag; it does not know that a list
' control exists. Everything here can be called from a program with no
' screen at all, which is what makes it the part you can trust.
'
' The rule this file follows, and the reason it is first in the tour:
' decide what the data is before you decide what it looks like.

/// A single contact.
///
/// JSON NAME gives each field the spelling it has in the file, so the BASIC
/// name and the file format can differ without a conversion step: FullName
/// is written as "name". A field with no JSON NAME is not written at all,
/// which is how you keep scratch state out of a saved file.
TYPE Contact
    /// The person's full name, written to the file as "name".
    FullName AS STRING JSON NAME "name" = ""
    /// The person's email address, written to the file as "email".
    Email AS STRING JSON NAME "email" = ""
    /// The person's phone number, written to the file as "phone".
    Phone AS STRING JSON NAME "phone" = ""
    /// Anything else worth remembering, written to the file as "notes".
    Notes AS STRING JSON NAME "notes" = ""
END TYPE

/// The whole file, as one value.
///
/// A RECORD can hold a growable array of TYPEs - People(*) - and the JSON
/// reader fills it in from the file, so loading is one call rather than a
/// parsing loop. Version is here because a format that cannot say what it is
/// cannot be changed later without guessing.
RECORD ContactBook
    /// Which version of the file format this is, written as "version".
    Version AS INTEGER JSON NAME "version" = 1
    /// Every contact in the file, written as "people".
    People(*) AS Contact JSON NAME "people"
END RECORD

' ---------------------------------------------------------------- the list
'
' Contacts() and ContactCount are GLOBALs in main.bas. This BASIC has no
' REDIM, so the array is DIMmed once at its largest and ContactCount says
' how much of it is real - the classic BASIC arrangement, and the reason
' every function here checks the bound before it writes.

/// Adds a contact and answers its row, or -1 when the book is full.
///
/// Answering -1 rather than stopping is deliberate: a full book is something
/// the caller can tell the person about, not a reason to lose the window.
///
/// - Parameter fullName: The new contact's full name.
/// - Parameter email: The new contact's email address.
/// - Parameter phone: The new contact's phone number.
/// - Parameter notes: The new contact's notes.
/// - Returns: The row the contact was added at, or -1 when the book is full.
FUNCTION AddContact(fullName AS STRING, email AS STRING, phone AS STRING, notes AS STRING) AS INTEGER
    ' A full book is reported, not written past.
    IF ContactCount > MaxContacts THEN
        RETURN -1
    END IF

    ' The new contact goes in the first unused row, after the last real one.
    LOCAL row = ContactCount
    Contacts(row).FullName = fullName
    Contacts(row).Email = email
    Contacts(row).Phone = phone
    Contacts(row).Notes = notes
    ContactCount = ContactCount + 1
    IsDirty = 1
    RETURN row
END FUNCTION

/// Writes edited values back over one row. Answers 1 when it wrote.
///
/// - Parameter row: The row to write over.
/// - Parameter fullName: The contact's full name.
/// - Parameter email: The contact's email address.
/// - Parameter phone: The contact's phone number.
/// - Parameter notes: The contact's notes.
/// - Returns: 1 when it wrote, 0 when there is no contact in that row.
FUNCTION UpdateContact(row AS INTEGER, fullName AS STRING, email AS STRING, phone AS STRING, notes AS STRING) AS INTEGER
    IF NOT ContactExists(row) THEN
        RETURN 0
    END IF

    Contacts(row).FullName = fullName
    Contacts(row).Email = email
    Contacts(row).Phone = phone
    Contacts(row).Notes = notes
    IsDirty = 1
    RETURN 1
END FUNCTION

/// Removes one row, closing the gap behind it. Answers 1 when it removed.
///
/// The loop copies each later contact down one place. A TYPE assigns whole:
/// one statement moves all four fields, so this is the same code it would be
/// for a book with forty fields per person.
///
/// - Parameter row: The row to remove.
/// - Returns: 1 when it removed, 0 when there is no contact in that row.
FUNCTION RemoveContact(row AS INTEGER) AS INTEGER
    IF NOT ContactExists(row) THEN
        RETURN 0
    END IF

    ' Each contact after the removed one moves up a row; the last row is
    ' left behind as a copy, and the shorter count stops it being real.
    LOCAL later
    FOR later = row TO ContactCount - 2
        Contacts(later) = Contacts(later + 1)
    NEXT later

    ContactCount = ContactCount - 1
    IsDirty = 1
    RETURN 1
END FUNCTION

/// Is there a contact in this row? Asked by everything that takes a row.
///
/// A list control answers -1 when nothing is selected, so "is this a real
/// row?" is a question every handler has to ask, and it should be spelled
/// one way in one place.
///
/// - Parameter row: The row to ask about; -1 means nothing is selected.
/// - Returns: 1 when the row holds a contact, 0 when it does not.
FUNCTION ContactExists(row AS INTEGER) AS INTEGER
    ' Below the first row: nothing selected.
    IF row < 0 THEN
        RETURN 0
    END IF
    ' Past the last real row: left over, or never used.
    IF row >= ContactCount THEN
        RETURN 0
    END IF
    RETURN 1
END FUNCTION

/// Empties the book. Used by Open before it reads a file in.
///
/// - Returns: Always 0.
FUNCTION ResetContacts() AS INTEGER
    ' No rows are real, none is being edited, and nothing is unsaved.
    ContactCount = 0
    EditingRow = -1
    IsDirty = 0
    RETURN 0
END FUNCTION

/// One row of the list, as the person reading it wants to see it.
///
/// Presentation, but not a view: it makes a STRING, and a string is
/// something a list, a report or a PRINT can all take. That is the seam -
/// the model formats text, the window decides where text goes.
///
/// - Parameter row: The row to describe.
/// - Returns: The name, with the email address after it in angle brackets
///   when there is one, or "" when there is no contact in that row.
FUNCTION ContactRow$(row AS INTEGER) AS STRING
    IF NOT ContactExists(row) THEN
        RETURN ""
    END IF

    ' A contact with no name still needs something to click on.
    LOCAL shown$ = Contacts(row).FullName
    IF shown$ = "" THEN
        shown$ = "(no name)"
    END IF

    IF Contacts(row).Email <> "" THEN
        shown$ = shown$ + "  <" + Contacts(row).Email + ">"
    END IF
    RETURN shown$
END FUNCTION

/// Three contacts, so a first run has something to click on.
///
/// Only called when there is no file to open. A starter project that opens
/// empty teaches nothing about the list, the form, or the dirty flag.
///
/// - Returns: How many contacts the book holds afterward.
FUNCTION SeedSampleContacts() AS INTEGER
    AddContact("Ada Lovelace", "ada@example.com", "555-0100", "Wrote the first program.")
    AddContact("Grace Hopper", "grace@example.com", "555-0101", "Found the first bug.")
    AddContact("Katherine Johnson", "katherine@example.com", "555-0102", "Checked the computer's math by hand.")

    ' Sample data is not an edit: the book matches nothing on disk, but
    ' there is nothing on disk to match, and starting up with the quit
    ' dialog already armed would be a lie.
    IsDirty = 0
    RETURN ContactCount
END FUNCTION

/// A number as text, with no gap in front of it.
///
/// STR$ leaves a space where a minus sign would go, so "have " + STR$(3)
/// reads "have  3". Every count in this program goes through here instead,
/// which is the sort of thing worth fixing once rather than remembering at
/// every call.
///
/// - Parameter amount: The number to write out.
/// - Returns: The number as text, with no leading space.
FUNCTION Number$(amount AS INTEGER) AS STRING
    LOCAL text$ = STR$(amount)
    ' Drop the space STR$ keeps for a minus sign that is not there.
    IF LEFT$(text$, 1) = " " THEN
        RETURN MID$(text$, 2)
    END IF
    RETURN text$
END FUNCTION
