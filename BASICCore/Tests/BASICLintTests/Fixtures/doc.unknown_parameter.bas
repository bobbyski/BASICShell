/// Doubles a number.
///
/// - Parameter value: The number to double.
FUNCTION Twice(n AS DOUBLE) AS DOUBLE
    RETURN n * 2
END FUNCTION
PRINT Twice(4)
