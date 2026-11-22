' DataFolder.bas — where the app keeps its data between launches.
'
'     DataFolder$("MyApp") ──► $APP_DATA_DIR, when it is set (tests set it)
'                         └──► ~/Library/Application Support/MyApp
'
' The folder is made the first time it is asked for, so a caller can write
' into it straight away.

/// The folder the app keeps its data in, made if it is not there yet.
///
/// `APP_DATA_DIR`, when it is set, names the folder instead, so a test or a
/// second copy of the app can keep its data apart from yours.
///
/// - Parameter appName: The app's name, which names its folder in
///   Application Support.
/// - Returns: The folder's path, with no `/` at the end.
FUNCTION DataFolder$(appName AS STRING) AS STRING
    ' The override wins, so tests never touch the real Application Support.
    LOCAL folder$ = ENVIRON$("APP_DATA_DIR")
    IF folder$ = "" THEN folder$ = ENVIRON$("HOME") + "/Library/Application Support/" + appName

    ' File.Mkdir makes any missing folders on the way, as mkdir -p does.
    IF NOT File.Exists(folder$) THEN File.Mkdir folder$
    RETURN folder$
END FUNCTION
