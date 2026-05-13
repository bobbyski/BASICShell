print "AIBASIC DIAGNOSTIC TEST"
print "Fix the syntax errors first, then class/interface errors will appear."

' These should show as Monaco syntax diagnostics together.
print @
let total =
for i = 1 to

' These deeper validation errors appear after the syntax errors above are fixed.
interface Printable
    inherits MissingInterface
    function Text$() as string
end interface

class Report
    function Summary$(count as integer) as string
        return "base"
    end function
end class

class FancyReport
    inherits Report
    overrides function Summary$(count as string) as string
        return count
    end function
end class

dim report as FancyReport
report = new FancyReport()
print report.Summary$("bad")
end
