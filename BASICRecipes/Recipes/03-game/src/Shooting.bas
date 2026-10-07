' Shooting.bas — shots, targets, and what happens when they meet.
'
' Shots keeps every shot in the air; Targets keeps the four targets. Each
' looks after itself. CheckHits, at the bottom, is where they meet: it
' asks the guard and the targets whether each shot hit them, and keeps the
' score.

' MARK: - Shots

CLASS Shots
    ' One place for each shot that can be in the air at once (MAXSHOTS).
    ' Flying is 1 for a shot in flight and 0 for a free place; X and Y are
    ' where it is, and VX and VY how far it goes each frame.
    PUBLIC Flying(8) AS INTEGER
    PUBLIC X(8) AS DOUBLE
    PUBLIC Y(8) AS DOUBLE
    PUBLIC VX(8) AS DOUBLE
    PUBLIC VY(8) AS DOUBLE

    ' A shot from (fromX, fromY) flying `way` at SHOTSPEED, in the first free
    ' place. With every place in flight, it does nothing.
    FUNCTION Fire(fromX AS DOUBLE, fromY AS DOUBLE, way AS DOUBLE) AS VOID
        LOCAL s = 0
        FOR s = 0 TO MAXSHOTS - 1
            IF ME.Flying(s) = 0 THEN
                ME.Flying(s) = 1
                ME.X(s) = fromX
                ME.Y(s) = fromY
                ME.VX(s) = COS(way) * SHOTSPEED
                ME.VY(s) = SIN(way) * SHOTSPEED
                RETURN
            END IF
        NEXT s
    END FUNCTION

    ' Every shot in the air moves on; one that leaves the floor lands.
    FUNCTION Fly() AS VOID
        LOCAL s = 0
        FOR s = 0 TO MAXSHOTS - 1
            IF ME.Flying(s) = 1 THEN
                ME.X(s) = ME.X(s) + ME.VX(s)
                ME.Y(s) = ME.Y(s) + ME.VY(s)
                IF ME.X(s) < 0 OR ME.X(s) > WORLDWIDTH OR ME.Y(s) < 0 OR ME.Y(s) > WORLDHEIGHT THEN ME.Land(s)
            END IF
        NEXT s
    END FUNCTION

    ' Shot `s` is done: its place is free again, and its shape is gone.
    FUNCTION Land(s AS INTEGER) AS VOID
        ME.Flying(s) = 0
        vtg.delete("shot" + Num$(s))
    END FUNCTION

    FUNCTION Render() AS VOID
        LOCAL s = 0
        FOR s = 0 TO MAXSHOTS - 1
            IF ME.Flying(s) = 1 THEN vtg.circle("shot" + Num$(s), theView.PixelX(ME.X(s)), theView.PixelY(ME.Y(s)), theView.Pixels(3), "none", "#fde047", 0, 3)
        NEXT s
    END FUNCTION
END CLASS

' MARK: - Targets

CLASS Targets
    ' Where each target stands (TARGETCOUNT of them), and how many more
    ' frames it flashes after a hit.
    PUBLIC X(4) AS DOUBLE
    PUBLIC Y(4) AS DOUBLE
    PUBLIC Flash(4) AS INTEGER

    ' One in each quarter of the floor, well away from where the player
    ' starts.
    FUNCTION PlaceFour() AS VOID
        ME.X(0) = 120
        ME.Y(0) = 110
        ME.X(1) = 520
        ME.Y(1) = 110
        ME.X(2) = 120
        ME.Y(2) = 370
        ME.X(3) = 520
        ME.Y(3) = 370
    END FUNCTION

    ' Whether a shot at (shotX, shotY) hits a target. The one hit flashes.
    FUNCTION HitAt(shotX AS DOUBLE, shotY AS DOUBLE) AS INTEGER
        LOCAL t = 0
        FOR t = 0 TO TARGETCOUNT - 1
            IF Distance(shotX, shotY, ME.X(t), ME.Y(t)) < TARGETSIZE THEN
                ME.Flash(t) = 8
                RETURN 1
            END IF
        NEXT t
        RETURN 0
    END FUNCTION

    ' A frame less of flashing.
    FUNCTION Fade() AS VOID
        LOCAL t = 0
        FOR t = 0 TO TARGETCOUNT - 1
            IF ME.Flash(t) > 0 THEN ME.Flash(t) = ME.Flash(t) - 1
        NEXT t
    END FUNCTION

    ' A target is two rings and a middle, bright while it flashes.
    FUNCTION Render() AS VOID
        LOCAL t = 0
        FOR t = 0 TO TARGETCOUNT - 1
            LOCAL ring$ = "#ef4444"
            IF ME.Flash(t) > 0 THEN ring$ = "#fde047"
            LOCAL px = theView.PixelX(ME.X(t))
            LOCAL py = theView.PixelY(ME.Y(t))
            vtg.circle("target" + Num$(t), px, py, theView.Pixels(TARGETSIZE), ring$, "#000000", theView.Pixels(3), 2)
            vtg.circle("ring" + Num$(t), px, py, theView.Pixels(TARGETSIZE * 0.6), ring$, "none", theView.Pixels(3), 2)
            vtg.circle("bull" + Num$(t), px, py, theView.Pixels(TARGETSIZE * 0.2), "none", ring$, 0, 2)
        NEXT t
    END FUNCTION
END CLASS

' MARK: - When they meet

' Each shot in the air is asked about: the guard first, then the targets.
' A shot that hits something lands, and the score goes up by what it hit.
' This is a plain function rather than a method of either: it is about how
' they meet, which belongs to neither.
FUNCTION CheckHits() AS VOID
    LOCAL s = 0
    FOR s = 0 TO MAXSHOTS - 1
        IF theShots.Flying(s) = 1 THEN
            IF theGuard.IsHitBy(theShots.X(s), theShots.Y(s)) = 1 THEN
                theShots.Land(s)
                score = score + GUARDPOINTS
            ELSEIF theTargets.HitAt(theShots.X(s), theShots.Y(s)) = 1 THEN
                theShots.Land(s)
                score = score + TARGETPOINTS
            END IF
        END IF
    NEXT s
END FUNCTION
