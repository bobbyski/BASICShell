//
//  BASICTouchControls.swift
//  BASICCore
//
//  On-screen game controls a program places on a touch screen (BASIC-11): a
//  joystick, a d-pad, a wheel and buttons, drawn by the host over the
//  program's graphics.
//
//      touch = TouchControls()
//      touch.Joystick("stick", "BOTTOMRIGHT", 40, 40, 160)
//      touch.Button("fire", "BOTTOMLEFT", 40, 40, 90, "FIRE", "#ff3b30")
//
//  A control reports the way a game controller does, through `ON GAMEPAD`
//  and under a game controller's names, so a game that reads a gamepad reads
//  these too. It can also be polled: `touch.X("stick")`, `touch.Held("fire")`.
//
//  On a host without a touch screen — BASICShell, the Mac, a compiled
//  program — the same calls are accepted and do nothing, and `Available` is
//  FALSE, so one program runs everywhere unchanged.
//

import Foundation

/// What a control is.
public enum BASICTouchControlKind: String, Sendable, CaseIterable {
    /// A thumb pad with two axes from -1 to 1 that springs back to the middle.
    case joystick = "JOYSTICK"
    /// Four directions, and the diagonals between them.
    case dpad = "DPAD"
    /// A spinner: how far it has turned, not where it points.
    case wheel = "WHEEL"
    /// Round, with a label and a color; held or not.
    case button = "BUTTON"
}

/// The side or corner of the screen a control is placed against.
public enum BASICTouchAnchor: String, Sendable, CaseIterable {
    case topLeft = "TOPLEFT", top = "TOP", topRight = "TOPRIGHT"
    case left = "LEFT", center = "CENTER", right = "RIGHT"
    case bottomLeft = "BOTTOMLEFT", bottom = "BOTTOM", bottomRight = "BOTTOMRIGHT"

    /// Accepts the names with or without a hyphen, space or underscore:
    /// `"BOTTOM-RIGHT"`, `"bottom right"`.
    public init?(named name: String) {
        let squeezed = name.uppercased().filter { $0.isLetter }
        self.init(rawValue: squeezed)
    }
}

/// Which directions a joystick or d-pad reports.
public enum BASICTouchDirections: String, Sendable, CaseIterable {
    /// Any direction: a joystick's axes are analog, a d-pad's take diagonals.
    case all = "ALL"
    /// Up, down, left and right, never two at once.
    case four = "4"
    /// The four, and the diagonals between them.
    case eight = "8"
    /// Left and right only: a paddle.
    case horizontal = "HORIZONTAL"
    /// Up and down only.
    case vertical = "VERTICAL"
}

/// One control as the program placed it.
public struct BASICTouchControl: Equatable, Sendable {
    /// The program's name for it, unique among its controls.
    public var id: String
    public var kind: BASICTouchControlKind
    public var anchor: BASICTouchAnchor
    /// From the anchored side inward, in points; along a centered axis, a
    /// shift right or down.
    public var offsetX: Double
    public var offsetY: Double
    /// Its diameter, in points.
    public var size: Double
    /// A button's caption.
    public var label: String
    /// A button's color, or a tint for the others: `#rrggbb`, or empty for
    /// the host's own.
    public var color: String
    /// The game controller name it reports as. A button reports as this name
    /// (`A`, `B`…); a joystick as its directions (`LEFT_STICK` reports
    /// `LEFT_STICK_LEFT`, `LEFT_STICK_UP`…), a d-pad likewise (`DPAD`), and a
    /// wheel as this name with how far it turned.
    public var reportsAs: String
    public var directions: BASICTouchDirections

    public init(
        id: String,
        kind: BASICTouchControlKind,
        anchor: BASICTouchAnchor,
        offsetX: Double,
        offsetY: Double,
        size: Double,
        label: String = "",
        color: String = "",
        reportsAs: String? = nil,
        directions: BASICTouchDirections = .all
    ) {
        self.id = id
        self.kind = kind
        self.anchor = anchor
        self.offsetX = offsetX
        self.offsetY = offsetY
        self.size = size
        self.label = label
        self.color = color
        self.reportsAs = reportsAs ?? Self.defaultReportsAs(kind)
        self.directions = directions
    }

