class Student
    public Id as integer
    public Name as string

    function New(id as integer, name as string)
        ME.Id = id
        ME.Name = name
    end function

    function Label$() as string
        return ME.Name
    end function
end class
