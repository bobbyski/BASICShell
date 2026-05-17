# FromJsonString() Function

![BASICStudio](https://img.shields.io/badge/BASICStudio-supported-brightgreen) ![BASICShell](https://img.shields.io/badge/BASICShell-supported-brightgreen)

Parses a JSON string into BASIC values. JSON objects become `DICTIONARY` values. JSON arrays become `VARIANT` arrays. JSON `null` becomes `NULL`.

The second argument controls permissive parsing. When `TRUE`, top-level JSON fragments such as strings, numbers, booleans, and `null` are accepted.

Parsed JSON can be assigned into a typed record, class, or existing typed array. Record and class decoding uses fields that opted into JSON with `JSON NAME "fieldName"`. Missing JSON fields keep the BASIC default value, and extra JSON fields are ignored. If a JSON value cannot be decoded into the target type, assignment reports `Runtime error: Type Mismatch`.

Variable-length arrays declared with `(*)` resize to match decoded JSON arrays. Empty parentheses are accepted as shorthand for one-dimensional dynamic arrays. Multidimensional dynamic arrays use one `*` per rank, and decode from nested JSON arrays.

```basic
let payload = FromJsonString("{" + chr$(34) + "name" + chr$(34) + ":" + chr$(34) + "Ada" + chr$(34) + "}", true)
print payload("name")
```

```basic
let value = FromJsonString("null", true)
print value
```

```basic
type Student
    Name as string json name "name"
    Age as integer json name "age"
end type

let student as Student
student = FromJsonString("{" + chr$(34) + "name" + chr$(34) + ":" + chr$(34) + "Ada" + chr$(34) + "," + chr$(34) + "age" + chr$(34) + ":16}", true)
print student.Name

let scores(2) as integer
scores = FromJsonString("[10,20,30]", true)
print scores(2)

let dynamicScores(*) as integer
dynamicScores = FromJsonString("[10,20,30,40]", true)
print len(dynamicScores)

let grid(*, *) as integer
grid = FromJsonString("[[1,2],[3,4]]", true)
print grid(1, 1)
```
