' TaskList.bas — the tasks, in the order they were added.
'
'     controller ──► Add / MarkDone / Remove / ClearDone ──► the tasks
'     views      ◄── Count, Tasks(row), ToDoCount, DoneCount
'
' Like TodoTask, it knows nothing of windows or files: the controller
' changes it, the views read it, and TaskStore.bas reads and writes it.

/// The tasks, oldest first, and what can be done with them.
///
/// A task is found by its row, from 0, which is where the list on screen
/// shows it too. This BASIC has no REDIM, so the rows are made once at
/// their most (``Capacity``) and `Count` says how many are real.
CLASS TaskList
    /// Every row there can be; the first `Count` hold tasks.
    PUBLIC Tasks(200) AS TodoTask
    /// How many tasks there are.
    PUBLIC Count AS INTEGER

    /// How many tasks the list can hold: the size `Tasks` is made with.
    ///
    /// - Returns: 200.
    FUNCTION Capacity() AS INTEGER
        RETURN 200
    END FUNCTION

    /// Whether a row holds a task.
    ///
    /// - Parameter row: The row, from 0; -1 means none.
    /// - Returns: TRUE when there is a task at `row`.
    FUNCTION HasRow(row AS INTEGER) AS BOOLEAN
        IF row >= 0 AND row < ME.Count THEN RETURN TRUE
        RETURN FALSE
    END FUNCTION

    /// Whether there is room for one more task.
    ///
    /// - Returns: TRUE until every row holds a task.
    FUNCTION HasRoom() AS BOOLEAN
        IF ME.Count < ME.Capacity() THEN RETURN TRUE
        RETURN FALSE
    END FUNCTION

    /// Adds a task at the end.
    ///
    /// - Parameter title: What to do.
    /// - Parameter isDone: Whether it is done already.
    FUNCTION Add(title AS STRING, isDone AS BOOLEAN) AS VOID
        ' A full list keeps what it has; the New Task command is grayed out
        ' before this can happen.
        IF NOT ME.HasRoom() THEN RETURN
        ME.Tasks(ME.Count).Title = title
        ME.Tasks(ME.Count).IsDone = isDone
        ME.Count = ME.Count + 1
    END FUNCTION

    /// Marks a task as done.
    ///
    /// - Parameter row: The task's row.
    FUNCTION MarkDone(row AS INTEGER) AS VOID
        IF ME.HasRow(row) THEN ME.Tasks(row).IsDone = TRUE
    END FUNCTION

    /// Whether a task can be marked as done: it is there, and still to do.
    ///
    /// - Parameter row: The task's row.
    /// - Returns: TRUE when the task at `row` is still to do.
    FUNCTION CanMarkDone(row AS INTEGER) AS BOOLEAN
        IF NOT ME.HasRow(row) THEN RETURN FALSE
        IF ME.Tasks(row).IsDone THEN RETURN FALSE
        RETURN TRUE
    END FUNCTION

    /// Takes a task off the list; the ones after it move up a row.
    ///
    /// - Parameter row: The task's row.
    FUNCTION Remove(row AS INTEGER) AS VOID
        IF NOT ME.HasRow(row) THEN RETURN
        LOCAL i = 0
        FOR i = row TO ME.Count - 2
            ME.Tasks(i) = ME.Tasks(i + 1)
        NEXT i
        ME.Count = ME.Count - 1
    END FUNCTION

    /// Takes every done task off the list, keeping the rest in order.
    FUNCTION ClearDone() AS VOID
        LOCAL kept = 0
        LOCAL i = 0
        ' Each task still to do moves up to the next free row.
        FOR i = 0 TO ME.Count - 1
            IF NOT ME.Tasks(i).IsDone THEN
                ME.Tasks(kept) = ME.Tasks(i)
                kept = kept + 1
            END IF
        NEXT i
        ME.Count = kept
    END FUNCTION

    /// Whether any task is done, for Clear Done.
    ///
    /// - Returns: TRUE when at least one task is done.
    FUNCTION HasDone() AS BOOLEAN
        IF ME.DoneCount() > 0 THEN RETURN TRUE
        RETURN FALSE
    END FUNCTION

    /// How many tasks are still to do.
    ///
    /// - Returns: The count.
    FUNCTION ToDoCount() AS INTEGER
        RETURN ME.Count - ME.DoneCount()
    END FUNCTION

    /// How many tasks are done.
    ///
    /// - Returns: The count.
    FUNCTION DoneCount() AS INTEGER
        LOCAL done = 0
        LOCAL i = 0
        FOR i = 0 TO ME.Count - 1
            IF ME.Tasks(i).IsDone THEN done = done + 1
        NEXT i
        RETURN done
    END FUNCTION
END CLASS
