# Database Tutorial

![BASICStudio](https://img.shields.io/badge/BASICStudio-supported-brightgreen) ![BASICShell](https://img.shields.io/badge/BASICShell-supported-brightgreen)

This tutorial builds a reading list that remembers every book you add, even
after the program has ended and the computer has been switched off. It is
written for someone who has finished the
[Beginner's Guide](TUTORIAL_BEGINNERS.md) and nothing else. Every line is
explained, and every step is a whole program you can run.

Type each step into the editor (or copy it), run it, and look at what it
prints before reading on. Some steps are meant to be run more than once; the
text says when.

## The idea first

Every program in the Beginner's Guide forgets everything when it ends. Its
variables live only while it runs: run Guess the Number twice, and the second
game knows nothing about the first. To remember something until next time, a
program has to write it into a file.

A *database* is a file made for keeping things. It holds *tables*, and a table
is laid out like a spreadsheet: each *row* is one thing (one book), and each
*column* is one fact about it (its title, its author, the year it came out).

```text
  Book
  Title                 Author          Year
  Emma                  Jane Austen     1815
  Pride and Prejudice   Jane Austen     1813
  Dune                  Frank Herbert   1965
```

A database is better than a plain text file once there is more than a
handful of things: it can find, sort and count them without the program
reading every line itself.

The database this tutorial uses is **SQLite**. It is a whole database in a
single file, so there is no server to install and nothing to set up, and the
file can be copied like any other to back it up. You talk to it in **SQL**, a
language of short instructions written as plain text, such as
`SELECT Title FROM Book`. BASIC sends the instruction to SQLite and hands back
the answer.

## Step 1: Open the database, and make a table

```basic
LET db = SqlDatabase("books.sqlite")
db.Execute("CREATE TABLE IF NOT EXISTS Book (Title TEXT, Author TEXT, Year INTEGER)")
PRINT "The reading list is ready."
db.Close()
```

Run it. It prints `The reading list is ready.`, and a new file called
`books.sqlite` appears in the folder the program runs in. The file is the
database.

**`LET db = SqlDatabase("books.sqlite")`** opens the database file called
`books.sqlite`, making it if it is not there yet, and puts it in a variable
called `db`. The file is in the folder the program runs in, the one `PWD$`
names, which for a project is the project's folder.

`SqlDatabase("books.sqlite")` is a new kind of thing. The Beginner's Guide put
numbers and text in variables; this puts an *object* in one. An object is a
thing that can do jobs, and you ask it to do one by writing a dot and the
job's name, as the next line does with `db.Execute`. The jobs an object can do
are called its *methods*.

**`db.Execute("CREATE TABLE IF NOT EXISTS Book (...)")`** sends SQLite an
instruction in SQL. `Execute` is for instructions that change the database
rather than ask it a question. This one says: make a table called `Book`, with
three columns, unless there is one already.

- `Title TEXT` is a column called `Title` that holds text.
- `Author TEXT` is another.
- `Year INTEGER` holds a whole number.

`IF NOT EXISTS` matters: the second time the program runs, the table is
already there, and without those words SQLite would stop with an error. So
the program can make its table every time it starts, and nothing happens if
it was made before.

SQL is written in capitals here (`CREATE TABLE`), as is usual, to tell it
apart from the names you chose (`Book`, `Title`). SQLite does not mind either
way.

**`db.Close()`** closes the database when the program has finished with it,
making sure everything is written to the file.

## Step 2: Add a book, and count them

```basic
LET db = SqlDatabase("books.sqlite")
db.Execute("CREATE TABLE IF NOT EXISTS Book (Title TEXT, Author TEXT, Year INTEGER)")

db.Execute("INSERT INTO Book (Title, Author, Year) VALUES (?, ?, ?)", "Emma", "Jane Austen", 1815)

LET answer = db.Query("SELECT COUNT(*) AS Books FROM Book")
IF answer.Read() THEN PRINT "Books in the list: "; answer.Number("Books")
answer.Close()
db.Close()
```

Run it: `Books in the list: 1`. **Now run it again.** It says
`Books in the list: 2`. The first run's book was still there: the database
kept it after the program ended. That is the whole point of a database.
(Emma is now in the list twice. Step 6 shows how to take one out.)

**`db.Execute("INSERT INTO Book (Title, Author, Year) VALUES (?, ?, ?)", "Emma", "Jane Austen", 1815)`**
adds a row to the table. `INSERT INTO Book` names the table, the first
brackets name the columns being filled, and `VALUES` gives what goes in them.

Each `?` is a gap, and the values after the SQL fill the gaps in order: the
first `?` gets `"Emma"`, the second `"Jane Austen"`, the third `1815`. Always
put values in this way, with a `?` for each one. It keeps the values apart
from the instruction, so a value can be anything, even one with quotes in it.
(The first mistake below shows what happens otherwise.)

**`LET answer = db.Query("SELECT COUNT(*) AS Books FROM Book")`** asks the
database a question. `Query` is for questions, and it gives back the answer,
which goes in a variable called `answer`. In SQL, `SELECT` asks for
something, `COUNT(*)` means *how many rows*, `FROM Book` says which table, and
`AS Books` gives the answer a name to read it by.

An answer is called a *recordset*. Think of it as a list of rows with a
finger pointing at one of them. Before you can read anything, the finger has
to be moved onto the first row.

**`IF answer.Read() THEN ...`** moves the finger onto the next row. `Read`
gives back true when there was a row to move to, and false when the answer
has run out. Here there is one row, so it is true, and the `PRINT` runs.

**`answer.Number("Books")`** reads the column called `Books` from the row the
finger is on, as a number. (For text, use `Text$`, as step 3 does.)

**`answer.Close()`** closes the answer when the program has finished with it.
Each open answer holds on to part of the database, so close each one when you
are done.

## Step 3: List the books, in order

```basic
GLOBAL db = SqlDatabase("books.sqlite")
db.Execute("CREATE TABLE IF NOT EXISTS Book (Title TEXT, Author TEXT, Year INTEGER)")
ListBooks()
db.Close()

FUNCTION ListBooks()
    LOCAL books = db.Query("SELECT Title, Author, Year FROM Book ORDER BY Year")
    WHILE books.Read()
        PRINT books.Number("Year"); "  "; books.Text$("Title"); ", by "; books.Text$("Author")
    WEND
    books.Close()
END FUNCTION
```

Run it, and every book in the list is printed, one to a line, oldest first:

```text
1815  Emma, by Jane Austen
1815  Emma, by Jane Austen
```

**`GLOBAL db = SqlDatabase("books.sqlite")`** opens the database as before,
but with `GLOBAL`, so that every function in the program can use `db`,
including `ListBooks` below.

**`ListBooks()`** calls the function that does the listing. Putting the
listing in a function means the next steps can call it again without writing
it out each time.

**`LOCAL books = db.Query("SELECT Title, Author, Year FROM Book ORDER BY Year")`**
asks for three columns of every row in the table. `ORDER BY Year` sorts the
rows by their year, smallest first; `ORDER BY Year DESC` would sort newest
first, and `ORDER BY Title` alphabetically. `LOCAL` makes `books` belong to
`ListBooks` alone.

**`WHILE books.Read()`** is the usual way to go through an answer: `Read`
moves the finger to the next row and gives back true, so the loop runs once
for each row, and when the rows run out it gives back false and the loop ends.

**`books.Text$("Title")`** reads a column as text. The `$` says it gives back
text, as it does on a variable.

## Step 4: Add the books you type

```basic
GLOBAL db = SqlDatabase("books.sqlite")
db.Execute("CREATE TABLE IF NOT EXISTS Book (Title TEXT, Author TEXT, Year INTEGER)")

INPUT "Title (Return to stop)? "; title$
WHILE title$ <> ""
    INPUT "Author? "; author$
    INPUT "Year? "; year
    db.Execute("INSERT INTO Book (Title, Author, Year) VALUES (?, ?, ?)", title$, author$, year)
    INPUT "Title (Return to stop)? "; title$
WEND

ListBooks()
db.Close()

FUNCTION ListBooks()
    LOCAL books = db.Query("SELECT Title, Author, Year FROM Book ORDER BY Year")
    WHILE books.Read()
        PRINT books.Number("Year"); "  "; books.Text$("Title"); ", by "; books.Text$("Author")
    WEND
    books.Close()
END FUNCTION
```

Run it and add two books: type `Pride and Prejudice`, `Jane Austen` and
`1813`, then `Dune`, `Frank Herbert` and `1965`. When it asks for the next
title, just press Return. The whole list is printed, in order, with your books
among the rest.

The `INPUT` lines and the `WHILE` loop are the ones from the Beginner's Guide:
ask for a title, and keep going until the answer is empty.

**`db.Execute("INSERT INTO Book (...) VALUES (?, ?, ?)", title$, author$, year)`**
is the same `INSERT` as step 2, with variables after the SQL instead of fixed
values. Each `?` gets whatever the person typed.

## Step 5: Find books

```basic
GLOBAL db = SqlDatabase("books.sqlite")

INPUT "Books by which author? "; who$
LET found = db.Query("SELECT Title, Year FROM Book WHERE Author = ? ORDER BY Year", who$)
LET matches = 0
WHILE found.Read()
    PRINT found.Number("Year"); "  "; found.Text$("Title")
    matches = matches + 1
WEND
found.Close()
IF matches = 0 THEN PRINT "Nothing by "; who$; " in the list."
db.Close()
```

Run it and type `Jane Austen`. It lists her books and no one else's. Run it
again and type a name that is not in the list, and it says so.

**`... WHERE Author = ? ...`** asks for only the rows whose `Author` column
matches. `WHERE` is how a question picks rows: `WHERE Year < 1900` would find
the old ones, and `WHERE Title = ?` one book by its title. The `?` gets
`who$`, the name typed, for the same reason as in `INSERT`: a value always
goes in as a `?`.

**`matches = matches + 1`** counts the rows as they go by, so that the program
can tell when nothing matched.

## Step 6: Change and remove books

```basic
GLOBAL db = SqlDatabase("books.sqlite")

INPUT "Take out which title (Return for none)? "; gone$
IF gone$ <> "" THEN
    LET removed = db.Execute("DELETE FROM Book WHERE Title = ?", gone$)
    PRINT "Took out "; removed; " books."
END IF

INPUT "Change the year of which title (Return for none)? "; title$
IF title$ <> "" THEN
    INPUT "The right year? "; year
    LET changed = db.Execute("UPDATE Book SET Year = ? WHERE Title = ?", year, title$)
    PRINT "Changed "; changed; " books."
END IF

ListBooks()
db.Close()

FUNCTION ListBooks()
    LOCAL books = db.Query("SELECT Title, Author, Year FROM Book ORDER BY Year")
    WHILE books.Read()
        PRINT books.Number("Year"); "  "; books.Text$("Title"); ", by "; books.Text$("Author")
    WEND
    books.Close()
END FUNCTION
```

Run it. For the title to take out, type `Emma`: it says `Took out 2 books.`,
because step 2 put Emma in twice and both copies match. For the year to
change, type `Dune` and `1966`, then the list shows the change.

**`db.Execute("DELETE FROM Book WHERE Title = ?", gone$)`** removes every row
whose title matches. Be careful with `DELETE`: without a `WHERE`, it removes
every row in the table, and there is no undo.

`Execute` gives back a number: how many rows it changed. That is how the
program can say `Took out 2 books.`, and how it would know a title was
misspelled (it would say `0`).

**`db.Execute("UPDATE Book SET Year = ? WHERE Title = ?", year, title$)`**
changes rows that are already there. `SET Year = ?` says which column gets
which value, and `WHERE` says which rows. The `?`s are filled in order: the
year first, then the title.

## Step 7: The shortcut: objects that save themselves

```basic
CLASS Book
    PUBLIC Id AS INTEGER DATABASE KEY
    PUBLIC Title AS STRING DATABASE
    PUBLIC Author AS STRING DATABASE
    PUBLIC Year AS INTEGER DATABASE
END CLASS

GLOBAL db = SqlDatabase("shelf.sqlite")
GLOBAL store = DataStore(db)
store.EnsureSchema("Book")

DIM emma AS Book
emma = NEW Book()
emma.Title = "Emma"
emma.Author = "Jane Austen"
emma.Year = 1815
emma = store.Save(emma)
PRINT "Saved Emma as book number "; emma.Id

DIM again AS Book
again = store.Load("Book", emma.Id)
PRINT "Loaded it back: "; again.Title; ", by "; again.Author; ", "; again.Year
PRINT "Books on the shelf: "; store.Count("Book")
db.Close()
```

Run it twice. The first time it saves Emma as book number 1; the second time
as book number 2, and there are two books on the shelf. This step uses a new
file, `shelf.sqlite`, so it starts empty.

The steps so far wrote SQL for everything. BASIC can also write it for you:
you describe a book once, and a *data store* makes the table, saves books and
loads them back.

**`CLASS Book ... END CLASS`** describes what a book is: a kind of record with
four fields. A `CLASS` is a pattern for making objects, each with its own
values for the fields.

**`PUBLIC Title AS STRING DATABASE`** is one field, called `Title`, holding
text. The word `DATABASE` at the end means *keep this field in the database*:
it becomes a column of the table.

**`PUBLIC Id AS INTEGER DATABASE KEY`** is the book's number. `KEY` means the
database gives each book its own number, the first time the book is saved, so
that one book can always be told from another, even two with the same title.

**`GLOBAL store = DataStore(db)`** makes the data store, which works on the
database in `db`.

**`store.EnsureSchema("Book")`** makes a table called `Book` with a column for
each field marked `DATABASE`, if the file does not have one yet. It is the
`CREATE TABLE IF NOT EXISTS` of the earlier steps, written for you.

**`DIM emma AS Book`** and **`emma = NEW Book()`** make one book, and the
next three lines fill in its fields.

**`emma = store.Save(emma)`** saves the book as a row in the table, and gives
back the book as it was saved, with its new number filled in. That is why the
answer is put back into `emma`.

**`again = store.Load("Book", emma.Id)`** reads the book with that number back
out of the database into a new object.

**`store.Count("Book")`** counts the books in the table.

A data store suits a program that works on whole records. SQL suits questions
across many rows: lists, searches and totals. A real program, like the Grade
Book in the Examples, uses both on the same file.

## Starting over

The database file stays in the program's folder until you delete it. To
start the reading list again from nothing, type this at the prompt, then run
step 1 again:

```text
File.Rm "books.sqlite"
```

`File.Rm` removes a file. There is no undo, so it is worth copying the file
somewhere first if the list matters to you.

## Mistakes to try on purpose

Making a mistake on purpose, and seeing what it does, is the quickest way to
understand why a line is there. Try each of these, then put the line back.

**Glue a value into the SQL.** In step 4, replace the `db.Execute(...)` line
with one that glues the values into the instruction:

```basic
    db.Execute("INSERT INTO Book (Title, Author, Year) VALUES ('" + title$ + "', '" + author$ + "', " + STR$(year) + ")")
```

Run it and add `Charlotte's Web` by `E. B. White`, `1952`. BASIC stops with
`near "s": syntax error`. In SQL, text goes between single quotes, so the
apostrophe in *Charlotte's* ended the title early, and SQLite tried to read
`s Web'...` as part of the instruction. Worse, a person could type a title
that *is* an instruction, and the program would carry it out. With a `?`, the
value never becomes part of the instruction, so any title is safe. Put the
`?` line back.

**Misspell a column.** In step 3, change `ORDER BY Year` to `ORDER BY Yaer`.
BASIC stops with `no such column: Yaer`. SQLite checks the names in an
instruction against the table, so a misspelled name is caught at once and the
message names it.

**Read before `Read`.** In step 2, replace the `IF answer.Read() THEN ...`
line with `PRINT answer.Number("Books")`. BASIC stops with
`Recordset.Number needs a successful Read first`. The finger was not on a row
yet, so there was nothing to read.

## Where to look next

- **Examples ▸ Data ▸ Database** shows both ways side by side, and what
  happens to a value that looks like SQL.
- **Examples ▸ Apps ▸ Grade Book** is a whole application kept in a SQLite
  file: classes saved with a data store, and SQL for its lists and totals.
- The [ActiveUI Tutorial](TUTORIAL_ACTIVEUI.md) puts a program in a window of
  its own, which is the next step for the reading list.
