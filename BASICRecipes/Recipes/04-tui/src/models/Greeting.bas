' Greeting.bas — what the program says back.
'
' Plain BASIC, like LanguageList.bas: the words, with no screen in them.

/// What the program says to someone who typed their name.
///
/// - Parameter person: The name typed, or "" for none yet.
/// - Returns: Such as "Hello, Ada!", or how to get one.
FUNCTION GreetingFor$(person AS STRING) AS STRING
    IF person = "" THEN RETURN "Type a name in the field first."
    RETURN "Hello, " + person + "!"
END FUNCTION

/// What the status line says about a picked language.
///
/// - Parameter language: The language picked.
/// - Returns: Such as "Language: BASIC".
FUNCTION LanguageText$(language AS STRING) AS STRING
    RETURN "Language: " + language
END FUNCTION
