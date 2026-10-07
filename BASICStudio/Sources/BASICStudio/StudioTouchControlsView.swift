//
//  StudioTouchControlsView.swift
//  BASICStudio
//
//  The program's on-screen controls, drawn over the console on iPhone and
//  iPad (BASIC-11). It takes only the touches that land on a control, every
//  finger its own; a touch anywhere else goes through to the console, where
//  it is the mouse as before.
//

#if os(iOS)
import BASICCore
import UIKit

@MainActor
final class StudioTouchControlsView: UIView {
    private var controls: StudioTouchControls?
    private var fingerNumbers: [ObjectIdentifier: Int] = [:]
    private var nextFingerNumber = 0

    override init(frame: CGRect) {
        super.init(frame: frame)
        isOpaque = false
        backgroundColor = .clear
        isMultipleTouchEnabled = true
        contentMode = .redraw
        accessibilityIdentifier = "TouchControls"
        // Light and dark draw differently (`Palette`), and either can change
        // while the program runs: from Control Center, at sunset, or by the
        // Studio theme.
        registerForTraitChanges([UITraitUserInterfaceStyle.self, UITraitAccessibilityContrast.self]) { (view: Self, _: UITraitCollection) in
            view.setNeedsDisplay()
        }
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not used")
    }

    /// The controls to draw. The console redraws this when the program
    /// changes them (`StudioTouchControls.onChange`).
    func attach(_ controls: StudioTouchControls) {
        guard self.controls !== controls else { return }
        self.controls = controls
        setNeedsDisplay()
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        setNeedsDisplay()
    }

    // MARK: - Touches

    /// Only a control is solid; between them the console is reachable.
    override func point(inside point: CGPoint, with event: UIEvent?) -> Bool {
        controls?.control(at: point, in: bounds) != nil
    }

    override func touchesBegan(_ touches: Set<UITouch>, with event: UIEvent?) {
        for touch in touches {
            let number = nextFingerNumber
            nextFingerNumber += 1
            if controls?.touchBegan(number, at: touch.location(in: self), in: bounds) == true {
                fingerNumbers[ObjectIdentifier(touch)] = number
            }
        }
        setNeedsDisplay()
    }

    override func touchesMoved(_ touches: Set<UITouch>, with event: UIEvent?) {
        for touch in touches {
            guard let number = fingerNumbers[ObjectIdentifier(touch)] else { continue }
            controls?.touchMoved(number, to: touch.location(in: self), in: bounds)
        }
        setNeedsDisplay()
    }

    override func touchesEnded(_ touches: Set<UITouch>, with event: UIEvent?) {
        lift(touches)
    }

    override func touchesCancelled(_ touches: Set<UITouch>, with event: UIEvent?) {
        lift(touches)
    }

    /// A finger lifts where it last was, which may be further on than its
    /// last move: that last stretch counts, as a wheel's turn.
    private func lift(_ touches: Set<UITouch>) {
        for touch in touches {
            guard let number = fingerNumbers.removeValue(forKey: ObjectIdentifier(touch)) else { continue }
            controls?.touchMoved(number, to: touch.location(in: self), in: bounds)
            controls?.touchEnded(number)
        }
        setNeedsDisplay()
    }

    // MARK: - Drawing

    /// What a control is drawn with. A control sits over the program's
    /// canvas, which may be any color, and over the console around it, which
    /// is white in light mode and black in dark: a control has to be seen
    /// on all of them, plainly, not just found by someone who knows it is
    /// there. So each line is the appearance's ink inside a halo of the
    /// opposite, and each base is a plate of the opposite under a wash of
    /// the ink: black ink on a black game still has a gray plate to show
    /// on, and white ink on a white page the same.
    struct Palette {
        /// Lines and knobs: black in light mode, white in dark.
        var ink: UIColor
        /// Around every line: the console's own background.
        var halo: UIColor

        init(traits: UITraitCollection) {
            ink = UIColor.label.resolvedColor(with: traits)
            halo = UIColor.systemBackground.resolvedColor(with: traits)
        }
    }

