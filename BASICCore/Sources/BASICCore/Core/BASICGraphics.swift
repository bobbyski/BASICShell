import Foundation
#if canImport(Darwin)
import Darwin
#endif

public struct BASICBreakpointLocation: Hashable, Sendable {
    /// Optional BASIC source file path.
    public var fileName: String?
    /// One-based source line number.
    public var lineNumber: Int
    /// Zero-based statement index within a colon-separated line.
    public var statementNumber: Int

    /// Creates a breakpoint location.
    public init(fileName: String? = nil, lineNumber: Int, statementNumber: Int = 0) {
        self.fileName = fileName
        self.lineNumber = lineNumber
        self.statementNumber = statementNumber
    }

    func matches(_ currentLocation: BASICBreakpointLocation) -> Bool {
        let sameFile = fileName == nil
            || currentLocation.fileName == nil
            || fileName == currentLocation.fileName
        let sameLine = lineNumber == currentLocation.lineNumber
        let sameStatement = statementNumber == currentLocation.statementNumber
            || statementNumber == 0
        return sameFile && sameLine && sameStatement
    }
}

/// User-configurable breakpoint.
public struct BASICBreakpoint: Identifiable, Hashable, Sendable {
    /// Stable breakpoint identity.
    public var id: UUID
    /// Source location where the breakpoint should stop.
    public var location: BASICBreakpointLocation
    /// Whether the breakpoint participates in execution.
    public var isEnabled: Bool

    /// Creates a breakpoint at a location.
    public init(id: UUID = UUID(), location: BASICBreakpointLocation, isEnabled: Bool = true) {
        self.id = id
        self.location = location
        self.isEnabled = isEnabled
    }
}

/// Graphics screen configuration requested by the BASIC SCREEN statement.
public struct BASICScreenMode: Equatable, Sendable {
    /// BASIC screen mode number.
    public let number: Int
    /// Pixel width for graphics operations.
    public let width: Int
    /// Pixel height for graphics operations.
    public let height: Int
    /// Number of supported colors.
    public let colorCount: Int

    /// Creates a screen mode description.
    public init(number: Int, width: Int, height: Int, colorCount: Int) {
        self.number = number
        self.width = width
        self.height = height
        self.colorCount = colorCount
    }
}

/// A resolved BASIC color, supporting legacy palette indexes and full RGBA colors.
public struct BASICColor: Equatable, Sendable {
    /// Red byte.
    public let red: Int
    /// Green byte.
    public let green: Int
    /// Blue byte.
    public let blue: Int
    /// Alpha byte.
    public let alpha: Int
    /// Original legacy palette index when the color came from a classic BASIC integer.
    public let legacyIndex: Int?

    /// Creates an RGBA color, clamping all components to byte range.
    public init(red: Int, green: Int, blue: Int, alpha: Int = 255, legacyIndex: Int? = nil) {
        self.red = Self.clampByte(red)
        self.green = Self.clampByte(green)
        self.blue = Self.clampByte(blue)
        self.alpha = Self.clampByte(alpha)
        self.legacyIndex = legacyIndex
    }

    /// Creates a legacy BASIC palette color.
    public static func legacy(_ index: Int) -> BASICColor {
        let palette = [
            (0, 0, 0), (96, 165, 250), (34, 197, 94), (6, 182, 212),
            (239, 68, 68), (217, 70, 239), (245, 158, 11), (229, 231, 235),
            (107, 114, 128), (147, 197, 253), (134, 239, 172), (103, 232, 249),
            (252, 165, 165), (240, 171, 252), (253, 224, 71), (255, 255, 255)
        ]
        let normalized = ((index % palette.count) + palette.count) % palette.count
        let color = palette[normalized]
        return BASICColor(red: color.0, green: color.1, blue: color.2, legacyIndex: index)
    }

    /// Parses a BASIC color string: optional-# hex, named colors, named colors with alpha, or comma-separated RGBA bytes.
    public static func parse(_ rawValue: String) throws -> BASICColor {
        let value = rawValue.trimmingCharacters(in: .whitespacesAndNewlines)
        if let color = parseRGBABytes(value) {
            return color
        }
        if let color = parseHex(value) {
            return color
        }
        if let color = parseNamed(value) {
            return color
        }
        throw BASICError.runtime("Invalid color")
    }

    /// CSS-style lowercase hex string suitable for VTG true-color APIs.
    public var cssHex: String {
        String(format: "#%02x%02x%02x%02x", red, green, blue, alpha)
    }

    private static func clampByte(_ value: Int) -> Int {
        min(255, max(0, value))
    }

    private static func parseHex(_ value: String) -> BASICColor? {
        let hex = value.hasPrefix("#") ? String(value.dropFirst()) : value
        guard hex.count == 6 || hex.count == 8,
              hex.allSatisfy({ $0.isHexDigit }),
              let number = UInt32(hex, radix: 16) else { return nil }
        if hex.count == 6 {
            return BASICColor(
                red: Int((number >> 16) & 0xff),
                green: Int((number >> 8) & 0xff),
                blue: Int(number & 0xff)
            )
        }
        return BASICColor(
            red: Int((number >> 24) & 0xff),
            green: Int((number >> 16) & 0xff),
            blue: Int((number >> 8) & 0xff),
            alpha: Int(number & 0xff)
        )
    }

    private static func parseRGBABytes(_ value: String) -> BASICColor? {
        let parts = value.split(separator: ",").map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
        guard parts.count == 3 || parts.count == 4,
              let red = Int(parts[0]),
              let green = Int(parts[1]),
              let blue = Int(parts[2]) else { return nil }
        let alpha = parts.count == 4 ? (Int(parts[3]) ?? 255) : 255
        return BASICColor(red: red, green: green, blue: blue, alpha: alpha)
    }

