' TaskStore.bas — the tasks between launches: tasks.txt, in and out.
'
'     ReadTasks(path)          ──► a TaskList (three samples on a first run)
'     WriteTasks(path, tasks)  ──► tasks.txt, replaced whole
'
' One task a line, in TabSeparated.bas's format: `done` or `todo`, a tab,
' and the title. The controller writes after every change, so quitting
' never loses anything.

/// The tasks a file holds, or the samples a first launch starts with.
///
/// - Parameter path: The file, such as `.../Application Support/MyApp/tasks.txt`.
/// - Returns: The tasks, in the file's order.
FUNCTION ReadTasks(path AS STRING) AS TaskList
    LOCAL tasks AS TaskList
    tasks = NEW TaskList()

    ' No file yet: this is the first launch, so start with something to try.
    IF NOT File.Exists(path) THEN
        tasks.Add("Try this program", FALSE)
        tasks.Add("Pick a task, then press Done", FALSE)
        tasks.Add("Open the To-Do List", TRUE)
        RETURN tasks
    END IF

    ' Each line is one task; a blank line (the last one) is none.
    LOCAL text$ = File.ReadText$(path)
    LOCAL start = 1
    LOCAL entry$ = ""
    LOCAL isDone AS BOOLEAN
    WHILE start <= LEN(text$)
        entry$ = LineAt$(text$, start)
        IF entry$ <> "" THEN
            ' A comparison is a number here, not a BOOLEAN, so the state is
            ' set in two steps.
            isDone = FALSE
            IF FieldAt$(entry$, 0) = "done" THEN isDone = TRUE
            tasks.Add(FieldAt$(entry$, 1), isDone)
        END IF
        start = start + LEN(entry$) + 1
    WEND
    RETURN tasks
END FUNCTION

/// Writes every task to a file, replacing what it held.
///
/// - Parameter path: The file.
/// - Parameter tasks: The tasks to keep.
FUNCTION WriteTasks(path AS STRING, tasks AS TaskList) AS VOID
    LOCAL text$ = ""
    LOCAL state$ = ""
    LOCAL row = 0
    ' One line a task: its state, a tab, and its title, escaped.
    FOR row = 0 TO tasks.Count - 1
        state$ = "todo"
        IF tasks.Tasks(row).IsDone THEN state$ = "done"
        text$ = text$ + state$ + CHR$(9) + EscapeField$(tasks.Tasks(row).Title) + CHR$(10)
    NEXT row
    File.WriteText path, text$
END FUNCTION
