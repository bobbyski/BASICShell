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
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not used")
    }

    func attach(_ controls: StudioTouchControls) {
        guard self.controls !== controls else { return }
        self.controls = controls
        controls.onChange = { [weak self] in
            MainActor.assumeIsolated { self?.setNeedsDisplay() }
        }
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

    override func draw(_ rect: CGRect) {
        guard let controls else { return }
        for drawn in controls.snapshot() {
            let frame = StudioTouchControls.frame(of: drawn.control, in: bounds)
            let tint = Self.color(drawn.control.color) ?? .white
            switch drawn.control.kind {
            case .joystick: drawJoystick(drawn, in: frame, tint: tint)
            case .dpad: drawDPad(drawn, in: frame, tint: tint)
            case .wheel: drawWheel(drawn, in: frame, tint: tint)
            case .button: drawButton(drawn, in: frame, tint: Self.color(drawn.control.color) ?? .systemRed)
            }
        }
    }

    /// A ring to push against, and a knob where the thumb has it.
    private func drawJoystick(_ drawn: StudioTouchControls.Drawn, in frame: CGRect, tint: UIColor) {
        let base = UIBezierPath(ovalIn: frame.insetBy(dx: 1, dy: 1))
        tint.withAlphaComponent(0.12).setFill()
        base.fill()
        tint.withAlphaComponent(0.45).setStroke()
        base.lineWidth = 2
        base.stroke()

        let knobRadius = frame.width * 0.22
        let reach = frame.width / 2 - knobRadius
        let center = CGPoint(
            x: frame.midX + CGFloat(drawn.state.x) * reach,
            y: frame.midY + CGFloat(drawn.state.y) * reach
        )
        let knob = UIBezierPath(arcCenter: center, radius: knobRadius, startAngle: 0, endAngle: .pi * 2, clockwise: true)
        tint.withAlphaComponent(drawn.state.held ? 0.75 : 0.45).setFill()
        knob.fill()
    }

    /// A cross; the arms pressed are lit.
    private func drawDPad(_ drawn: StudioTouchControls.Drawn, in frame: CGRect, tint: UIColor) {
        let base = UIBezierPath(ovalIn: frame.insetBy(dx: 1, dy: 1))
        tint.withAlphaComponent(0.08).setFill()
        base.fill()

        let arm = frame.width * 0.3
        let length = frame.width * 0.36
        let arms: [(String, CGRect)] = [
            ("UP", CGRect(x: frame.midX - arm / 2, y: frame.midY - arm / 2 - length, width: arm, height: length)),
            ("DOWN", CGRect(x: frame.midX - arm / 2, y: frame.midY + arm / 2, width: arm, height: length)),
            ("LEFT", CGRect(x: frame.midX - arm / 2 - length, y: frame.midY - arm / 2, width: length, height: arm)),
            ("RIGHT", CGRect(x: frame.midX + arm / 2, y: frame.midY - arm / 2, width: length, height: arm)),
        ]
        let hub = CGRect(x: frame.midX - arm / 2, y: frame.midY - arm / 2, width: arm, height: arm)
        tint.withAlphaComponent(0.3).setFill()
        UIBezierPath(rect: hub).fill()
        for (direction, armFrame) in arms {
            let path = UIBezierPath(roundedRect: armFrame, cornerRadius: arm * 0.2)
            tint.withAlphaComponent(drawn.pressed.contains(direction) ? 0.8 : 0.3).setFill()
            path.fill()
        }
    }

    /// A ring with notches that turn with the finger.
    private func drawWheel(_ drawn: StudioTouchControls.Drawn, in frame: CGRect, tint: UIColor) {
        let ringWidth = frame.width * 0.16
        let ring = UIBezierPath(ovalIn: frame.insetBy(dx: ringWidth / 2, dy: ringWidth / 2))
        ring.lineWidth = ringWidth
        tint.withAlphaComponent(drawn.state.held ? 0.4 : 0.25).setStroke()
        ring.stroke()

        let radius = frame.width / 2 - ringWidth / 2
        for notch in 0..<12 {
            let angle = (Double(notch) * 30 + drawn.angle) * .pi / 180
            let inner = radius - ringWidth * 0.4
            let outer = radius + ringWidth * 0.4
            let path = UIBezierPath()
            path.move(to: CGPoint(x: frame.midX + CGFloat(cos(angle)) * inner, y: frame.midY + CGFloat(sin(angle)) * inner))
            path.addLine(to: CGPoint(x: frame.midX + CGFloat(cos(angle)) * outer, y: frame.midY + CGFloat(sin(angle)) * outer))
            path.lineWidth = notch == 0 ? 4 : 2
            tint.withAlphaComponent(notch == 0 ? 0.9 : 0.55).setStroke()
            path.stroke()
        }
    }

    /// A round button in its color, with its label.
    private func drawButton(_ drawn: StudioTouchControls.Drawn, in frame: CGRect, tint: UIColor) {
        let face = UIBezierPath(ovalIn: frame.insetBy(dx: 1, dy: 1))
        tint.withAlphaComponent(drawn.state.held ? 0.9 : 0.55).setFill()
        face.fill()
        UIColor.white.withAlphaComponent(0.6).setStroke()
        face.lineWidth = 2
        face.stroke()

        guard !drawn.control.label.isEmpty else { return }
        let attributes: [NSAttributedString.Key: Any] = [
            .font: UIFont.systemFont(ofSize: max(10, frame.width * 0.22), weight: .bold),
            .foregroundColor: UIColor.white,
        ]
        let label = NSAttributedString(string: drawn.control.label, attributes: attributes)
        let size = label.size()
        label.draw(at: CGPoint(x: frame.midX - size.width / 2, y: frame.midY - size.height / 2))
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
