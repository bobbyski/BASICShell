' TaskListView.bas — the New task field, and the list of tasks under it.
'
'     ┌──────────────────────────────┐
'     │ New task                     │  the field: Return adds it
'     ├──────────────────────────────┤
'     │ ☐ Try this program           │
'     │ ☐ Pick a task, then press …  │  one row a task
'     │ ☑ Open the To-Do List        │  ☑ is done
'     └──────────────────────────────┘
'
' The view shows the tasks and reports what the person does; it never
' changes a task itself. The controller names the handlers.

/// The field a new task is typed in, and the list that shows every task.
CLASS TaskListView
    /// The New task field.
    PUBLIC NewTaskField AS VARIANT
    /// The list, one row a task.
    PUBLIC Rows AS VARIANT

    /// Makes the field and the list, and puts them in a window.
    ///
    /// - Parameter window: The window to add them to, top to bottom.
    FUNCTION Build(window AS VARIANT) AS VOID
        ME.NewTaskField = AUIField("", "New task")
        ME.Rows = AUIList()
        window.add(ME.NewTaskField)
        window.add(ME.Rows)
    END FUNCTION

    /// Shows every task, with one picked.
    ///
    /// Swift's To-Do List gives each row a checkbox and strikes a done task
    /// through. BASIC's AUIList rows are text, with no checkbox and no
    /// strike-through yet, so ☐ and ☑ in front of the title stand in.
    ///
    /// - Parameter tasks: The tasks to show.
    /// - Parameter picked: The picked row, or -1 for none.
    FUNCTION Show(tasks AS TaskList, picked AS INTEGER) AS VOID
        ' The list is filled again from the tasks, which are the truth.
        ME.Rows.clear()
        LOCAL box$ = ""
        LOCAL row = 0
        FOR row = 0 TO tasks.Count - 1
            box$ = "☐ "
            IF tasks.Tasks(row).IsDone THEN box$ = "☑ "
            ME.Rows.add(box$ + tasks.Tasks(row).Title)
        NEXT row
        ' Filling the list drops its selection, so the picked row is picked
        ' again. Picking in code reports nothing, so no handler runs.
        ME.Rows.select(picked)
    END FUNCTION

    /// What the New task field holds.
    ///
    /// - Returns: The text typed so far.
    FUNCTION NewTaskText$() AS STRING
        RETURN ME.NewTaskField.text$()
    END FUNCTION

    /// Empties the New task field, once its task is added.
    FUNCTION ClearField() AS VOID
        ME.NewTaskField.text("")
    END FUNCTION
END CLASS
