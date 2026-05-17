#! /usr/bin/env aibasic
' File class example.
' Uses the modern File system class:
'   File()
'   file.open(nameOrUrl, access, type, requireNew)
'   File(nameOrUrl, access, type, requireNew)
'   file.json()
'   file.writeJson(value, pretty)
'   file.size()
'   file.close

print "FILE JSON GRADE REPORT"

type GradeEntry
    Student as string json name "student"
    Assignment as string json name "assignment"
    Score as integer json name "score"
    Possible as integer json name "possible"
end type

record GradeReport
    Course as string json name "course"
    Teacher as string json name "teacher"
    Entries(*) as GradeEntry json name "entries"
end record

let report as GradeReport
report.Course = "Intro to BASIC"
report.Teacher = "Ms. Ada"
let q$ = chr$(34)
let entries$ = "[{"
entries$ = entries$ + q$ + "student" + q$ + ":" + q$ + "Ada Lovelace" + q$
entries$ = entries$ + "," + q$ + "assignment" + q$ + ":" + q$ + "Loops" + q$
entries$ = entries$ + "," + q$ + "score" + q$ + ":18," + q$ + "possible" + q$ + ":20}"
entries$ = entries$ + ",{" + q$ + "student" + q$ + ":" + q$ + "Grace Hopper" + q$
entries$ = entries$ + "," + q$ + "assignment" + q$ + ":" + q$ + "Classes" + q$
entries$ = entries$ + "," + q$ + "score" + q$ + ":47," + q$ + "possible" + q$ + ":50}"
entries$ = entries$ + ",{" + q$ + "student" + q$ + ":" + q$ + "Katherine Johnson" + q$
entries$ = entries$ + "," + q$ + "assignment" + q$ + ":" + q$ + "Imports" + q$
entries$ = entries$ + "," + q$ + "score" + q$ + ":29," + q$ + "possible" + q$ + ":30}]"
report.Entries = FromJsonString(entries$, true)

print "WRITING grade-report.json"
let output = File()
output.open("grade-report.json", WRITE, JSON, false)
output.writeJson(report, true)
print "BYTES ="; output.size()
output.close

print "READING grade-report.json"
let input = File("grade-report.json", READ, JSON, false)
let loaded as GradeReport
loaded = input.json()
input.close

print loaded.Course
print loaded.Teacher
print "ENTRIES ="; len(loaded.Entries)
print loaded.Entries(0).Student, loaded.Entries(0).Score
print loaded.Entries(1).Student, loaded.Entries(1).Score
print loaded.Entries(2).Student, loaded.Entries(2).Score

print "FILE JSON GRADE REPORT COMPLETE"
