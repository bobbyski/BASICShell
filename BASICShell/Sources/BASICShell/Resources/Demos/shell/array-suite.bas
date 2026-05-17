#! /usr/bin/env aibasic
print "ARRAY BASELINE SUITE"

type Student
    Name as string json name "name"
    Age as integer json name "age"
    Scores(*) as integer json name "scores"
end type

record Classroom
    Name as string json name "name"
    Students(*) as Student json name "students"
    Grid(*, *) as integer json name "grid"
end record

print "SCALAR ARRAY"
dim nums(4) as integer
for i = 0 to 4
    nums(i) = (i + 1) * 10
next i
print "LEN NUMS ="; len(nums)
print "NUMS(0) ="; nums(0)
print "NUMS(4) ="; nums(4)

print "DYNAMIC ARRAY FROM JSON"
let dyn(*) as integer
dyn = FromJsonString("[3,6,9,12]", true)
print "LEN DYN ="; len(dyn)
print "DYN(2) ="; dyn(2)

print "STRING ARRAY"
dim names$(2)
names$(0) = "Ada"
names$(1) = "Grace"
names$(2) = names$(0) + " + " + names$(1)
print names$(2)

print "ARRAY OF RECORDS"
dim roster(1) as Student
roster(0).Name = "Ada"
roster(0).Age = 16
roster(1).Name = "Grace"
roster(1).Age = 17
print roster(0).Name
print roster(1).Age
print ToJsonString(roster, false)

print "FIXED 2D ARRAY"
dim grid(1, 2) as integer
for row = 0 to 1
    for col = 0 to 2
        grid(row, col) = row * 10 + col
    next col
next row
print "LEN GRID ="; len(grid)
print "GRID(1,2) ="; grid(1, 2)

print "DYNAMIC 2D ARRAY FROM JSON"
let dynGrid(*, *) as integer
dynGrid = FromJsonString("[[1,2,3],[4,5,6]]", true)
print "LEN DYNGRID ="; len(dynGrid)
print "DYNGRID(1,2) ="; dynGrid(1, 2)
print ToJsonString(dynGrid, false)

print "RECORD CONTAINING ARRAYS FROM JSON"
let q$ = chr$(34)
let room as Classroom
room = FromJsonString("{" + q$ + "name" + q$ + ":" + q$ + "Lab" + q$ + "," + q$ + "students" + q$ + ":[{" + q$ + "name" + q$ + ":" + q$ + "Ada" + q$ + "," + q$ + "age" + q$ + ":16," + q$ + "scores" + q$ + ":[90,95]},{" + q$ + "name" + q$ + ":" + q$ + "Grace" + q$ + "," + q$ + "age" + q$ + ":17," + q$ + "scores" + q$ + ":[98,99]}]," + q$ + "grid" + q$ + ":[[7,8],[9,10]]}", true)
print room.Name
print "LEN STUDENTS ="; len(room.Students)
print "LEN ROOM GRID ="; len(room.Grid)
print ToJsonString(room, false)

print "KNOWN GAPS - COMMENTED"
' Field array element access needs segmented reference parsing:
' print room.Students(1).Name
' print room.Students(1).Scores(0)
' print room.Grid(1, 1)
'
' Direct mutation of array fields also needs segmented indexed field paths:
' room.Students(0).Scores(0) = 100
' room.Grid(0, 0) = 42

print "ARRAY BASELINE COMPLETE"
