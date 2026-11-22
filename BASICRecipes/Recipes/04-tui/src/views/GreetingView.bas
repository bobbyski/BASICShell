' GreetingView.bas — the window's content: the banner, the name field and
' the list of languages.
'
'     ┌ {{NAME}} ───────────────────────┐
'     │ Tab to move, Enter to press.     │  the banner: what just happened
'     │ Type a name, then press Greet    │
'     │ [your name                     ] │
'     │ BASIC                            │  the languages
'     │ Swift                            │
'     └──────────────────────────────────┘
'
' The view shows what it is given and reports what the person does; the
' controller decides what that means.

/// The banner, the name field and the list of languages, in one column.
CLASS GreetingView
    /// The line at the top that says what just happened.
    PUBLIC Banner AS VARIANT
    /// The field a name is typed in.
    PUBLIC NameField AS VARIANT
    /// The languages to pick from.
    PUBLIC Choices AS VARIANT

    /// Makes the column of controls.
    ///
    /// - Parameter languages: The languages to list.
    /// - Returns: The column, for the window to hold.
    FUNCTION Build(languages AS LanguageList) AS VARIANT
        ME.Banner = TUILabel("Tab to move, Enter to press.")
        ME.NameField = TUIField("your name")
        ME.Choices = TUIList()
        LOCAL i = 0
        FOR i = 0 TO languages.Count - 1
            ME.Choices.additem(languages.Names(i))
        NEXT i

        ' Top to bottom: the banner, a hint, the field, the list.
        LOCAL page = TUIStack("v")
        page.add(ME.Banner)
        page.add(TUILabel("Type a name, then press Greet"))
        page.add(ME.NameField)
        page.add(ME.Choices)
        RETURN page
    END FUNCTION

    /// Says something in the banner.
    ///
    /// - Parameter message: What to say.
    FUNCTION Say(message AS STRING) AS VOID
        ME.Banner.text(message)
    END FUNCTION

    /// What the banner says now.
    ///
    /// - Returns: Its text.
    FUNCTION Said$() AS STRING
        RETURN ME.Banner.value$()
    END FUNCTION

    /// The name typed so far.
    ///
    /// - Returns: The field's text.
    FUNCTION TypedName$() AS STRING
        RETURN ME.NameField.value$()
    END FUNCTION

    /// The language picked in the list.
    ///
    /// - Returns: Its name, or "" for none.
    FUNCTION PickedLanguage$() AS STRING
        RETURN ME.Choices.selectedtext$()
    END FUNCTION
END CLASS
