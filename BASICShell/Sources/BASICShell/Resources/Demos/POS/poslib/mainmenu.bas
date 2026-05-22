class MainMenu
    function Show() as integer
        dim choices(2) as string
        choices(0) = "Point of Sale"
        choices(1) = "Add or edit parts"
        choices(2) = "Exit app"
        return Me.Choose(choices)
    end function

    function Choose(choices as variant) as integer
        let selected = 1
        let count = len(choices)
        let longest = 0
        let topRow = 7
        let key$ = ""
        let escape$ = chr$(27)
        let reverse$ = escape$ + "[7m"
        let normal$ = escape$ + "[0;32;40m"
        let i = 0
        let label$ = ""
        let menuWidth = 0
        let leftColumn = 1

MeasureOptions:
        for i = 0 to count - 1
            label$ = chr$(49 + i) + ". " + choices(i)
            if len(label$) > longest then longest = len(label$)
        next i

        menuWidth = longest + 4
        leftColumn = int((SCREENWIDTH - menuWidth) / 2) + 1
        if leftColumn < 1 then leftColumn = 1

FlushKeys:
        key$ = inkey$
        if key$ <> "" then FlushKeys

RenderMenu:
        for i = 0 to count - 1
            label$ = chr$(49 + i) + ". " + choices(i)
            locate topRow + i, leftColumn
            print normal$ + space$(menuWidth);
            locate topRow + i, leftColumn
            if selected = i + 1 then print reverse$ + space$(2) + label$ + space$(menuWidth - len(label$) - 2) + normal$ else print normal$ + space$(2) + label$
        next i

WaitForKey:
        key$ = inkey$
        if key$ = "" then WaitForKey

        if key$ = "[H" then selected = selected - 1
        if key$ = "[P" then selected = selected + 1
        if key$ = "[GP:DPAD_UP" then selected = selected - 1
        if key$ = "[GP:LEFT_STICK_UP" then selected = selected - 1
        if key$ = "[GP:RIGHT_STICK_UP" then selected = selected - 1
        if key$ = "[GP:DPAD_DOWN" then selected = selected + 1
        if key$ = "[GP:LEFT_STICK_DOWN" then selected = selected + 1
        if key$ = "[GP:RIGHT_STICK_DOWN" then selected = selected + 1

        if selected < 1 then selected = count
        if selected > count then selected = 1

        if key$ = chr$(13) then AcceptSelection
        if key$ = chr$(10) then AcceptSelection
        if key$ = "[GP:A" then AcceptSelection

        goto RenderMenu

AcceptSelection:
        return selected
    end function
end class
