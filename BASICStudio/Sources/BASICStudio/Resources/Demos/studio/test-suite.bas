#!/usr/bin/env aibasic
rem BASICStudio feature demo
' apostrophe comment alias
# shell-friendly comment alias
// slash comment alias

print "BASICSTUDIO TEST SUITE"

print "TEXT OUTPUT AND EXPRESSIONS"
let total = 10 + 5 * 2
print "TOTAL =", total
print "TOTAL NO SPACE=";total
print "COLUMNS","LEFT","RIGHT"
print "CONTINUED "; \
    "LINE"

global flag as boolean = true
print "BOOLEAN =", flag

print "NUL DISPLAY "; chr$(0); "OK"
print "LEN NUL =", len("A" + chr$(0) + "B")

name$ = "AIBASIC"
print "STRING =", name$
print "STRING:";name$

print "FOR/NEXT DEFAULT STEP"
for i = 1 to 3
    print "I =", i
next i

print "FOR/NEXT CUSTOM STEP"
for j = 5 to 1 step -2
    print "J =";j
next

print "SELECT CASE"
select case total
case 1 to 10
    print "SELECT LOW"
case 20, 25
    print "SELECT MATCH"
case is > 100
    print "SELECT HIGH"
case else
    print "SELECT ELSE"
end select

print "BLOCK IF / ELSEIF"
day = 4
hour = 12
if day = 3 then
    print "WEDNESDAY"
elseif day = 4 then
    if hour = 12 then
        print "THURSDAY NOON"
    else
        print "THURSDAY OTHER"
    end if
else
    print "OTHER DAY"
end if

print "FUNCTIONS"
print "ADD =", Add(2, 3)
print "TITLE =", Title$()

print "DIM ARRAYS"
dim scores(2) as integer
scores(0) = 10
scores(1) = 20
scores(2) = scores(0) + scores(1)
print "SCORE TOTAL =", scores(2)

print "USER TYPES"
type Student
    Name as string * 20
    Age as integer
    Grade as single
end type

dim s as Student
s.Name = "Grace"
s.Age = 17
s.Grade = 98.5
print "STUDENT =", s.Name
print "AGE =", s.Age
print "GRADE =", s.Grade

dim students(1) as Student
students(0).Name = "Ada"
students(0).Age = 16
students(1).Name = "Katherine"
students(1).Age = students(0).Age + 1
print "ROSTER 0 =", students(0).Name
print "ROSTER 1 =", students(1).Name
print "ROSTER AGE =", students(1).Age

print "INTERFACES AND CLASSES"
interface Printable
    function Title() as string
    function ToText$() as string
end interface

class Report
    implements Printable
    public Title as string
    Count as integer
    private InternalCode as string

    function Title() as string
        return ME.Title
    end function

    function Summary$() as string
        return ME.Title + " READY"
    end function

    function Text$() as string implements Printable.ToText$
        return ME.Title
    end function
end class

class FancyReport
    inherits Report
    public Badge as string

    function New(title as string, badge as string)
        ME.Title = title
        ME.Badge = badge
    end function

    overrides function Summary$() as string
        return ME.Title + " " + ME.Badge
    end function

    function Rename$(title as string) as string
        ME.Title = title
        return ME.Title
    end function
end class

dim report as Report
report = new Report()
report.Title = "Status"
report.Count = scores(2)
print "REPORT =", report.Title
print "REPORT TITLE =", report.Title()
print "REPORT SUMMARY =", report.Summary$()
print "REPORT TEXT =", report.Text$()
print "REPORT COUNT =", report.Count

dim fancy as FancyReport
fancy = new FancyReport("Phase2", "OK")
print "INHERITED SUMMARY =", fancy.Summary$()
print "RENAMED =", fancy.Rename$("Phase2B")
print "RENAMED SUMMARY =", fancy.Summary$()

if total >= 20 then Passed
print "MATH FAILED"
goto GraphicsDemo

Passed:
    print "IF/GOTO PASSED" ' trailing apostrophe comment
    gosub "SubDemo"
    goto GraphicsDemo

# hash comments are only line-start comments
LABEL "SubDemo"
    option local-let
    let scoped as integer = 7
    print "LOCAL LET =", scoped
    print "GOSUB/RETURN PASSED" // trailing slash comment
    return

GraphicsDemo:
    print "GRAPHICS DEMO": // trailing slash comment
    screen 1
    color 2
    line (240,8)-(318,8), 2
    line (318,8)-(318,58), 3
    line (318,58)-(240,58), 1
    line (240,58)-(240,8), 2
    line (240,8)-(318,58), 1
    line (318,8)-(240,58), 2
    pset (279,33), 3
    print "CENTER BEFORE =", point(279,33)
    preset (279,33)
    print "CENTER AFTER =", point(279,33)
    print "DONE"
    end

function Add(a as integer, b as integer) as integer
    return a + b
end function

function Title$() as string
    Title$ = "AIBASIC"
end function