    override func draw(_ rect: CGRect) {
        guard let controls else { return }
        let palette = Palette(traits: traitCollection)
        for drawn in controls.snapshot() {
            let frame = StudioTouchControls.frame(of: drawn.control, in: bounds)
            // A color the program gave, or the ink; a button with none is red.
            let given = Self.color(drawn.control.color)
            switch drawn.control.kind {
            case .joystick: drawJoystick(drawn, in: frame, tint: given ?? palette.ink, palette)
            case .dpad: drawDPad(drawn, in: frame, tint: given ?? palette.ink, palette)
            case .wheel: drawWheel(drawn, in: frame, tint: given ?? palette.ink, palette)
            case .button: drawButton(drawn, in: frame, face: given ?? .systemRed, palette)
            }
        }
    }

    /// A base the control's lines and knob show on, whatever is under it.
    private func plate(_ path: UIBezierPath, _ tint: UIColor, _ palette: Palette) {
        palette.halo.withAlphaComponent(0.5).setFill()
        path.fill()
        tint.withAlphaComponent(0.18).setFill()
        path.fill()
    }

    /// `path` stroked `width` wide in `color`, inside a halo.
    private func outline(_ path: UIBezierPath, _ color: UIColor, width: CGFloat, _ palette: Palette) {
        path.lineWidth = width + 4
        palette.halo.withAlphaComponent(0.9).setStroke()
        path.stroke()
        path.lineWidth = width
        color.setStroke()
        path.stroke()
    }

    /// A ring to push against, and a knob where the thumb has it.
    private func drawJoystick(_ drawn: StudioTouchControls.Drawn, in frame: CGRect, tint: UIColor, _ palette: Palette) {
        let base = UIBezierPath(ovalIn: frame.insetBy(dx: 4, dy: 4))
        plate(base, tint, palette)
        outline(base, tint.withAlphaComponent(0.85), width: 3, palette)

        let knobRadius = frame.width * 0.22
        let reach = frame.width / 2 - knobRadius
        let center = CGPoint(
            x: frame.midX + CGFloat(drawn.state.x) * reach,
            y: frame.midY + CGFloat(drawn.state.y) * reach
        )
        let knob = UIBezierPath(arcCenter: center, radius: knobRadius, startAngle: 0, endAngle: .pi * 2, clockwise: true)
        tint.withAlphaComponent(drawn.state.held ? 0.95 : 0.75).setFill()
        knob.fill()
        outline(knob, tint, width: 2, palette)
    }

    /// A cross; the arms pressed are lit.
    private func drawDPad(_ drawn: StudioTouchControls.Drawn, in frame: CGRect, tint: UIColor, _ palette: Palette) {
        let base = UIBezierPath(ovalIn: frame.insetBy(dx: 4, dy: 4))
        plate(base, tint, palette)
        outline(base, tint.withAlphaComponent(0.5), width: 2, palette)

        let arm = frame.width * 0.3
        let length = frame.width * 0.36
        let arms: [(String, CGRect)] = [
            ("UP", CGRect(x: frame.midX - arm / 2, y: frame.midY - arm / 2 - length, width: arm, height: length)),
            ("DOWN", CGRect(x: frame.midX - arm / 2, y: frame.midY + arm / 2, width: arm, height: length)),
            ("LEFT", CGRect(x: frame.midX - arm / 2 - length, y: frame.midY - arm / 2, width: length, height: arm)),
            ("RIGHT", CGRect(x: frame.midX + arm / 2, y: frame.midY - arm / 2, width: length, height: arm)),
        ]
        let hub = CGRect(x: frame.midX - arm / 2, y: frame.midY - arm / 2, width: arm, height: arm)
        tint.withAlphaComponent(0.7).setFill()
        UIBezierPath(rect: hub).fill()
        for (direction, armFrame) in arms {
            let path = UIBezierPath(roundedRect: armFrame, cornerRadius: arm * 0.2)
            tint.withAlphaComponent(drawn.pressed.contains(direction) ? 0.95 : 0.7).setFill()
            path.fill()
            outline(path, tint, width: 1.5, palette)
        }
    }

