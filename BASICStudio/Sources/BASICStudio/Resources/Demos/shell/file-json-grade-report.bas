#! /usr/bin/env aibasic
' Forward-looking File class example.
' Requires the planned File system class:
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
report.Entries = FromJsonString("[{" + chr$(34) + "student" + chr$(34) + ":" + chr$(34) + "Ada Lovelace" + chr$(34) + "," + chr$(34) + "assignment" + chr$(34) + ":" + chr$(34) + "Loops" + chr$(34) + "," + chr$(34) + "score" + chr$(34) + ":18," + chr$(34) + "possible" + chr$(34) + ":20},{" + chr$(34) + "student" + chr$(34) + ":" + chr$(34) + "Grace Hopper" + chr$(34) + "," + chr$(34) + "assignment" + chr$(34) + ":" + chr$(34) + "Classes" + chr$(34) + "," + chr$(34) + "score" + chr$(34) + ":47," + chr$(34) + "possible" + chr$(34) + ":50},{" + chr$(34) + "student" + chr$(34) + ":" + chr$(34) + "Katherine Johnson" + chr$(34) + "," + chr$(34) + "assignment" + chr$(34) + ":" + chr$(34) + "Imports" + chr$(34) + "," + chr$(34) + "score" + chr$(34) + ":29," + chr$(34) + "possible" + chr$(34) + ":30}]", true)

print "WRITING grade-report.json"
let output = File()
output.open("grade-report.json", WRITE, JSON, true)
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
