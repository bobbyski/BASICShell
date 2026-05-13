class GradeEntry
    public StudentName as string
    public Assignment as string
    public Score as integer
    public Possible as integer

    function New(studentName as string, assignment as string, score as integer, possible as integer)
        ME.StudentName = studentName
        ME.Assignment = assignment
        ME.Score = score
        ME.Possible = possible
    end function

    function Percent() as double
        return (ME.Score / ME.Possible) * 100
    end function

    function Letter$() as string
        let value = ME.Percent()
        if value >= 90 then
            return "A"
        elseif value >= 80 then
            return "B"
        elseif value >= 70 then
            return "C"
        elseif value >= 60 then
            return "D"
        else
            return "F"
        end if
    end function

    function Summary$() as string
        return ME.StudentName + " " + ME.Assignment
    end function
end class
