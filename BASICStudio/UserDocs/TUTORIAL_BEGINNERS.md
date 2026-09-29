# Beginner's Guide to BASIC

![BASICStudio](https://img.shields.io/badge/BASICStudio-supported-brightgreen) ![BASICShell](https://img.shields.io/badge/BASICShell-supported-brightgreen)

BASIC was designed to be the first programming language anyone learns. You write instructions in plain words, one per line, and the computer carries them out in order. This guide assumes you have never programmed before. By the end you will have written a small game.

Every example here can be typed in exactly as shown. Try each one, then change it and see what happens. That is how programmers learn.

## Say Hello

Click in the console, the dark pane where the `Ready` prompt is, and type:

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

In BASICShell, save the program in a file such as `hello.bas`, then type `load "hello.bas"` and `run`.

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

Join strings with `+`:

```basic
print "Hello, " + name$ + "!"
```

## Asking Questions

`INPUT` waits for the person running the program to type something, then stores it in a variable:

```basic
input "What is your name? "; name$
print "Hello, "; name$; "!"
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

Make sure something inside the loop changes the test. A `WHILE` whose test never becomes false runs forever. If that happens, click **Stop**.

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

## Making Your Own Commands

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

The names in parentheses are the function's *parameters*, the values it is given, and each says what type it is. `Double` ends with `as integer` because it gives back a whole number with `RETURN`. `Greet` gives nothing back, so it is used as a statement on its own.

## Notes to Yourself

Anything after an apostrophe is a comment. BASIC ignores it, but it helps the next person to read the program, and that person is often you:

```basic
' Work out the total cost
price = 4
count = 3
print price * count ' prints 12
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

`RND()` gives a random number from 0 up to, but not including, 1. Multiplying by 100 and taking the whole-number part with `INT` gives 0 to 99, and adding 1 makes it 1 to 100.

Some ideas for making it your own:

- Tell the player when they are within 5 of the answer.
- Let them choose how big the range is.
- Ask whether they want to play again.

## When Something Goes Wrong

Everyone's programs have mistakes in them, which are called *bugs*. When BASIC cannot understand or carry out a line, it stops and says why, and the editor marks the line. Read the message, fix the line, and run again.

If a program seems stuck, click **Stop**. The debugger (the bug button) lets you pause a program and watch its variables change one line at a time.

## Where to Go Next

- [Graphics Tutorial](TUTORIAL_GRAPHICS.md): draw shapes, colors and a clickable calculator.
- [TUIKit Tutorial](TUTORIAL_TUIKIT.md): build windows, buttons and menus in the terminal.
- [Async Programming Tutorial](TUTORIAL_ASYNC.md): do several things at once.
- [BASICrc Tutorial](TUTORIAL_BASICRC.md): set BASICShell up the way you like it.

The Reference section of this menu has a page for every statement. [PRINT](PRINT.md), [INPUT](INPUT.md), [FOR...NEXT](FOR_NEXT.md) and [FUNCTION](FUNCTION.md) are good ones to read next. The Examples menu has finished programs to run and take apart.
