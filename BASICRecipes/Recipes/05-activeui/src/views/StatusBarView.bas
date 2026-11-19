' StatusBarView.bas — the line along the bottom that counts the tasks.
'
'     2 to do · 1 done

/// The status line: how many tasks are still to do, and how many are done.
CLASS StatusBarView
    /// The label the counts are written in.
    PUBLIC CountsLabel AS VARIANT

    /// Makes the status line and puts it in a window.
    ///
    /// - Parameter window: The window to add it to, at the bottom.
    FUNCTION Build(window AS VARIANT) AS VOID
        ME.CountsLabel = AUILabel("")
        window.add(ME.CountsLabel)
    END FUNCTION

    /// Shows the counts for the tasks.
    ///
    /// - Parameter tasks: The tasks to count.
    FUNCTION Show(tasks AS TaskList) AS VOID
        ME.CountsLabel.text(StatusText$(tasks))
    END FUNCTION
END CLASS

/// What the status line says about the tasks.
///
/// - Parameter tasks: The tasks to count.
/// - Returns: Such as "2 to do · 1 done".
FUNCTION StatusText$(tasks AS TaskList) AS STRING
    ' STR$ puts a space in front of a number; MID$ takes it off.
    RETURN MID$(STR$(tasks.ToDoCount()), 2) + " to do · " + MID$(STR$(tasks.DoneCount()), 2) + " done"
END FUNCTION
