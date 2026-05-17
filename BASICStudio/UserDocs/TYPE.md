# TYPE Statement

![BASICStudio](https://img.shields.io/badge/BASICStudio-supported-brightgreen) ![BASICShell](https://img.shields.io/badge/BASICShell-supported-brightgreen)

Defines a user record type with named fields. Fields use `AS <type>`, and fixed-length string metadata such as `STRING * 20` is accepted. `RECORD ... END RECORD` is also accepted as an alias.

Fields may include literal defaults and opt-in JSON metadata. `JSON NAME "fieldName"` includes that field in `ToJsonString()` output with the given case-sensitive JSON name. Fields without JSON metadata are excluded from record JSON output.

```basic
type Student
    Name as string * 20 json name "name"
    Age as integer
    Grade as single
end type
```

Use `DIM` to create record variables, then access fields with dotted notation.

```basic
dim s as Student
s.Name = "Grace"
s.Age = 17
s.Grade = 98.5

print s.Name
print s.Age
print s.Grade
```

Arrays of records are supported too.

```basic
dim students(1) as Student
students(0).Name = "Ada"
students(1).Name = "Grace"
print students(1).Name
```

Record fields may also declare variable-length arrays. Use `(*)` for a dynamic one-dimensional array and `(*, *)` for a dynamic two-dimensional array. Empty parentheses are accepted as shorthand for a one-dimensional dynamic array, but `*` is clearer when the field is intended to resize from JSON.

```basic
record Classroom
    Name as string json name "name"
    Students(*) as Student json name "students"
    StudentsByRowAndSeat(*, *) as Student json name "studentsByRowAndSeat"
end record
```
