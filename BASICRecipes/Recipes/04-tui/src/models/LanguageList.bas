' LanguageList.bas — the languages the list offers.
'
' Plain BASIC: nothing here knows there is a screen, so the same list works
' in a program that only prints.

/// The languages to pick from, in the order they are listed.
///
/// This BASIC has no REDIM, so the places are made once at their most
/// (``Capacity``) and `Count` says how many are real.
CLASS LanguageList
    /// Every place there can be; the first `Count` hold names.
    PUBLIC Names(20) AS STRING
    /// How many languages there are.
    PUBLIC Count AS INTEGER

    /// How many languages the list can hold: the size `Names` is made with.
    ///
    /// - Returns: 20.
    FUNCTION Capacity() AS INTEGER
        RETURN 20
    END FUNCTION

    /// Adds a language at the end; a full list keeps what it has.
    ///
    /// - Parameter language: Its name.
    FUNCTION Add(language AS STRING) AS VOID
        IF ME.Count >= ME.Capacity() THEN RETURN
        ME.Names(ME.Count) = language
        ME.Count = ME.Count + 1
    END FUNCTION
END CLASS

/// The languages the program starts with. Add your own here.
///
/// - Returns: BASIC and Swift.
FUNCTION StarterLanguages() AS LanguageList
    LOCAL languages AS LanguageList
    languages = NEW LanguageList()
    languages.Add("BASIC")
    languages.Add("Swift")
    RETURN languages
END FUNCTION
