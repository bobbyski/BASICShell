# TYPE Statement

![BASICStudio](https://img.shields.io/badge/BASICStudio-supported-brightgreen) ![BASICShell](https://img.shields.io/badge/BASICShell-supported-brightgreen)

Defines a user record type with named fields. Fields use `AS <type>`, and fixed-length string metadata such as `STRING * 20` is accepted.

```basic
type Student
    Name as string * 20
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
