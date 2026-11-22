' TodoTask.bas — one task.
'
' Plain BASIC: nothing here knows there is a window, so the same task works
' in a program with no screen at all.

/// One thing to do, and whether it is done.
TYPE TodoTask
    /// What to do, as the person typed it.
    Title AS STRING
    /// Whether it is done: the list ticks it, and Clear Done removes it.
    IsDone AS BOOLEAN
END TYPE