    /// The game controller name each kind reports as unless told otherwise.
    public static func defaultReportsAs(_ kind: BASICTouchControlKind) -> String {
        switch kind {
        case .joystick: return "LEFT_STICK"
        case .dpad: return "DPAD"
        case .wheel: return "WHEEL"
        case .button: return "A"
        }
    }
}

/// Where a control is now, as the program polls it.
public struct BASICTouchControlState: Equatable, Sendable {
    /// Across, from -1 (left) to 1 (right). A d-pad's is -1, 0 or 1.
    public var x: Double = 0
    /// Down, from -1 (up) to 1 (down) — the way screen and VTG coordinates
    /// run. A d-pad's is -1, 0 or 1.
    public var y: Double = 0
    /// A finger is on it.
    public var held: Bool = false

    public init(x: Double = 0, y: Double = 0, held: Bool = false) {
        self.x = x
        self.y = y
        self.held = held
    }
}

/// A host that can draw controls on a touch screen and track the fingers on
/// them. A host that is not one ignores every `TouchControls` call.
///
/// The interpreter calls this from its own thread; an implementation guards
/// its state.
public protocol BASICTouchControlsHost: AnyObject {
    /// There is a touch screen to put controls on.
    var touchControlsAvailable: Bool { get }
    /// Shows `control`, replacing one with the same id.
    func placeTouchControl(_ control: BASICTouchControl)
    /// Takes away the control with this id, if there is one.
    func removeTouchControl(id: String)
    /// Takes away every control.
    func clearTouchControls()
    /// Where the control with this id is now.
    func touchControlState(id: String) -> BASICTouchControlState
    /// How far, in degrees, the wheel with this id has turned since this was
    /// last asked: clockwise positive.
    func takeTouchWheelTurn(id: String) -> Double
}

/// The `TouchControls` object's members, and what it has placed: `Directions`
/// changes a control already on the screen, or one placed later.
final class BASICTouchControlsCall {
    /// The game controller number the on-screen controls report as; real
    /// controllers count up from 0.
    static let controllerNumber = -1

    private var placed: [String: BASICTouchControl] = [:]
    private var directions: [String: BASICTouchDirections] = [:]

    static func property(_ property: String, host: BASICTouchControlsHost?) throws -> BASICValue {
        switch property.uppercased() {
        case "AVAILABLE":
            return .boolean(host?.touchControlsAvailable ?? false)
        default:
            throw BASICError.runtime("TouchControls has no property \(property)")
        }
    }