    /// A ring with notches that turn with the finger.
    private func drawWheel(_ drawn: StudioTouchControls.Drawn, in frame: CGRect, tint: UIColor, _ palette: Palette) {
        let ringWidth = frame.width * 0.16
        let ring = UIBezierPath(ovalIn: frame.insetBy(dx: ringWidth / 2 + 2, dy: ringWidth / 2 + 2))
        plate(UIBezierPath(ovalIn: frame.insetBy(dx: 2, dy: 2)), tint, palette)
        outline(ring, tint.withAlphaComponent(drawn.state.held ? 0.6 : 0.45), width: ringWidth, palette)

        let radius = frame.width / 2 - ringWidth / 2 - 2
        for notch in 0..<12 {
            let angle = (Double(notch) * 30 + drawn.angle) * .pi / 180
            let inner = radius - ringWidth * 0.4
            let outer = radius + ringWidth * 0.4
            let path = UIBezierPath()
            path.move(to: CGPoint(x: frame.midX + CGFloat(cos(angle)) * inner, y: frame.midY + CGFloat(sin(angle)) * inner))
            path.addLine(to: CGPoint(x: frame.midX + CGFloat(cos(angle)) * outer, y: frame.midY + CGFloat(sin(angle)) * outer))
            path.lineWidth = notch == 0 ? 4 : 2
            palette.halo.setStroke()
            path.stroke()
            tint.setStroke()
            path.lineWidth = notch == 0 ? 3 : 1.5
            path.stroke()
        }
    }

    /// A round button in its color, solid, with its label in whichever of
    /// black and white reads on that color.
    private func drawButton(_ drawn: StudioTouchControls.Drawn, in frame: CGRect, face: UIColor, _ palette: Palette) {
        let disc = UIBezierPath(ovalIn: frame.insetBy(dx: 3, dy: 3))
        // Held is a little darker, so a press is seen under the finger.
        (drawn.state.held ? Self.darkened(face) : face).setFill()
        disc.fill()
        outline(disc, palette.ink.withAlphaComponent(0.6), width: 1.5, palette)

        guard !drawn.control.label.isEmpty else { return }
        let attributes: [NSAttributedString.Key: Any] = [
            .font: UIFont.systemFont(ofSize: max(10, frame.width * 0.22), weight: .bold),
            .foregroundColor: Self.labelColor(on: face),
        ]
        let label = NSAttributedString(string: drawn.control.label, attributes: attributes)
        let size = label.size()
        label.draw(at: CGPoint(x: frame.midX - size.width / 2, y: frame.midY - size.height / 2))
    }

    /// Black on a light face, white on any other.
    static func labelColor(on face: UIColor) -> UIColor {
        var red: CGFloat = 0, green: CGFloat = 0, blue: CGFloat = 0, alpha: CGFloat = 0
        guard face.getRed(&red, green: &green, blue: &blue, alpha: &alpha) else { return .white }
        return StudioTouchControls.isLight(red: Double(red), green: Double(green), blue: Double(blue)) ? .black : .white
    }

    /// A press's shade of `color`.
    static func darkened(_ color: UIColor) -> UIColor {
        var hue: CGFloat = 0, saturation: CGFloat = 0, brightness: CGFloat = 0, alpha: CGFloat = 0
        guard color.getHue(&hue, saturation: &saturation, brightness: &brightness, alpha: &alpha) else { return color }
        return UIColor(hue: hue, saturation: saturation, brightness: brightness * 0.75, alpha: alpha)
    }

    /// `#rrggbb` as a color, or nil for anything else.
    static func color(_ hex: String) -> UIColor? {
        var digits = hex.trimmingCharacters(in: .whitespaces)
        if digits.hasPrefix("#") { digits.removeFirst() }
        guard digits.count == 6, let value = UInt32(digits, radix: 16) else { return nil }
        return UIColor(
            red: CGFloat((value >> 16) & 0xff) / 255,
            green: CGFloat((value >> 8) & 0xff) / 255,
            blue: CGFloat(value & 0xff) / 255,
            alpha: 1
        )
    }
}
#endif
