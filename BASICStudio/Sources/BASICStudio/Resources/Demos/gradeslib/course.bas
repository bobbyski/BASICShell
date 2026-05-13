class Course
    public Title as string
    public Teacher as string

    function New(title as string, teacher as string)
        ME.Title = title
        ME.Teacher = teacher
    end function

    function Header$() as string
        return ME.Title + " / " + ME.Teacher
    end function
end class