    func method(_ method: String, arguments: [BASICValue], host: BASICTouchControlsHost?) throws -> BASICValue {
        let name = method.uppercased()
        switch name {
        case "AVAILABLE":
            try Self.expect(arguments, 0, "Available")
            return .boolean(host?.touchControlsAvailable ?? false)
        case "JOYSTICK", "DPAD", "WHEEL":
            guard (5...6).contains(arguments.count) else {
                throw BASICError.runtime("\(Self.spelled(name)) expects an id, an anchor, two offsets, a size, and optionally the gamepad name it reports as")
            }
            place(BASICTouchControl(
                id: try Self.text(arguments[0]),
                kind: BASICTouchControlKind(rawValue: name)!,
                anchor: try Self.anchor(arguments[1]),
                offsetX: try Self.number(arguments[2]),
                offsetY: try Self.number(arguments[3]),
                size: try Self.size(arguments[4]),
                reportsAs: try Self.optionalText(arguments, at: 5)?.uppercased()
            ), host: host)
            return .empty
        case "BUTTON":
            guard (7...8).contains(arguments.count) else {
                throw BASICError.runtime("Button expects an id, an anchor, two offsets, a size, a label, a color, and optionally the gamepad name it reports as")
            }
            place(BASICTouchControl(
                id: try Self.text(arguments[0]),
                kind: .button,
                anchor: try Self.anchor(arguments[1]),
                offsetX: try Self.number(arguments[2]),
                offsetY: try Self.number(arguments[3]),
                size: try Self.size(arguments[4]),
                label: try Self.text(arguments[5]),
                color: try Self.text(arguments[6]),
                reportsAs: try Self.optionalText(arguments, at: 7)?.uppercased()
            ), host: host)
            return .empty
        case "DIRECTIONS":
            try Self.expect(arguments, 2, "Directions")
            let id = try Self.text(arguments[0])
            let word = try Self.text(arguments[1]).uppercased()
            guard let chosen = BASICTouchDirections(rawValue: word) else {
                throw BASICError.runtime("Directions expects ALL, 4, 8, HORIZONTAL or VERTICAL")
            }
            directions[id.uppercased()] = chosen
            if var control = placed[id.uppercased()] {
                control.directions = chosen
                place(control, host: host)
            }
            return .empty
        case "REMOVE":
            try Self.expect(arguments, 1, "Remove")
            let id = try Self.text(arguments[0])
            placed[id.uppercased()] = nil
            host?.removeTouchControl(id: id)
            return .empty
        case "CLEAR":
            try Self.expect(arguments, 0, "Clear")
            placed.removeAll()
            host?.clearTouchControls()
            return .empty
        case "X":
            try Self.expect(arguments, 1, "X")
            return .number(host?.touchControlState(id: try Self.text(arguments[0])).x ?? 0)
        case "Y":
            try Self.expect(arguments, 1, "Y")
            return .number(host?.touchControlState(id: try Self.text(arguments[0])).y ?? 0)
        case "HELD":
            try Self.expect(arguments, 1, "Held")
            return .boolean(host?.touchControlState(id: try Self.text(arguments[0])).held ?? false)
        case "TURN":
            try Self.expect(arguments, 1, "Turn")
            return .number(host?.takeTouchWheelTurn(id: try Self.text(arguments[0])) ?? 0)
        default:
            throw BASICError.runtime("TouchControls has no method \(method)")
        }
    }

    /// Shows `control` with any directions already chosen for its id, and
    /// remembers it so a later `Directions` can change it.
    private func place(_ control: BASICTouchControl, host: BASICTouchControlsHost?) {
        var control = control
        if let chosen = directions[control.id.uppercased()] {
            control.directions = chosen
        }
        placed[control.id.uppercased()] = control
        host?.placeTouchControl(control)
    }

    // MARK: - Arguments

    private static func expect(_ arguments: [BASICValue], _ count: Int, _ method: String) throws {
        guard arguments.count == count else {
            throw BASICError.runtime("\(method) expects \(count) argument\(count == 1 ? "" : "s")")
        }
    }

    private static func text(_ value: BASICValue) throws -> String {
        guard let string = value.string else { throw BASICError.runtime("Expected a string") }
        return string.description
    }

    private static func optionalText(_ arguments: [BASICValue], at index: Int) throws -> String? {
        guard arguments.indices.contains(index), arguments[index] != .empty, arguments[index] != .null else { return nil }
        return try text(arguments[index])
    }

    private static func number(_ value: BASICValue) throws -> Double {
        guard let number = value.number else { throw BASICError.runtime("Expected a number") }
        return number
    }

    private static func size(_ value: BASICValue) throws -> Double {
        let size = try number(value)
        guard size > 0 else { throw BASICError.runtime("A touch control's size must be more than 0") }
        return size
    }

    private static func anchor(_ value: BASICValue) throws -> BASICTouchAnchor {
        let name = try text(value)
        guard let anchor = BASICTouchAnchor(named: name) else {
            throw BASICError.runtime("\(name) is not a place on the screen: use TOPLEFT, TOP, TOPRIGHT, LEFT, CENTER, RIGHT, BOTTOMLEFT, BOTTOM or BOTTOMRIGHT")
        }
        return anchor
    }

    private static func spelled(_ name: String) -> String {
        switch name {
        case "JOYSTICK": return "Joystick"
        case "DPAD": return "DPad"
        default: return "Wheel"
        }
    }
}