    private static func parseNamed(_ value: String) -> BASICColor? {
        let parts = value.split(separator: ",", omittingEmptySubsequences: false)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
        guard let name = parts.first?.lowercased(),
              let rgb = namedColors[name] else { return nil }
        var alpha = 255
        for part in parts.dropFirst() {
            let lowered = part.lowercased()
            guard lowered.hasPrefix("alpha:") else { continue }
            alpha = parseAlpha(String(lowered.dropFirst("alpha:".count))) ?? alpha
        }
        return BASICColor(red: rgb.0, green: rgb.1, blue: rgb.2, alpha: alpha)
    }

    private static func parseAlpha(_ value: String) -> Int? {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.hasSuffix("%"), let percent = Double(trimmed.dropLast()) {
            return clampByte(Int((percent / 100.0 * 255.0).rounded()))
        }
        return Int(trimmed).map(clampByte)
    }

    private static let namedColors: [String: (Int, Int, Int)] = [
        "black": (0, 0, 0),
        "blue": (0, 0, 255),
        "cyan": (0, 255, 255),
        "gray": (128, 128, 128),
        "green": (0, 128, 0),
        "grey": (128, 128, 128),
        "magenta": (255, 0, 255),
        "orange": (255, 165, 0),
        "purple": (128, 0, 128),
        "red": (255, 0, 0),
        "white": (255, 255, 255),
        "yellow": (255, 255, 0)
    ]
}

/// Host interface for pixel graphics used by BASICStudio.
public protocol BASICGraphicsHost: BASICHost {
    /// Indicates whether graphics operations are available on the current host.
    var isGraphicsAvailable: Bool { get }
    /// Message to report when the host exists but graphics are unavailable.
    var graphicsUnavailableMessage: String { get }
    /// Selects a graphics screen mode.
    func setScreenMode(_ mode: BASICScreenMode)
    /// Sets the current graphics drawing color.
    func setGraphicsColor(_ color: Int)
    /// Sets the current graphics drawing color using the full-color model.
    func setGraphicsColor(_ color: BASICColor)
    /// Clears the graphics layer, optionally with a color.
    func clearGraphics(color: Int?)
    /// Sets one graphics pixel.
    func setPixel(x: Int, y: Int, color: Int)
    /// Sets one graphics pixel using the full-color model.
    func setPixel(x: Int, y: Int, color: BASICColor)
    /// Reads one graphics pixel.
    func getPixel(x: Int, y: Int) -> Int
    /// Draws one line segment.
    func drawLine(x1: Int, y1: Int, x2: Int, y2: Int, color: Int)
    /// Draws one line segment using the full-color model.
    func drawLine(x1: Int, y1: Int, x2: Int, y2: Int, color: BASICColor)
    /// Draws one circle outline.
    func drawCircle(cx: Int, cy: Int, radius: Int, color: Int)
    /// Draws one circle outline using the full-color model.
    func drawCircle(cx: Int, cy: Int, radius: Int, color: BASICColor)
    /// Draws one ellipse outline.
    func drawEllipse(cx: Int, cy: Int, radiusX: Int, radiusY: Int, color: Int)
    /// Draws one ellipse outline using the full-color model.
    func drawEllipse(cx: Int, cy: Int, radiusX: Int, radiusY: Int, color: BASICColor)
    /// Flood-fills a bounded graphics region.
    func paintFill(x: Int, y: Int, color: Int, borderColor: Int?)
    /// Flood-fills a bounded graphics region using the full-color model.
    func paintFill(x: Int, y: Int, color: BASICColor, borderColor: BASICColor?)
}

public extension BASICGraphicsHost {
    /// Default for hosts that conform only when graphics are available.
    var isGraphicsAvailable: Bool { true }

    /// Default message for hosts that do not expose a more specific graphics policy.
    var graphicsUnavailableMessage: String { "Unsupported feature: you must run this program in BASICStudio" }

    /// Sets the current graphics drawing color using the full-color model.
    func setGraphicsColor(_ color: BASICColor) {
        setGraphicsColor(color.legacyIndex ?? 1)
    }

    /// Sets one graphics pixel using the full-color model.
    func setPixel(x: Int, y: Int, color: BASICColor) {
        setPixel(x: x, y: y, color: color.legacyIndex ?? 1)
    }

    /// Draws one line segment using the full-color model.
    func drawLine(x1: Int, y1: Int, x2: Int, y2: Int, color: BASICColor) {
        drawLine(x1: x1, y1: y1, x2: x2, y2: y2, color: color.legacyIndex ?? 1)
    }

    /// Draws one circle outline using the full-color model.
    func drawCircle(cx: Int, cy: Int, radius: Int, color: BASICColor) {
        drawCircle(cx: cx, cy: cy, radius: radius, color: color.legacyIndex ?? 1)
    }

    /// Draws one ellipse outline using the full-color model.
    func drawEllipse(cx: Int, cy: Int, radiusX: Int, radiusY: Int, color: BASICColor) {
        drawEllipse(cx: cx, cy: cy, radiusX: radiusX, radiusY: radiusY, color: color.legacyIndex ?? 1)
    }

    /// Flood-fills a bounded graphics region using the full-color model.
    func paintFill(x: Int, y: Int, color: BASICColor, borderColor: BASICColor?) {
        paintFill(x: x, y: y, color: color.legacyIndex ?? 1, borderColor: borderColor?.legacyIndex)
    }

}

public extension BASICHost {
    /// Convenience default that adapts `print(_:terminator:)` to `printLine(_:)`.
    func print(_ text: String, terminator: String) {
        printLine(text + terminator.trimmingCharacters(in: .newlines))
    }
}
