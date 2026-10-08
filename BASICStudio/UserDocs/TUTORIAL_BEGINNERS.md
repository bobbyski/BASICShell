# Beginner's Guide to BASIC

![BASICStudio](https://img.shields.io/badge/BASICStudio-supported-brightgreen) ![BASICShell](https://img.shields.io/badge/BASICShell-supported-brightgreen)

BASIC was designed to be the first programming language anyone learns. You write instructions in plain words, one per line, and the computer carries them out in order. This guide assumes you have never programmed before. By the end you will have written a small game.

Every example here can be typed in exactly as shown. Try each one, then change it and see what happens. That is how programmers learn. Along the way are **mistakes to try on purpose**: everyone's programs go wrong, and it helps to have seen what BASIC says when they do before it happens by accident.

## Where Things Are

BASICStudio's window has a row of buttons along the top, the *toolbar*, and a large pane under it that shows either the **console** or the **editor**:

```text
 ▶  ⚡  ■  │  Console  Editor  Debug  Documentation  ...      ← the toolbar
┌──────────────────────────────────────────┬─────────────────┐
│                                          │                 │
│  the console, or the editor:             │  this guide,    │
│  the Console and Editor buttons          │  when the       │
│  choose which                            │  Documentation  │
│                                          │  button is on   │
│  ~  Ready                                │                 │
│                                          │                 │
└──────────────────────────────────────────┴─────────────────┘
```

- The **console** is where you talk to BASIC a line at a time. It shows `Ready` when it is waiting for you, and it is where programs print what they print.
- The **editor** is where you write a program: a list of lines kept together, to run as often as you like.
- **▶ Run** runs the program in the editor, and **■ Stop** stops one that is running. (**⚡** runs it a faster way; you will not need it here.)
- The toolbar buttons show pictures rather than words: the Console button is a little terminal window, and the Editor button is a pencil on a square. Rest the mouse on one to see its name.

**BASICShell** is BASIC in a terminal window, with no buttons at all. Everything is typed. Its prompt, with `Ready` in it, works like BASICStudio's console. To write a program there, type `edit`: a full-screen editor opens. Type the program, press **Control-S** to keep it and **Control-X** to leave, then type `run`. `save "hello.bas"` keeps the program in a file, and `load "hello.bas"` brings it back. To stop a program that is running, press **Control-C**.

## Say Hello

Click in the console, where the `Ready` prompt is, and type:

```basic
print "Hello, world!"
```

Press Return and BASIC answers:

```text
Hello, world!
```

`PRINT` shows whatever follows it. Text goes inside double quotes. Without quotes, BASIC works the answer out first:

```basic
print 2 + 3 * 4
```

```text
14
```

Multiplication happens before addition, just as in math class. Use parentheses to change the order: `print (2 + 3) * 4` prints `20`.

Typing a statement at the prompt runs it immediately. That is handy for trying things, but it is forgotten as soon as it has run. To keep instructions, you write a program.

## Your First Program

A program is a list of statements saved together. In BASICStudio, click the **Editor** button in the toolbar and type:

```basic
print "Hello!"
print "This is my first program."
print "2 + 2 ="; 2 + 2
```

Click **Run** (the triangle). BASICStudio switches to the console and shows:

```text
Hello!
This is my first program.
2 + 2 =4
```

The semicolon joins things together on one line. The statements ran from top to bottom, one after another. Every program works that way unless you tell it otherwise, which the rest of this guide shows you how to do.

In BASICShell, type `edit`, type the program, press Control-S and Control-X, and type `run`.

### Mistakes to try on purpose

**Leave out a closing quote.** Change the first line to `print "Hello!` and run it. Nothing is printed, not even the lines that were right:

```text
print "Hello!
      ^
Syntax error: Unterminated string
```

BASIC reads the whole program before it runs any of it, and stops at the first line it cannot understand. It shows that line, puts a `^` under the place where it got lost, and says why. A *string* is a piece of text in quotes, and *unterminated* means it never ends: the closing `"` is missing.

BASICShell says the same, with the place written out in front instead of the `^`: `Line 1, column 7: Syntax error: Unterminated string`. Column 7 is the seventh character along, where the string starts.

**Misspell PRINT.** Put the quote back, and change the second line to `pirnt "This is my first program."`:

```text
pirnt "This is my first program."
      ^
Syntax error: Expected =
```

BASIC does not know a word `pirnt`, so it guesses that it is the name of a variable (you will meet those next) and that the line is giving it a value, as in `pirnt = 5`. It got as far as the text in quotes and says it expected an `=` there. A message like this often points just past the real mistake, so look at the start of the line too.

## Variables Remember Things

A variable is a name that holds a value. Give it a value with `=`, then use the name wherever you need the value:

```basic
name$ = "Ada"
age = 36
print name$; " is "; age; " years old."
print "Next year "; name$; " will be "; age + 1
```

```text
Ada is 36 years old.
Next year Ada will be 37
```

A name ending in `$` holds text, which programmers call a *string*. A name without it holds a number. Names are not case-sensitive, so `AGE` and `age` are the same variable.

Join strings with `+`. After running the program above, type this at the prompt; the variables are still there:

```basic
print "Hello, " + name$ + "!"
```

```text
Hello, Ada!
```

## Asking Questions

`INPUT` waits for the person running the program to type something, then stores it in a variable:

```basic
input "What is your name? "; name$
print "Hello, "; name$; "!"
```

Run it, type `Grace` and press Return:

```text
What is your name? Grace
Hello, Grace!
```

The text in quotes is the question. Include your own `?` and a space, so the answer does not run into it. Use a `$` variable for text answers and a plain one for numbers.

## Making Decisions

`IF` runs statements only when something is true:

```basic
input "How old are you? "; age
if age >= 18 then
    print "You can vote."
else
    print "Not old enough to vote yet."
end if
```

Run it twice, answering `20` and then `12`:

```text
How old are you? 20
You can vote.
```

```text
How old are you? 12
Not old enough to vote yet.
```

The lines between `THEN` and `ELSE` run when the test is true, and the lines after `ELSE` run when it is not. `END IF` marks the end. The comparisons are:

| Test | Means |
|---|---|
| `a = b` | equal |
| `a <> b` | not equal |
| `a < b`, `a > b` | less than, greater than |
| `a <= b`, `a >= b` | less than or equal, greater than or equal |

To check more than two cases, add `ELSEIF`. See [IF THEN](IF_THEN.md).

## Repeating Things

Computers are good at doing the same thing many times. `FOR` counts:

```basic
for i = 1 to 5
    print i; " squared is "; i * i
next i
```

```text
1 squared is 1
2 squared is 4
3 squared is 9
4 squared is 16
5 squared is 25
```

Everything between `FOR` and `NEXT` runs once for each value of `i`, from 1 to 5.

`WHILE` repeats for as long as something stays true, which suits the times you do not know how many passes there will be:

```basic
count = 3
while count > 0
    print count; "..."
    count = count - 1
wend
print "Liftoff!"
```

```text
3...
2...
1...
Liftoff!
```

Make sure something inside the loop changes the test. A `WHILE` whose test never becomes false runs forever.

### Mistakes to try on purpose

**Leave out NEXT.** Take the last line, `next i`, out of the `FOR` example and run it:

```text
1 squared is 1
```

No message at all. BASIC ran the lines after `FOR` once, found no `NEXT` to send it back to the top, and carried on to the end of the program. Not every mistake comes with a message. When a program does less than you meant, look for a line that is missing.

**A loop that never stops.** Take `count = count - 1` out of the `WHILE` example and run it. `count` stays 3, so `count > 0` is always true, and the console fills with `3...` until you stop it: click **■ Stop** in BASICStudio, or press **Control-C** in BASICShell. BASIC says where it was when it stopped:

```text
3...
3...
3...
Break at 4
```

*Break* means the program was stopped from outside, and the number is the line it had got to. It may be 2 or 3 instead: any of the loop's three lines, depending on where it was when you stopped it.

## Lists of Things

An array holds many values under one name, each with a number called its *index*. `DIM` creates one:

```basic
dim fruit$(2)
fruit$(0) = "apple"
fruit$(1) = "banana"
fruit$(2) = "cherry"
for i = 0 to 2
    print i; ": "; fruit$(i)
next i
```

```text
0: apple
1: banana
2: cherry
```

Counting starts at 0, so `DIM fruit$(2)` makes three places: 0, 1 and 2. Arrays and `FOR` loops go together well.

### Mistakes to try on purpose

**Go past the end.** Change the loop to `for i = 0 to 3` and run it:

```text
0: apple
1: banana
2: cherry
    print i; ": "; fruit$(i)
    ^
Runtime error: fruit$ subscript out of range at 6
```

The first three passes are fine. The fourth asks for `fruit$(3)`, and there is no place 3. A *subscript* is the index in brackets, and *out of range* means it is not one of the places `DIM` made. This is a *runtime* error, found while the program was running, unlike the syntax errors above, which were found before it started; that is why the first three lines were printed. *At 6* is the line it was on.

## Making Your Own Functions

A function gives a name to some statements so you can use them again. Put functions at the end of the program:

```basic
print Double(21)
Greet("Ada")
Greet("Grace")

function Double(n as integer) as integer
    return n * 2
end function

function Greet(who as string)
    print "Hello, "; who; "!"
end function
```

```text
42
Hello, Ada!
Hello, Grace!
```

The names in parentheses are the function's *parameters*, the values it is given. `Double(21)` runs `Double` with `n` set to 21, and `Greet("Ada")` runs `Greet` with `who` set to `"Ada"`.

Each parameter says what kind of value it takes. `as integer` means a whole number, such as 21 or -4, with nothing after a decimal point. `as string` means text. `Double` also ends with `as integer` after its parentheses: that is the kind of value it gives back, with `RETURN`. `Greet` gives nothing back, so it has no `as` at the end, and it is used as a statement on its own rather than inside a `PRINT`.

### Mistakes to try on purpose

**Give a function the wrong kind of value.** Change the first line to `print Double(2.5)`:

```text
print Double(2.5)
^
Type error: Cannot assign non-integer value to n at 1
```

2.5 is not a whole number, and `n` was declared `as integer`, so BASIC will not put it there. Saying what kind each parameter is means a mistake like this is caught where it happens. `Greet(42)` is caught the same way: `Cannot assign non-string value to who`.

## Notes to Yourself

Anything after an apostrophe is a comment. BASIC ignores it, but it helps the next person to read the program, and that person is often you:

```basic
' Work out the total cost
price = 4
count = 3
print price * count ' prints 12
```

```text
12
```

## Putting It Together: Guess the Number

This game uses everything above. Type it into the editor and run it:

```basic
' Guess the Number
secret = int(rnd() * 100) + 1
tries = 0
guess = 0

print "I'm thinking of a number from 1 to 100."
while guess <> secret
    input "Your guess? "; guess
    tries = tries + 1
    if guess < secret then
        print "Higher!"
    elseif guess > secret then
        print "Lower!"
    end if
wend
print "You got it in "; tries; " tries!"
```

A game goes something like this; the number is different every time:

```text
I'm thinking of a number from 1 to 100.
Your guess? 50
Higher!
Your guess? 75
Lower!
Your guess? 62
Lower!
Your guess? 56
You got it in 4 tries!
```

The line that picks the number, `secret = int(rnd() * 100) + 1`, is worth taking slowly, from the inside out:

1. `RND()` gives a random number from 0 up to, but not including, 1. Say it gives `0.4273`.
2. `* 100` makes that `42.73`. Any number `RND()` can give ends up from 0 up to, but not including, 100.
3. `INT` keeps the whole-number part and drops the rest: `42`. Now it is a whole number from 0 to 99.
4. `+ 1` makes it `43`. Now it is from 1 to 100, as the game promises.

The smallest `RND()` can give is 0, which comes out as 1. The largest is just under 1, such as `0.9999`, which becomes `99.99`, then `99`, then 100.

`guess = 0` before the loop matters too. `WHILE` checks its test before the first pass, and a guess of 0 can never be the secret, so the loop always runs at least once.

Some ideas for making it your own:

- Tell the player when they are within 5 of the answer.
- Let them choose how big the range is.
- Ask whether they want to play again.

## When Something Goes Wrong

Everyone's programs have mistakes in them, which are called *bugs*. When BASIC cannot understand or carry out a line, it stops and says why, and the editor marks the line. You have seen the three kinds now:

- a **syntax error**, found before the program starts, in a line BASIC cannot read;
- a **runtime error** or a **type error**, found while it runs, in a line it can read but cannot carry out;
- and the quiet kind, where the program runs without a message but does the wrong thing.

Read the message, fix the line, and run again. If a program seems stuck, click **Stop**. The debugger (the bug button) lets you pause a program and watch its variables change one line at a time, which is the way to find the quiet kind.

## Where to Go Next

- [Graphics Tutorial](TUTORIAL_GRAPHICS.md): draw shapes, colors and a clickable calculator.
- [TUIKit Tutorial](TUTORIAL_TUIKIT.md): build windows, buttons and menus in the terminal.
- [ActiveUI Tutorial](TUTORIAL_ACTIVEUI.md): build a to-do list in a real window of its own.
- [Database Tutorial](TUTORIAL_DATABASE.md): keep a reading list in a database file that remembers it between runs.
- [Async Programming Tutorial](TUTORIAL_ASYNC.md): do several things at once.
- [BASICrc Tutorial](TUTORIAL_BASICRC.md): set BASICShell up the way you like it, every time it starts.
