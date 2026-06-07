class ViewEditor
    function Edit(value as variant) as variant
        return Me.EditAt(value, 1, 1, SCREENWIDTH, SCREENHEIGHT)
    end function

    function EditAt(value as variant, top as integer, left as integer, width as integer, height as integer) as variant
        let selected = 0
        let key$ = ""
        let entry$ = ""
        let count = fieldcount(value)
        let bottom = top + height - 1
        let escape$ = chr$(27)
        let normal$ = escape$ + "[0;32;40m"
        let reverse$ = escape$ + "[7m"
        let i = 0
        let label$ = ""
        let valueText$ = ""
        let meta as dictionary
        let fieldName$ = ""
        let fieldWidth = 20

        if top < 1 then top = 1
        if left < 1 then left = 1
        if width < 1 then width = SCREENWIDTH
        if height < 1 then height = SCREENHEIGHT

RenderEditor:
        print normal$;
        locate top, left
        print "Add / Edit Part"
        locate top + 1, left
        print string$(width, "-")

        for i = 0 to count - 1
            meta = fieldmeta(value, i)
            label$ = meta("label")
            if label$ = "" then label$ = fieldname$(value, i)
            valueText$ = fieldvalue$(value, i)
            locate top + 3 + i, left
            print space$(width);
            locate top + 3 + i, left
            print label$
            locate top + 3 + i, left + 18
            print valueText$
        next i

        locate bottom - 1, left
        print space$(width);
        locate bottom - 1, left
        print "Enter advances. F10 saves. Escape cancels."

EditField:
        fieldName$ = fieldname$(value, selected)
        meta = fieldmeta(value, selected)
        label$ = meta("label")
        if label$ = "" then label$ = fieldName$
        fieldWidth = meta("width")
        if fieldWidth < 1 then fieldWidth = 20

        locate top + 3 + selected, left + 18
        print space$(width - 18);
        locate top + 3 + selected, left + 18
        line input entry$ length fieldWidth default valueText$ exitvar key$
        if key$ <> chr$(27) then value = setfield(value, fieldName$, entry$)
        if key$ = "[F10" then return value
        if key$ = chr$(27) then return value
        if key$ = "[H" then selected = selected - 1: goto RenderEditor
        if key$ = "[P" then selected = selected + 1: goto RenderEditor
        if key$ = "[GP:DPAD_UP" then selected = selected - 1: goto RenderEditor
        if key$ = "[GP:DPAD_DOWN" then selected = selected + 1: goto RenderEditor
        selected = selected + 1
        if selected >= count then selected = 0
        goto RenderEditor
    end function
end class
