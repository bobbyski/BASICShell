FUNCTION Tangled(n AS INTEGER) AS INTEGER
    IF n = 0 THEN
        RETURN 0
    END IF
    IF n = 1 THEN
        RETURN 1
    END IF
    IF n = 2 THEN
        RETURN 2
    END IF
    IF n = 3 THEN
        RETURN 3
    END IF
    IF n = 4 THEN
        RETURN 4
    END IF
    IF n = 5 THEN
        RETURN 5
    END IF
    IF n = 6 THEN
        RETURN 6
    END IF
    IF n = 7 THEN
        RETURN 7
    END IF
    IF n = 8 THEN
        RETURN 8
    END IF
    IF n = 9 THEN
        RETURN 9
    END IF
    IF n = 10 THEN
        RETURN 10
    END IF
    IF n = 11 THEN
        RETURN 11
    END IF
    RETURN 0
END FUNCTION
PRINT Tangled(1)
