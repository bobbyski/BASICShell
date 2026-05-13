import "gradeslib/"

print "TEACHER GRADE BOOK"

dim course as Course
course = new Course("Intro to BASIC", "Ms. Ada")
print course.Header$()
print

dim ada as Student
dim grace as Student
dim katherine as Student

ada = new Student(1, "Ada Lovelace")
grace = new Student(2, "Grace Hopper")
katherine = new Student(3, "Katherine Johnson")

dim entry1 as GradeEntry
dim entry2 as GradeEntry
dim entry3 as GradeEntry

entry1 = new GradeEntry(ada.Label$(), "Loops", 18, 20)
entry2 = new GradeEntry(grace.Label$(), "Classes", 47, 50)
entry3 = new GradeEntry(katherine.Label$(), "Imports", 29, 30)

print "STUDENT", "ASSIGNMENT", "SCORE", "GRADE"
print entry1.StudentName, entry1.Assignment, entry1.Score, entry1.Letter$()
print entry2.StudentName, entry2.Assignment, entry2.Score, entry2.Letter$()
print entry3.StudentName, entry3.Assignment, entry3.Score, entry3.Letter$()

print
print "DETAILS"
print entry1.Summary$(), entry1.Percent()
print entry2.Summary$(), entry2.Percent()
print entry3.Summary$(), entry3.Percent()
end
