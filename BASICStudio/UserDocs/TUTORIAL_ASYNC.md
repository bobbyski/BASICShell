# Async Programming Tutorial

![BASICStudio](https://img.shields.io/badge/BASICStudio-supported-brightgreen) ![BASICShell](https://img.shields.io/badge/BASICShell-supported-brightgreen)

This tutorial makes breakfast: it puts the kettle on and the bread in the
toaster at the same time, sets the table while they work, and serves
breakfast when both are ready. It is written for someone who has finished the
[Beginner's Guide](TUTORIAL_BEGINNERS.md) and nothing else. Every line is
explained, and every step is a whole program you can run.

Type each step into the editor (or copy it), run it, and watch the order the
lines are printed in before reading on. In this tutorial the order is the
lesson.

## The idea first

The programs in the Beginner's Guide do one thing at a time: each line
finishes before the next one starts. That is fine while every line is quick.
But some jobs are slow because they are *waiting*: for a timer, for a file,
for a web page from the other side of the world. A program that only waits
gets nothing done meanwhile.

Think of making breakfast. You do not stand and watch the kettle until it
boils, and only then put the bread in the toaster. You put the kettle on,
put the bread in, set the table while both are working, and pour when the
kettle is ready.

A program can work the same way. It can *start* a slow job, carry on with
other lines while the job runs, and *wait* for the job's answer only at the
moment it needs it. A job started like this is called a *task*, and starting
it gives the program a *ticket* for it, like the ticket a dry cleaner gives
you: the coat is not ready yet, but the ticket is how you collect it later.
Waiting for a task and collecting its answer is called *awaiting* it.

## Step 1: Waiting a moment

```basic
PRINT "Wait for it..."
slept = AWAIT Sleep(2000)
PRINT "Two seconds later."
```

Run it. `Wait for it...` appears, then two seconds pass, then
`Two seconds later.`

**`Sleep(2000)`** starts a timer that goes off after 2000 milliseconds, which
is two seconds (a millisecond is a thousandth of a second). `Sleep` does not
wait itself: it starts the timer and gives back a ticket for it straight away.

**`AWAIT`** waits for a ticket's task to finish and gives back its answer.
Here it waits for the timer to go off. The answer from `Sleep` is how many
milliseconds it slept, and **`slept = ...`** keeps it. `AWAIT` always gives
back an answer, so it always goes on the right of an `=`, even when, as here,
the program has no use for the answer.

This step does nothing at the same time as anything else; it only shows
`AWAIT`. The next steps start things and do other work while they run.

## Step 2: A slow job of your own

```basic
PRINT "Putting the kettle on."
GLOBAL kettle AS TASK = BoilKettle()
PRINT "While it boils, getting out a cup."
water$ = AWAIT kettle
PRINT "Pouring the "; water$; "."

ASYNC FUNCTION BoilKettle() AS STRING
    slept = AWAIT Sleep(1500)
    PRINT "The kettle has boiled."
    RETURN "tea"
END FUNCTION
```

Run it, and watch the order:

```text
Putting the kettle on.
While it boils, getting out a cup.
The kettle has boiled.
Pouring the tea.
```

The program got out a cup *before* the kettle had boiled. It did not wait
for `BoilKettle` to finish before carrying on.

**`ASYNC FUNCTION BoilKettle() AS STRING`** makes a function that runs as a
task. `ASYNC` is short for *asynchronous*, which means *not at the same pace*:
calling it starts it, and the caller carries on without waiting. Inside, it is
an ordinary function. This one waits one and a half seconds (the kettle
boiling), says so, and gives back the text `"tea"`.

**`GLOBAL kettle AS TASK = BoilKettle()`** calls the function, which starts
it, and keeps the ticket in a variable called `kettle`. `AS TASK` says the
variable holds a ticket for a task. The call does not wait for the kettle; it
only starts it, so the program goes straight on to the next line.

**`PRINT "While it boils, getting out a cup."`** runs while the kettle is
still boiling.

**`water$ = AWAIT kettle`** waits for the kettle's task to finish, then puts
what it gave back, `"tea"`, into `water$`. This is where the program stops and
waits, and only because it needs the answer now.

## Step 3: Two things at once

```basic
PRINT "Putting the kettle on, and the bread in the toaster."
GLOBAL kettle AS TASK = BoilKettle()
GLOBAL toaster AS TASK = MakeToast()
PRINT "Both are going. Setting the table."
water$ = AWAIT kettle
toast$ = AWAIT toaster
PRINT "Breakfast: "; toast$; " and "; water$; "."

ASYNC FUNCTION BoilKettle() AS STRING
    slept = AWAIT Sleep(1500)
    PRINT "The kettle has boiled."
    RETURN "tea"
END FUNCTION

ASYNC FUNCTION MakeToast() AS STRING
    slept = AWAIT Sleep(800)
    PRINT "The toast has popped up."
    RETURN "toast"
END FUNCTION
```

Run it:

```text
Putting the kettle on, and the bread in the toaster.
Both are going. Setting the table.
The toast has popped up.
The kettle has boiled.
Breakfast: toast and tea.
```

The toast popped up *first*, although the toaster was started second. The
two tasks ran at the same time, and the quicker one finished first.
Breakfast takes as long as the slower job, the kettle, not as long as both
added together.

**`GLOBAL toaster AS TASK = MakeToast()`** starts a second task straight after
the first, with its own ticket.

**`water$ = AWAIT kettle`** and **`toast$ = AWAIT toaster`** collect the two
answers. The program waits for the kettle first, and while it waits, the
toast pops up on its own. By the time it awaits the toaster, the toast is
long done, so that `AWAIT` gives back its answer at once.

## Step 4: How is a task getting on?

```basic
GLOBAL kettle AS TASK = BoilKettle()
PRINT "Just started: "; TASKSTATUS$(kettle)
slept = AWAIT Sleep(300)
PRINT "While it boils: "; TASKSTATUS$(kettle)
water$ = AWAIT kettle
PRINT "Once it has boiled: "; TASKSTATUS$(kettle)

GLOBAL second AS TASK = BoilKettle()
CANCEL second
PRINT "A second kettle, switched off: "; TASKSTATUS$(second)

ASYNC FUNCTION BoilKettle() AS STRING
    slept = AWAIT Sleep(1000)
    RETURN "tea"
END FUNCTION
```

Run it:

```text
Just started: RUNNING
While it boils: SUSPENDED
Once it has boiled: COMPLETED
A second kettle, switched off: CANCELLED
```

**`TASKSTATUS$(kettle)`** says how the task on a ticket is getting on, as a
word:

| Word | Means |
|---|---|
| `RUNNING` | it is working |
| `SUSPENDED` | it is waiting for something, here its own timer |
| `COMPLETED` | it has finished, and its answer is ready |
| `CANCELLED` | it was stopped before it finished |
| `FAILED` | it went wrong (step 7 shows what to do about that) |

**`slept = AWAIT Sleep(300)`** gives the kettle a moment to get going, so
there is something to see.

**`CANCEL second`** stops a task that is no longer wanted: the second kettle
is switched off before it boils.

## Step 5: Start it, and don't wait

```basic
BACKGROUND RingDoorbell()
PRINT "Carrying on without waiting."
slept = AWAIT Sleep(500)
PRINT "Done."

ASYNC FUNCTION RingDoorbell()
    slept = AWAIT Sleep(200)
    PRINT "Ding dong!"
END FUNCTION
```

Run it:

```text
Carrying on without waiting.
Ding dong!
Done.
```

Some jobs have no answer to collect: ringing a doorbell, writing a note in a
log. The program wants them started, and does not care when they finish.

**`ASYNC FUNCTION RingDoorbell()`** has no `AS` type after it, so it gives
back nothing.

**`BACKGROUND RingDoorbell()`** starts it and lets it go: no ticket is kept,
and nothing will wait for it. The word `BACKGROUND` says that on purpose.
Without it, starting a task and keeping no ticket is a mistake BASIC stops
for, because usually it is one: the second mistake below shows why.

**`slept = AWAIT Sleep(500)`** keeps the program going long enough for the
doorbell to ring. When a program ends, any task still going in the background
is stopped, so without this line you would never hear the bell.

## Step 6: Saving and reading a file

```basic
GLOBAL saving AS TASK = WriteFileAsync("shopping.txt", "Bread" + CHR$(10) + "Tea" + CHR$(10))
written = AWAIT saving
PRINT "Wrote "; written; " bytes."

GLOBAL reading AS TASK = ReadFileAsync("shopping.txt")
list$ = AWAIT reading
PRINT "The list says:"
PRINT list$
```

Run it. It writes a shopping list to a file called `shopping.txt` in the
program's folder, then reads it back:

```text
Wrote 10 bytes.
The list says:
Bread
Tea
```

Saving and reading files can be slow, on a busy disk or a file kept in the
cloud, so these are tasks too.

**`WriteFileAsync("shopping.txt", ...)`** starts writing the text to the file,
making the file if it is not there and replacing it if it is. `CHR$(10)` is
the character that starts a new line, so the list has one thing to a line.
Its answer, collected by **`written = AWAIT saving`**, is how many bytes it
wrote: one for each letter and each new line here.

**`ReadFileAsync("shopping.txt")`** starts reading the whole file, and its
answer is the file's text.

## Step 7: Fetching a web page, and when it goes wrong

```basic
ON ERROR GOTO CouldNotFetch
GLOBAL request AS TASK = HttpGetAsync("https://example.com/")
PRINT "Asking for the page..."
page = AWAIT request
PRINT "Status: "; page("STATUS")
PRINT "The page is "; LEN(page("BODY")); " characters long."
END

CouldNotFetch:
    PRINT "Could not fetch the page. Is the computer on the internet?"
```

Run it. With an internet connection it prints `Status: 200` (the web's way of
saying *here it is*) and how long the page is. Without one, it says it could
not fetch the page. Change the address to `https://example.invalid/`, which
does not exist, and run it again to see the second message for certain.

**`HttpGetAsync("https://example.com/")`** starts asking a web server for the
page at that address. Its answer is a *dictionary*: several values, each
looked up by a name in brackets. **`page("STATUS")`** is the server's reply
code, and **`page("BODY")`** is the page itself, as text.

**`ON ERROR GOTO CouldNotFetch`**, on the first line, says: *if anything goes
wrong from here on, jump to the line labeled `CouldNotFetch`* instead of
stopping with an error. A task that goes wrong reports it at the `AWAIT` that
collects it, so a page that cannot be fetched jumps there from
`page = AWAIT request`.

**`END`** stops the program after the page has been shown, so that it does
not carry on into the lines meant only for when something went wrong.

**`CouldNotFetch:`** is a *label*, a name for a line that `GOTO` can jump to.
The line after it is what happens when the page cannot be fetched.

## Mistakes to try on purpose

Making a mistake on purpose, and seeing what it does, is the quickest way to
understand why a line is there. Try each of these, then put the line back.

**Forget `AWAIT`.** In step 2, change `water$ = AWAIT kettle` to
`PRINT "The kettle gave me: "; kettle` and run it. It prints
`The kettle gave me: <TASK #2 BoilKettle>`, the ticket rather than the tea,
and when the program ends it warns that the task `is still running; use
AWAIT, JOIN, CANCEL, or BACKGROUND`. A ticket is not the answer; `AWAIT` is
what collects it.

**Start a task and keep nothing.** In step 2, change
`GLOBAL kettle AS TASK = BoilKettle()` to just `BoilKettle()`. BASIC stops
straight away with `Task result was ignored; use AWAIT, assign it to a TASK
variable, or launch it with BACKGROUND`. Starting a task whose answer nobody
can ever collect is almost always a slip, so BASIC asks you to say what you
meant: keep the ticket, or say `BACKGROUND`.

**Expect a task to change your variables.** Run this:

```basic
GLOBAL cups = 0
GLOBAL kettle AS TASK = BoilKettle()
done$ = AWAIT kettle
PRINT "Cups poured: "; cups

ASYNC FUNCTION BoilKettle() AS STRING
    cups = cups + 2
    PRINT "Inside the task, cups is "; cups
    RETURN "tea"
END FUNCTION
```

It prints `Inside the task, cups is 2` and then `Cups poured: 0`. A task gets
its own copy of the program's variables when it starts, so what it changes
stays in its copy. That is on purpose: two things running at once, both
changing the same variable, would make a program that does something
different every time it runs. When a task has something to tell the program,
it gives it back with `RETURN`, and the program collects it with `AWAIT`.

## What else there is

- **`JOIN kettle`** waits for a task to finish without collecting its answer.
- **`TASKERROR$(kettle)`** gives the message of a task that failed.
- **Stop** in BASICStudio, or Ctrl-C in BASICShell, stops the program and
  every task it started.
- **Seeing tasks while they run:** BASICStudio's debugger lists each task, how
  it is getting on and what it is waiting for, and in BASICShell the commands
  `TASKS` and `TASK` followed by a task's number show the same.

The reference page [ASYNC and AWAIT](ASYNC_AWAIT.md) has every detail, and
[Async Files](ASYNC_FILES.md) every file task.
