# ActiveUI Tutorial

![BASICStudio](https://img.shields.io/badge/BASICStudio-supported-brightgreen) ![BASICShell](https://img.shields.io/badge/BASICShell-not%20supported-lightgrey)

This tutorial builds a to-do list in a window of its own: a box to type a
task into, buttons, a list, and a question that asks before it throws
everything away. It is written for someone who has finished the
[Beginner's Guide](TUTORIAL_BEGINNERS.md) and nothing else. Every line is
explained, and every step is a whole program you can run.

Type each step into the editor (or copy it), click **Run**, and try it before
reading on. Each step builds on the one before, so the new lines are the only
ones you have not met.

## The idea first

The programs in the Beginner's Guide run from top to bottom. They print, they
ask a question with `INPUT`, and the person answers. The program is in charge,
and the person waits for it.

A program with a window works the other way round. It does its work in two
parts:

1. **It builds the window.** It makes a label, a button, a box to type into,
   and puts each one in the window. Nothing shows yet.
2. **It shows the window, and waits.** From then on the person is in charge.
   They type, click and choose whenever they like, in any order, for as long
   as they like. The program waits.

While it builds the window, the program tells each button what to do when it
is pressed: *call this function*. So when the person presses the button, the
program wakes up, runs that function, and goes back to waiting. When the
person closes the window, the waiting is over, and the program carries on
from where it was.

ActiveUI is the part of BASIC that makes real windows, with real buttons and
lists, the same ones every other app on your Mac or iPad has. The window
belongs to your program: it opens beside BASICStudio's own window and goes
away when your program ends.

## Step 1: A window with a label

```basic
GLOBAL win = AUIWindow("To Do")
GLOBAL message = AUILabel("Nothing to do yet.")
win.add(message)
win.run()
PRINT "The window has closed."
```

Click **Run**. A new window called **To Do** opens with `Nothing to do yet.`
in it. Close it: on a Mac, click the red button in its top-left corner; on an
iPad, tap the ✓ in its top-right corner. The console then says
`The window has closed.`

Now each line.

**`GLOBAL win = AUIWindow("To Do")`** makes the window and puts it in a
variable called `win`. **To Do** is its title, shown across its top.

`AUIWindow("To Do")` is a new kind of thing. The Beginner's Guide put numbers
and text in variables; this puts an *object* in one. An object is a thing
that can do jobs, and you ask it to do one by writing a dot and the job's
name, as the next lines do with `win.add` and `win.run`. The jobs an object
can do are called its *methods*.

`GLOBAL` says that the whole program shares this variable, including every
`FUNCTION` in it. That matters from step 2 on: the functions the buttons call
need to reach the window and what is in it. Inside a function, `GLOBAL` is
the only way to make a variable the rest of the program can see; at the top
of the program, as here, it says plainly what you mean. Write `GLOBAL` for
every control a function will use.

**`GLOBAL message = AUILabel("Nothing to do yet.")`** makes a *label*, a
line of text in the window that the person can read but not change, and puts
it in `message`.

**`win.add(message)`** puts the label in the window. Making a label does not
put it anywhere; `add` does.

**`win.run()`** is the moment the program hands the window over. `run` puts
the window on the screen and waits, for as long as it is open, while the
person uses it. **The line after `win.run()` does not run until the window has
closed.** That is how waiting looks in a program: one line that takes a long
time to finish.

**`PRINT "The window has closed."`** runs once the person has closed the
window. That is what ends the program: closing the window ends `run`, and the
program carries on to its last line and stops.

## Step 2: A button that does something

```basic
GLOBAL win = AUIWindow("To Do")
GLOBAL message = AUILabel("Press the button.")
LET addButton = AUIButton("Add")
win.add(message)
win.add(addButton)
addButton.onclick("AddTask")
win.run()
PRINT "The window has closed."

FUNCTION AddTask()
    message.text("You pressed Add.")
END FUNCTION
```

Run it, press **Add**, and the label changes to `You pressed Add.`

**`LET addButton = AUIButton("Add")`** makes a button with **Add** on it.
`LET` makes an ordinary variable. No function needs to reach the button
itself once it is built, so it does not need `GLOBAL`.

**`win.add(addButton)`** puts the button in the window, under the label. A
window lines up what you add to it, one under another, in the order you add
them.

**`addButton.onclick("AddTask")`** is the most important line in this
tutorial. It does not add anything. It tells the button: *when someone
presses you, call the function called `AddTask`*. Then the program carries on.

Look at `"AddTask"`: it is in quotes. It is the function's *name*, written as
text. The program does not call `AddTask` here; it hands the name to the
button. Later, while `win.run()` is waiting, the person presses the button,
and only then is the function with that name found and called. Your program
never calls `AddTask` itself. A function that is called like this, because
something happened in the window, is called a *handler*: it handles the thing
that happened.

**`FUNCTION AddTask()`** is the handler. It sits at the end of the program,
after everything else, as functions do in the Beginner's Guide.

**`message.text("You pressed Add.")`** changes what the label says. `text` is
one of a label's methods. The handler can reach the label because `message`
is `GLOBAL`.

> **Why a name, and not the code itself?** Some languages let you write a
> button's code right where you make the button. BASIC has something like
> that, a *closure* ([CLOSURES](CLOSURES.md)), but a closure works on its own
> copy of the program's variables, so anything it changed would be lost when
> it finished. A handler is always a named `FUNCTION`, so what it changes
> stays changed.

## Step 3: A box to type in

```basic
GLOBAL win = AUIWindow("To Do")
GLOBAL message = AUILabel("Type something to do, then press Add.")
GLOBAL taskField = AUIField("", "Something to do")
LET addButton = AUIButton("Add")
win.add(message)
win.add(taskField)
win.add(addButton)
addButton.onclick("AddTask")
win.run()
PRINT "The window has closed."

FUNCTION AddTask()
    LOCAL newTask$ = taskField.text$()
    IF newTask$ = "" THEN
        message.text("Type something to do first.")
    ELSE
        message.text("You typed: " + newTask$)
    END IF
END FUNCTION
```

Run it. Click in the box, type `Buy milk`, and press **Add**: the label says
`You typed: Buy milk`. Press **Add** with the box empty, and it asks you to
type something first.

**`GLOBAL taskField = AUIField("", "Something to do")`** makes a *field*, a
box the person types into. The first text in the brackets is what is in the
box to start with: `""`, nothing. The second is the hint shown in gray while
the box is empty; it is not part of the answer. It is `GLOBAL` because
`AddTask` reads it.

**`win.add(taskField)`** puts the field in the window, between the label and
the button.

**`LOCAL newTask$ = taskField.text$()`** reads what is in the field. `text$`
is the field's method for that; the `$` says, as it does for a variable, that
it gives back text. `LOCAL` makes `newTask$` belong to `AddTask` alone: it is
made fresh each time the button is pressed, and forgotten when the function
ends.

The `IF` is the one from the Beginner's Guide: an empty field gets one
message, and anything else gets the other, joined together with `+`.

## Step 4: A list

```basic
GLOBAL win = AUIWindow("To Do")
GLOBAL message = AUILabel("Type something to do, then press Add.")
GLOBAL taskField = AUIField("", "Something to do")
GLOBAL taskList = AUIList()
LET addButton = AUIButton("Add")
win.add(message)
win.add(taskField)
win.add(addButton)
win.add(taskList)
addButton.onclick("AddTask")
taskField.onsubmit("AddTask")
win.run()
PRINT "The window has closed."

FUNCTION AddTask()
    LOCAL newTask$ = taskField.text$()
    IF newTask$ = "" THEN
        message.text("Type something to do first.")
    ELSE
        taskList.add(newTask$)
        taskField.text("")
        message.text("Added " + newTask$ + ".")
    END IF
END FUNCTION
```

Run it and add three tasks. Each one goes into the list under the button,
and the box empties, ready for the next. Try pressing **Return** instead of
**Add**: it does the same.

**`GLOBAL taskList = AUIList()`** makes a *list*, a column of lines the
person can scroll through and pick from. It starts empty.

**`win.add(taskList)`** puts it in the window, at the bottom.

**`taskField.onsubmit("AddTask")`** gives the field a handler too. A field
calls its *submit* handler when the person presses **Return** in it. Naming
the same function as the button means **Return** and **Add** do exactly the
same thing, with one function to write.

**`taskList.add(newTask$)`** puts a new line at the end of the list.

**`taskField.text("")`** empties the field, by setting its text to nothing.
`text("...")` sets, and `text$()` reads.

## Step 5: Asking before clearing

```basic
GLOBAL win = AUIWindow("To Do")
GLOBAL message = AUILabel("Type something to do, then press Add.")
GLOBAL taskField = AUIField("", "Something to do")
GLOBAL taskList = AUIList()
LET buttons = AUIStack("horizontal")
LET addButton = AUIButton("Add")
LET clearButton = AUIButton("Clear All")
buttons.add(addButton)
buttons.add(clearButton)
win.add(message)
win.add(taskField)
win.add(buttons)
win.add(taskList)
addButton.onclick("AddTask")
taskField.onsubmit("AddTask")
clearButton.onclick("ClearAll")
win.run()
PRINT "The window has closed."

FUNCTION AddTask()
    LOCAL newTask$ = taskField.text$()
    IF newTask$ = "" THEN
        message.text("Type something to do first.")
    ELSE
        taskList.add(newTask$)
        taskField.text("")
        message.text("Added " + newTask$ + ".")
    END IF
END FUNCTION

FUNCTION ClearAll()
    LOCAL sure = AUIDialog("Clear the list?", "Every task goes.")
    sure.addbutton("Clear")
    sure.addbutton("Cancel")
    IF sure.show() = 0 THEN
        taskList.clear()
        message.text("Cleared.")
    END IF
END FUNCTION
```

Run it, add some tasks, and press **Clear All**. A question appears: *Clear
the list?* Press **Cancel** and nothing happens. Press **Clear All** again
and choose **Clear**, and the list empties.

**`LET buttons = AUIStack("horizontal")`** makes a *stack*: a holder that
lines up what you put in it. `"horizontal"` lines things up side by side,
left to right. Without it, a stack lines things up one under another, as a
window does.

**`buttons.add(addButton)`** and **`buttons.add(clearButton)`** put the two
buttons in the stack, so they sit side by side.

**`win.add(buttons)`** puts the whole stack, both buttons together, in the
window. A stack is how you put several things on one row.

**`clearButton.onclick("ClearAll")`** names the second button's handler.

**`LOCAL sure = AUIDialog("Clear the list?", "Every task goes.")`** makes a
*dialog*: a small window that asks a question and waits for an answer. The
first text is the question, in bold; the second says more.

**`sure.addbutton("Clear")`** and **`sure.addbutton("Cancel")`** give the
dialog its buttons, in order. The first is number 0 and the second is number
1, counting from 0 as arrays do.

**`IF sure.show() = 0 THEN`** shows the dialog and waits for the person to
press one of its buttons. `show` gives back that button's number. So the
lines inside the `IF` run only if they pressed **Clear**, button 0.

**`taskList.clear()`** empties the list.

Asking first matters whenever something cannot be undone. A dialog is how a
program asks.

## Step 6: A status line

```basic
GLOBAL win = AUIWindow("To Do")
GLOBAL message = AUILabel("Type something to do, then press Add.")
GLOBAL taskField = AUIField("", "Something to do")
GLOBAL taskList = AUIList()
GLOBAL statusLine = AUILabel("")
LET buttons = AUIStack("horizontal")
LET addButton = AUIButton("Add")
LET clearButton = AUIButton("Clear All")
buttons.add(addButton)
buttons.add(clearButton)
win.add(message)
win.add(taskField)
win.add(buttons)
win.add(taskList)
win.add(statusLine)
addButton.onclick("AddTask")
taskField.onsubmit("AddTask")
clearButton.onclick("ClearAll")
taskList.onselect("Picked")
ShowCount()
win.run()
PRINT "The window has closed with "; taskList.count(); " things still to do."

FUNCTION AddTask()
    LOCAL newTask$ = taskField.text$()
    IF newTask$ = "" THEN
        message.text("Type something to do first.")
    ELSE
        taskList.add(newTask$)
        taskField.text("")
        message.text("Added " + newTask$ + ".")
        ShowCount()
    END IF
END FUNCTION

FUNCTION ClearAll()
    LOCAL sure = AUIDialog("Clear the list?", "Every task goes.")
    sure.addbutton("Clear")
    sure.addbutton("Cancel")
    IF sure.show() = 0 THEN
        taskList.clear()
        message.text("Cleared.")
        ShowCount()
    END IF
END FUNCTION

FUNCTION Picked(event AS BASICAUIEvent)
    message.text("You picked " + event.Text$ + ".")
END FUNCTION

FUNCTION ShowCount()
    statusLine.text("To do:" + STR$(taskList.count()))
END FUNCTION
```

Run it. A line at the bottom counts the tasks, and changes as you add and
clear them. Click a task in the list, and the message at the top says which
one you picked. Close the window, and the console says how many were left.

**`GLOBAL statusLine = AUILabel("")`** is a second label, empty to start
with, and **`win.add(statusLine)`** puts it at the bottom, under the list. A
line along the bottom of a window that says how things stand is called a
*status line*.

**`taskList.onselect("Picked")`** gives the list a handler, called when the
person picks a line in it.

**`ShowCount()`**, just before `win.run()`, is called by the program itself,
not by the window. It is an ordinary function, like `Greet` in the Beginner's
Guide, and here it fills in the status line before the window is shown. The
same function is called again at the end of `AddTask` and `ClearAll`, so the
count is always right. Not every function is a handler: this one is called by
name in the program, the old way.

**`FUNCTION Picked(event AS BASICAUIEvent)`** is a handler that is told what
happened. When the list calls it, it passes along an *event*, a small object
describing the pick, and the function takes it as its parameter.
`event.Text$` is the text of the line that was picked. The handlers in the
earlier steps took nothing, because a button press has nothing more to say.

**`statusLine.text("To do:" + STR$(taskList.count()))`** sets the status
line, to `To do: 3` when there are three. `taskList.count()` is how many lines
the list has, and `STR$` turns that number into text so it can be joined to
the rest with `+`. `STR$` puts a space in front of the number, where a minus
sign would go, which is why there is no space after the colon.

**`PRINT "The window has closed with "; taskList.count(); " things still to do."`**
runs after the window has closed, and can still ask the list how many lines
it had.

## What ends the program

The program ends when the window closes and the lines after `win.run()` have
run. The person closes the window with its close button: the red button in
the corner on a Mac, the ✓ at the top on an iPad. A handler can close it too,
with `win.close()`, for a **Quit** button of your own.

**Stop** in BASICStudio's toolbar also ends the program at once, window and
all.

## Mistakes to try on purpose

Making a mistake on purpose, and seeing what it does, is the quickest way to
understand why a line is there. Try each of these on the program from step 6,
then put the line back.

**Leave out `win.run()`.** Delete it and run. The window never appears, and
the console prints the last line straight away. Everything was built, but
nothing was shown, so the program went straight on to the end. Building a
window is not showing it.

**Misspell a handler's name.** Change `addButton.onclick("AddTask")` to
`addButton.onclick("AddTsk")` and run. The window looks just the same: a name
in quotes is only text, so nothing checks it while the window is built. Type
a task and press **Add**, and nothing happens. There is no function called
`AddTsk` to call. Press **Return** instead, and the task is added, because the
field's handler is still spelled right. When a button does nothing, check that
the name in quotes matches the `FUNCTION` exactly.

**Leave a control out of the window.** Delete `win.add(statusLine)` and run.
The status line is made, and `ShowCount` changes it, but it is never seen,
because it was never put in the window. Making a control and adding it are two
different steps.

## Where it runs

A program's own window needs an app that can open windows: **BASICStudio**,
on the Mac and on iPad.

- **BASICShell** runs in a terminal, which has no windows. It stops at the
  first line with `AUIWindow needs a host that can open windows; run the
  program in BASICStudio`.
- **basicc**, the compiler, refuses these programs by name today, for the same
  reason.

For windows in a terminal, see the [TUIKit Tutorial](TUTORIAL_TUIKIT.md).

## How it differs from TUIKit

If you have done the [TUIKit Tutorial](TUTORIAL_TUIKIT.md), the idea is the
same: build, show, then wait while the person uses it, with handlers named in
quotes. What differs:

- These are real windows, the same as every other app's, rather than boxes
  drawn with letters in the console.
- A window lines up what you add to it, so you need a stack only for a row.
  In TUIKit, two things added straight to a window land in the same place.
- There is no application object to make. `win.run()` shows the window and
  waits; in TUIKit, `app.run` does that.

## Where to look next

- **Examples ▸ ActiveUI ▸ Aui Gallery** has every kind of control there is,
  with the call each one takes.
- **File ▸ New Project…** has an ActiveUI starter: this to-do list, finished,
  with a **Done** button that takes a task off.
- **Examples ▸ Apps ▸ Grade Book** is a whole application made the same way,
  with tabs, tables and a database, written to be read and changed.
