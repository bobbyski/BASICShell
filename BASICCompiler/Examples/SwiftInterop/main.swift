// A Swift program that uses — and inherits from — a class written in BASIC.
//
// `Sprite` is not a wrapper. It was allocated by code basicc emitted, using
// metadata basicc emitted, and this file compiles against the
// .swiftinterface basicc generated. Nothing here knows it came from BASIC.
//
// Members arrive UPPERCASED: BASIC is case-insensitive and BIR normalises
// names, so the Swift face gets the normalised spelling. Carrying the source
// spelling through is a tracked item, not a decision.

import BASICRTSwift
import sprite

let s = Sprite()
s.SETX(4)
s.SETY(5)
print("Sprite.AREA()       =", s.AREA(), "— the body written in sprite.bas")
print("Sprite.PERIMETER()  =", s.PERIMETER())

// BASIC's fields are Swift's stored properties: same object, same offsets.
print("fields from Swift   = X \(s.X), Y \(s.Y)")
s.X = 10
print("written from Swift  =", s.AREA(), "— BASIC's method reads Swift's write")

/// Swift inheriting from BASIC. `super.AREA()` runs the body in sprite.bas,
/// and `padding` is a Swift stored property laid out past BASIC's.
final class PaddedSprite: Sprite {
    var padding = 1.0
    override func AREA() -> Double { super.AREA() + padding }
}

let p = PaddedSprite()
p.SETX(4)
p.SETY(5)
print("PaddedSprite.AREA() =", p.AREA(), "— super's 20, plus 1")

// Through a base-class reference, so this is virtual dispatch and not a
// statically resolved call.
let asSprite: Sprite = p
print("through a Sprite    =", asSprite.AREA())
print("type(of:)           =", type(of: asSprite))
// A dynamic cast, which only succeeds if the runtime really believes this
// object's type descends from BASICObject.
let anything: AnyObject = p
print("dynamic cast        =", (anything as? BASICObject) != nil)
