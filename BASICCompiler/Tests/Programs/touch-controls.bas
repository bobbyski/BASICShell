' TouchControls (BASIC-11) with no touch screen: every call is accepted and
' does nothing, polls read a control at rest, and a bad place is an error.
touch = TouchControls()
PRINT "available "; touch.Available; touch.Available()
touch.Joystick("stick", "BOTTOMRIGHT", 40, 40, 160)
touch.DPad("pad", "bottom-left", 30, 30, 150, "DPAD")
touch.Wheel("spin", "RIGHT", 40, 0, 180)
touch.Button("fire", "BOTTOMLEFT", 40, 40, 90, "FIRE", "#ff3b30")
touch.Button("zap", "BOTTOMLEFT", 150, 80, 70, "ZAP", "#ffd60a", "B")
touch.Directions("stick", "HORIZONTAL")
PRINT touch.X("stick"); touch.Y("stick"); touch.Held("fire"); touch.Turn("spin")
touch.Remove("zap")
touch.Clear()
ON ERROR GOTO Oops
touch.Joystick("s", "MIDDLE", 0, 0, 100)
PRINT "not reached"
END
Oops:
PRINT "error "; ERR
END
