#! /usr/bin/env aibasic
print "JSON TEST SUITE"

let q$ = chr$(34)

type Student
    Name as string json name "name" = "Unknown"
    Age as integer json name "age" = 0
    Grade as single json name "grade" = 0
    Scratch as string = "not serialized"
end type

record Classroom
    Name as string json name "name"
    Students(*) as Student json name "students"
    StudentsByRowAndSeat(*, *) as Student json name "studentsByRowAndSeat"
end record

class ReportBase
    public Title as string json name "title" = "Untitled"
    public InternalId as integer = 99
end class

class DefaultJson
    public Badge as string json name "badge" = "defaultBadge"
    public Enabled as boolean json name "enabled" = true
    public Missing as variant json name "missing" = NULL
    public LocalOnly as string = "secret"
end class

class FancyReport
    inherits ReportBase
    public Badge as string json name "badge" = "defaultBadge"
    public Count as integer json name "count" = 0
    public Enabled as boolean json name "enabled" = true
    public Missing as variant json name "missing" = NULL
    public LocalOnly as string = "secret"

    function New(title as string, badge as string, count as integer)
        ME.Title = title
        ME.Badge = badge
        ME.Count = count
    end function
end class

print "CLASS DEFAULTS"
local defaultReport as DefaultJson
defaultReport = new DefaultJson()
print ToJsonString(defaultReport, false)

print "CLASS ALIASES AND EXCLUDES"
let report as FancyReport
report = new FancyReport("Quarterly", "READY", 7)
print ToJsonString(report, false)

print "PRETTY JSON"
let pretty$ = ToJsonString(report, true)
print "HAS TITLE =", instr(pretty$, q$ + "title" + q$) > 0
print "HAS LOCALONLY =", instr(pretty$, "LocalOnly") > 0

print "RECORD JSON"
let student as Student
print ToJsonString(student, false)
student.Name = "Ada"
student.Age = 16
student.Grade = 99.5
student.Scratch = "hidden"
print ToJsonString(student, false)

print "DICTIONARY JSON"
let payload as dictionary
payload("name") = "Grace"
payload("active") = true
payload("missing") = NULL
payload("score") = 98.5
print ToJsonString(payload, false)

print "ARRAY JSON"
global scores(2) as integer
scores(0) = 10
scores(1) = 20
scores(2) = 30
print ToJsonString(scores, false)
payload("scores") = scores
print ToJsonString(payload, false)

print "PARSE OBJECT"
let source$ = "{" + q$ + "name" + q$ + ":" + q$ + "Katherine" + q$ + "," + q$ + "active" + q$ + ":true," + q$ + "missing" + q$ + ":null," + q$ + "score" + q$ + ":88}"
let parsed = FromJsonString(source$, true)
print parsed("name")
print parsed("active")
print parsed("missing")
print parsed("score")

print "TYPED DECODE"
let typedStudent as Student
typedStudent = FromJsonString("{" + q$ + "name" + q$ + ":" + q$ + "Katherine" + q$ + "," + q$ + "age" + q$ + ":15," + q$ + "grade" + q$ + ":91.5}", true)
print typedStudent.Name
print typedStudent.Age
print typedStudent.Grade
let typedReport as FancyReport
typedReport = FromJsonString("{" + q$ + "title" + q$ + ":" + q$ + "Decoded" + q$ + "," + q$ + "badge" + q$ + ":" + q$ + "OK" + q$ + "," + q$ + "count" + q$ + ":4}", true)
print ToJsonString(typedReport, false)
let typedScores(2) as integer
typedScores = FromJsonString("[3,4,5]", true)
print typedScores(0) + typedScores(1) + typedScores(2)
let room as Classroom
room = FromJsonString("{" + q$ + "name" + q$ + ":" + q$ + "OS" + q$ + "," + q$ + "students" + q$ + ":[{" + q$ + "name" + q$ + ":" + q$ + "Ada" + q$ + "},{" + q$ + "name" + q$ + ":" + q$ + "Grace" + q$ + "}]," + q$ + "studentsByRowAndSeat" + q$ + ":[[{"+ q$ + "name" + q$ + ":" + q$ + "Ada" + q$ + "}],[{" + q$ + "name" + q$ + ":" + q$ + "Grace" + q$ + "}]]}", true)
print room.Name
print len(room.Students)
print len(room.StudentsByRowAndSeat)
print ToJsonString(room, false)
let grid(*, *) as integer
grid = FromJsonString("[[1,2],[3,4]]", true)
print len(grid)
print grid(1, 1)

print "PARSE ARRAY"
let parsedArray = FromJsonString("[1,null," + q$ + "two" + q$ + ",true]", true)
print parsedArray(0)
print parsedArray(1)
print parsedArray(2)
print parsedArray(3)

print "PARSE FRAGMENTS"
print FromJsonString("null", true)
print FromJsonString("123", true)
print FromJsonString(q$ + "solo" + q$, true)

print "JSON TESTS COMPLETE"
