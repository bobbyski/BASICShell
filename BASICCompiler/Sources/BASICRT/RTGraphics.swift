import Foundation

// BASICRT graphics — SCREEN, COLOR, CLS, PSET, PRESET, POINT, LINE, CIRCLE,
// PAINT, DRAW: the interpreter's graphics statements over the console
// host's model (BASICShell's ConsoleHost on VectorTerminalSDK).
//
// The core keeps what the interpreter and the Shell keep: the current
// color and point, the DRAW parser, and a shadow framebuffer of palette
// indexes so POINT and PAINT can answer and fill. The terminal is reached
// through the host hooks below — implemented over the VTG canvas in
// BASICRTHost, or by stubs that report graphics unsupported.

// MARK: - Host hooks (BASICRTHost or BASICRTHostStubs)

@_silgen_name("basic_rt_host_graphics_available") func rtHostGraphicsAvailable() -> Bool
@_silgen_name("basic_rt_host_gfx_canvas_size") func rtHostCanvasSize(_ width: UnsafeMutablePointer<Int>, _ height: UnsafeMutablePointer<Int>) -> Bool
@_silgen_name("basic_rt_host_gfx_pixel") func rtHostPixel(_ id: UnsafePointer<CChar>, _ x: Int, _ y: Int, _ color: UnsafePointer<CChar>)
@_silgen_name("basic_rt_host_gfx_line") func rtHostLine(_ id: UnsafePointer<CChar>, _ x1: Int, _ y1: Int, _ x2: Int, _ y2: Int, _ color: UnsafePointer<CChar>, _ width: Int)
@_silgen_name("basic_rt_host_gfx_draw") func rtHostDraw(_ id: UnsafePointer<CChar>, _ count: Int, _ xs: UnsafePointer<Int>, _ ys: UnsafePointer<Int>, _ color: UnsafePointer<CChar>, _ width: Int)
@_silgen_name("basic_rt_host_gfx_circle") func rtHostCircle(_ id: UnsafePointer<CChar>, _ cx: Int, _ cy: Int, _ radius: Int, _ color: UnsafePointer<CChar>, _ lineWidth: Int)
@_silgen_name("basic_rt_host_gfx_ellipse") func rtHostEllipse(_ id: UnsafePointer<CChar>, _ cx: Int, _ cy: Int, _ rx: Int, _ ry: Int, _ color: UnsafePointer<CChar>, _ lineWidth: Int)
@_silgen_name("basic_rt_host_gfx_clear") func rtHostClear()
@_silgen_name("basic_rt_host_gfx_present") func rtHostPresent()

// MARK: - Colors (the interpreter's BASICColor)

struct RTColor: Equatable {
    let red: Int, green: Int, blue: Int, alpha: Int
    let legacyIndex: Int?

    init(red: Int, green: Int, blue: Int, alpha: Int = 255, legacyIndex: Int? = nil) {
        func clamp(_ value: Int) -> Int { min(255, max(0, value)) }
        self.red = clamp(red); self.green = clamp(green); self.blue = clamp(blue); self.alpha = clamp(alpha)
        self.legacyIndex = legacyIndex
    }

    static let palette = [
        (0, 0, 0), (96, 165, 250), (34, 197, 94), (6, 182, 212),
        (239, 68, 68), (217, 70, 239), (245, 158, 11), (229, 231, 235),
        (107, 114, 128), (147, 197, 253), (134, 239, 172), (103, 232, 249),
        (252, 165, 165), (240, 171, 252), (253, 224, 71), (255, 255, 255),
    ]

    static func legacy(_ index: Int) -> RTColor {
        let normalized = ((index % palette.count) + palette.count) % palette.count
        let color = palette[normalized]
        return RTColor(red: color.0, green: color.1, blue: color.2, legacyIndex: index)
    }

    /// `#rrggbbaa`, what the Shell hands VTG.
    var cssHex: String { String(format: "#%02x%02x%02x%02x", red, green, blue, alpha) }

    static let named: [String: (Int, Int, Int)] = [
        "black": (0, 0, 0), "blue": (0, 0, 255), "cyan": (0, 255, 255), "gray": (128, 128, 128),
        "green": (0, 128, 0), "grey": (128, 128, 128), "magenta": (255, 0, 255), "orange": (255, 165, 0),
        "purple": (128, 0, 128), "red": (255, 0, 0), "white": (255, 255, 255), "yellow": (255, 255, 0),
    ]

    static func parse(_ rawValue: String) -> RTColor {
        let value = rawValue.trimmingCharacters(in: .whitespacesAndNewlines)
        func clamp(_ value: Int) -> Int { min(255, max(0, value)) }
        let parts = value.split(separator: ",").map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
        if parts.count == 3 || parts.count == 4, let red = Int(parts[0]), let green = Int(parts[1]), let blue = Int(parts[2]) {
            return RTColor(red: red, green: green, blue: blue, alpha: parts.count == 4 ? (Int(parts[3]) ?? 255) : 255)
        }
        let hex = value.hasPrefix("#") ? String(value.dropFirst()) : value
        if hex.count == 6 || hex.count == 8, hex.allSatisfy({ $0.isHexDigit }), let number = UInt32(hex, radix: 16) {
            if hex.count == 6 {
                return RTColor(red: Int((number >> 16) & 0xff), green: Int((number >> 8) & 0xff), blue: Int(number & 0xff))
            }
            return RTColor(red: Int((number >> 24) & 0xff), green: Int((number >> 16) & 0xff), blue: Int((number >> 8) & 0xff), alpha: Int(number & 0xff))
        }
        let namedParts = value.split(separator: ",", omittingEmptySubsequences: false).map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
        if let name = namedParts.first?.lowercased(), let rgb = named[name] {
            var alpha = 255
            for part in namedParts.dropFirst() {
                let lowered = part.lowercased()
                guard lowered.hasPrefix("alpha:") else { continue }
                let text = String(lowered.dropFirst("alpha:".count)).trimmingCharacters(in: .whitespacesAndNewlines)
                if text.hasSuffix("%"), let percent = Double(text.dropLast()) { alpha = clamp(Int((percent / 100.0 * 255.0).rounded())) }
                else if let byte = Int(text) { alpha = clamp(byte) }
            }
            return RTColor(red: rgb.0, green: rgb.1, blue: rgb.2, alpha: alpha)
        }
        basic_rt_fail("Invalid color")
    }

    /// The interpreter's `resolveColor`: a string parses, a number is a palette index.
    static func resolve(_ value: RTValue) -> RTColor {
        if let string = value.string { return parse(string.description) }
        guard let number = value.number else { basic_rt_fail("Expected a color") }
        return legacy(Int(number.rounded()))
    }
}

// MARK: - The graphics state

enum RTGraphics {
    nonisolated(unsafe) static var currentColor = RTColor.legacy(1)
    nonisolated(unsafe) static var currentPoint = (x: 0, y: 0)
    nonisolated(unsafe) static var width = 0
    nonisolated(unsafe) static var height = 0
    nonisolated(unsafe) static var pixels: [Int] = []
    nonisolated(unsafe) static var operationID = 0
    nonisolated(unsafe) static var didUse = false
    nonisolated(unsafe) static var availability: Bool?

    static let colorCount = 16

    static var isAvailable: Bool {
        if let availability { return availability }
        let available = rtHostGraphicsAvailable()
        availability = available
        return available
    }

    /// The guard every graphics statement runs.
    static func require() {
        guard isAvailable else { basic_rt_fail("VectorTerminal graphics are not supported by this terminal") }
    }

    /// The Shell's `ensureNativeSemanticGraphicsMode`: the live canvas size,
    /// else 1024×768, allocated once.
    static func ensureMode() {
        guard width <= 0 || height <= 0 else { return }
        var canvasWidth = 0, canvasHeight = 0
        _ = rtHostCanvasSize(&canvasWidth, &canvasHeight)
        width = canvasWidth > 0 ? canvasWidth : 1024
        height = canvasHeight > 0 ? canvasHeight : 768
        pixels = Array(repeating: 0, count: max(0, width * height))
    }

    static func nextID(_ prefix: String) -> String {
        operationID += 1
        return "basic-\(prefix)-\(operationID)"
    }

    static func normalized(_ color: Int) -> Int { max(0, color) % colorCount }

    static func setPixel(x: Int, y: Int, color: Int) {
        guard width > 0, height > 0, x >= 0, y >= 0, x < width, y < height else { return }
        pixels[y * width + x] = normalized(color)
    }

    static func line(x1: Int, y1: Int, x2: Int, y2: Int, color: Int) {
        var x = x1, y = y1
        let dx = abs(x2 - x1), sx = x1 < x2 ? 1 : -1
        let dy = -abs(y2 - y1), sy = y1 < y2 ? 1 : -1
        var error = dx + dy
        while true {
            setPixel(x: x, y: y, color: color)
            if x == x2 && y == y2 { break }
            let nextError = 2 * error
            if nextError >= dy { error += dy; x += sx }
            if nextError <= dx { error += dx; y += sy }
        }
    }

    static func circle(cx: Int, cy: Int, radius: Int, color: Int) {
        var x = max(0, radius), y = 0
        var error = 1 - x
        while x >= y {
            for (px, py) in [(cx + x, cy + y), (cx + y, cy + x), (cx - y, cy + x), (cx - x, cy + y), (cx - x, cy - y), (cx - y, cy - x), (cx + y, cy - x), (cx + x, cy - y)] {
                setPixel(x: px, y: py, color: color)
            }
            y += 1
            if error < 0 { error += 2 * y + 1 } else { x -= 1; error += 2 * (y - x) + 1 }
        }
    }

    static func ellipse(cx: Int, cy: Int, radiusX: Int, radiusY: Int, color: Int) {
        let rx = max(0, radiusX), ry = max(0, radiusY)
        guard rx > 0 || ry > 0 else { setPixel(x: cx, y: cy, color: color); return }
        let steps = max(24, Int(Double(max(rx, ry)) * 8))
        var plotted = Set<Int>()
        for step in 0...steps {
            let angle = (Double(step) / Double(steps)) * Double.pi * 2
            let x = cx + Int((Double(rx) * cos(angle)).rounded())
            let y = cy + Int((Double(ry) * sin(angle)).rounded())
            let key = (y << 16) ^ x
            guard plotted.insert(key).inserted else { continue }
            setPixel(x: x, y: y, color: color)
        }
    }

    static func fill(x: Int, y: Int, color: Int, borderColor: Int?) -> [(x: Int, y: Int)] {
        guard width > 0, height > 0, x >= 0, y >= 0, x < width, y < height else { return [] }
        let fillColor = normalized(color)
        let border = borderColor.map(normalized)
        let startColor = pixels[y * width + x]
        guard startColor != fillColor, border != startColor else { return [] }
        var changed: [(x: Int, y: Int)] = []
        var stack = [(x: x, y: y)]
        var visited = Set<Int>()
        while let point = stack.popLast() {
            guard point.x >= 0, point.y >= 0, point.x < width, point.y < height else { continue }
            let index = point.y * width + point.x
            guard visited.insert(index).inserted else { continue }
            let current = pixels[index]
            if let border, current == border { continue }
            guard current == startColor else { continue }
            pixels[index] = fillColor
            changed.append(point)
            stack.append((point.x + 1, point.y)); stack.append((point.x - 1, point.y))
            stack.append((point.x, point.y + 1)); stack.append((point.x, point.y - 1))
        }
        return changed
    }

    /// The interpreter's `BASICGraphicsBatcher.horizontalRuns`.
    static func horizontalRuns(_ points: [(x: Int, y: Int)]) -> [(x1: Int, x2: Int, y: Int)] {
        guard !points.isEmpty else { return [] }
        let sorted = points.sorted { $0.y == $1.y ? $0.x < $1.x : $0.y < $1.y }
        var runs: [(x1: Int, x2: Int, y: Int)] = []
        var currentY = sorted[0].y, startX = sorted[0].x, endX = sorted[0].x
        for point in sorted.dropFirst() {
            if point.y == currentY, point.x <= endX + 1 { endX = max(endX, point.x); continue }
            runs.append((startX, endX, currentY))
            currentY = point.y; startX = point.x; endX = point.x
        }
        runs.append((startX, endX, currentY))
        return runs
    }

    // MARK: Host operations — the Shell's BASICGraphicsHost methods

    static func hostPixel(x: Int, y: Int, color: RTColor) {
        ensureMode()
        setPixel(x: x, y: y, color: color.legacyIndex ?? 1)
        didUse = true
        rtHostPixel(nextID("pixel"), x, y, color.cssHex)
        rtHostPresent()
    }

    static func hostLine(x1: Int, y1: Int, x2: Int, y2: Int, color: RTColor) {
        ensureMode()
        line(x1: x1, y1: y1, x2: x2, y2: y2, color: color.legacyIndex ?? 1)
        didUse = true
        rtHostLine(nextID("line"), x1, y1, x2, y2, color.cssHex, 2)
        rtHostPresent()
    }

    static func hostPath(_ points: [(x: Int, y: Int)], color: RTColor) {
        guard points.count >= 2 else { return }
        ensureMode()
        for index in points.indices.dropLast() {
            line(x1: points[index].x, y1: points[index].y, x2: points[index + 1].x, y2: points[index + 1].y, color: color.legacyIndex ?? 1)
        }
        didUse = true
        let xs = points.map(\.x), ys = points.map(\.y)
        rtHostDraw(nextID("draw"), points.count, xs, ys, color.cssHex, 2)
        rtHostPresent()
    }

    static func hostCircle(cx: Int, cy: Int, radius: Int, color: RTColor) {
        ensureMode()
        circle(cx: cx, cy: cy, radius: radius, color: color.legacyIndex ?? 1)
        didUse = true
        rtHostCircle(nextID("circle"), cx, cy, radius, color.cssHex, 2)
        rtHostPresent()
    }

    static func hostEllipse(cx: Int, cy: Int, rx: Int, ry: Int, color: RTColor) {
        ensureMode()
        ellipse(cx: cx, cy: cy, radiusX: rx, radiusY: ry, color: color.legacyIndex ?? 1)
        didUse = true
        rtHostEllipse(nextID("ellipse"), cx, cy, rx, ry, color.cssHex, 2)
        rtHostPresent()
    }

    static func hostPaint(x: Int, y: Int, color: RTColor, border: RTColor?) {
        ensureMode()
        let changed = fill(x: x, y: y, color: color.legacyIndex ?? 1, borderColor: border?.legacyIndex)
        didUse = true
        for run in horizontalRuns(changed) {
            if run.x1 == run.x2 {
                rtHostPixel(nextID("paint"), run.x1, run.y, color.cssHex)
            } else {
                rtHostLine(nextID("paint"), run.x1, run.y, run.x2, run.y, color.cssHex, 1)
            }
        }
        rtHostPresent()
    }

    /// The Shell's `clearGraphics(color: nil)`.
    static func clear() {
        guard isAvailable else { return }
        if width > 0, height > 0 {
            pixels = Array(repeating: 0, count: width * height)
            operationID = 0
        }
        didUse = true
        rtHostClear()
        rtHostPresent()
    }

    /// What the Shell does when a run finishes: the canvas is cleared.
    static func finish() {
        guard didUse, availability == true else { return }
        rtHostClear()
        rtHostPresent()
        didUse = false
    }

    // MARK: DRAW (the interpreter's drawGraphicsPath)

    static func draw(_ source: String) {
        let characters = Array(source)
        var index = 0
        var drawColor = currentColor
        var blankNext = false, noUpdateNext = false
        var scale = 4, angle = 0
        var pending: [(x: Int, y: Int)] = []
        var pendingColor: RTColor?

        func skipSeparators() {
            while index < characters.count, characters[index] == " " || characters[index] == "\t" || characters[index] == ";" { index += 1 }
        }
        func readSignedNumber(default defaultValue: Int? = nil) -> Int {
            skipSeparators()
            let start = index
            if index < characters.count, characters[index] == "+" || characters[index] == "-" { index += 1 }
            while index < characters.count, characters[index].isNumber { index += 1 }
            guard index > start else {
                if let defaultValue { return defaultValue }
                basic_rt_fail("DRAW expected number")
            }
            guard let value = Int(String(characters[start..<index])) else { basic_rt_fail("DRAW expected number") }
            return value
        }
        func flush() {
            if pending.count >= 2, let color = pendingColor { hostPath(pending, color: color) }
            pending.removeAll(); pendingColor = nil
        }
        func queue(from start: (x: Int, y: Int), to end: (x: Int, y: Int), color: RTColor) {
            if pendingColor == color, let last = pending.last, last.x == start.x, last.y == start.y {
                pending.append(end)
            } else {
                flush(); pendingColor = color; pending = [start, end]
            }
        }
        func drawTo(_ x: Int, _ y: Int) {
            let old = currentPoint
            if !blankNext { queue(from: old, to: (x, y), color: drawColor) } else { flush() }
            if !noUpdateNext { currentPoint = (x, y) } else { flush() }
            blankNext = false; noUpdateNext = false
        }
        func scaled(_ value: Int) -> Int { Int((Double(value) * Double(scale) / 4.0).rounded()) }
        func rotated(dx: Int, dy: Int) -> (dx: Int, dy: Int) {
            let sdx = scaled(dx), sdy = scaled(dy)
            switch ((angle % 4) + 4) % 4 {
            case 1: return (sdy, -sdx)
            case 2: return (-sdx, -sdy)
            case 3: return (-sdy, sdx)
            default: return (sdx, sdy)
            }
        }
        func relative(dx: Int, dy: Int) {
            let t = rotated(dx: dx, dy: dy)
            drawTo(currentPoint.x + t.dx, currentPoint.y + t.dy)
        }

        while index < characters.count {
            skipSeparators()
            guard index < characters.count else { break }
            let command = String(characters[index]).uppercased()
            index += 1
            switch command {
            case "B": blankNext = true
            case "N": noUpdateNext = true
            case "C":
                flush()
                drawColor = .legacy(readSignedNumber())
                currentColor = drawColor
            case "S":
                let newScale = readSignedNumber()
                guard newScale > 0 else { basic_rt_fail("DRAW scale must be greater than zero") }
                scale = newScale
            case "A":
                let newAngle = readSignedNumber()
                guard (0...3).contains(newAngle) else { basic_rt_fail("DRAW angle must be 0, 1, 2, or 3") }
                angle = newAngle
            case "U": relative(dx: 0, dy: -readSignedNumber(default: 1))
            case "D": relative(dx: 0, dy: readSignedNumber(default: 1))
            case "L": relative(dx: -readSignedNumber(default: 1), dy: 0)
            case "R": relative(dx: readSignedNumber(default: 1), dy: 0)
            case "E": let amount = readSignedNumber(default: 1); relative(dx: amount, dy: -amount)
            case "F": let amount = readSignedNumber(default: 1); relative(dx: amount, dy: amount)
            case "G": let amount = readSignedNumber(default: 1); relative(dx: -amount, dy: amount)
            case "H": let amount = readSignedNumber(default: 1); relative(dx: -amount, dy: -amount)
            case "M":
                skipSeparators()
                let xStart = index
                let x = readSignedNumber()
                let xRelative = xStart < characters.count && (characters[xStart] == "+" || characters[xStart] == "-")
                skipSeparators()
                guard index < characters.count, characters[index] == "," else { basic_rt_fail("DRAW expected comma in M command") }
                index += 1
                skipSeparators()
                let yStart = index
                let y = readSignedNumber()
                let yRelative = yStart < characters.count && (characters[yStart] == "+" || characters[yStart] == "-")
                drawTo(xRelative ? currentPoint.x + x : x, yRelative ? currentPoint.y + y : y)
            default:
                basic_rt_fail("DRAW unknown command \(command)")
            }
        }
        flush()
    }
}

// MARK: - Statements

@inline(__always) private func rtInt(_ value: Double) -> Int { Int(value.rounded()) }
private func rtColorArgument(_ pointer: UnsafeMutableRawPointer?) -> RTColor? {
    pointer.map { RTColor.resolve(rtValue($0)) }
}

@_cdecl("basic_rt_gfx_screen")
public func basic_rt_gfx_screen(_ mode: Double) {
    RTGraphics.require()
    RTGraphics.ensureMode()
}

/// `COLOR fg[, bg]`: the truecolor SGR the interpreter prints, and the
/// current graphics color. `background` is null when absent.
@_cdecl("basic_rt_gfx_color")
public func basic_rt_gfx_color(_ foreground: UnsafeMutableRawPointer?, _ background: UnsafeMutableRawPointer?) {
    let color = RTColor.resolve(rtValue(foreground))
    let back = background.map { RTColor.resolve(rtValue($0)) }
    var parts = ["38;2;\(color.red);\(color.green);\(color.blue)"]
    if let back { parts.append("48;2;\(back.red);\(back.green);\(back.blue)") }
    RTConsole.write("\u{1B}[\(parts.joined(separator: ";"))m")
    RTGraphics.currentColor = color
}

@_cdecl("basic_rt_gfx_pset")
public func basic_rt_gfx_pset(_ x: Double, _ y: Double, _ color: UnsafeMutableRawPointer?) {
    RTGraphics.require()
    let point = (x: rtInt(x), y: rtInt(y))
    RTGraphics.hostPixel(x: point.x, y: point.y, color: rtColorArgument(color) ?? RTGraphics.currentColor)
    RTGraphics.currentPoint = point
}

@_cdecl("basic_rt_gfx_preset")
public func basic_rt_gfx_preset(_ x: Double, _ y: Double, _ color: UnsafeMutableRawPointer?) {
    RTGraphics.require()
    let point = (x: rtInt(x), y: rtInt(y))
    RTGraphics.hostPixel(x: point.x, y: point.y, color: rtColorArgument(color) ?? .legacy(0))
    RTGraphics.currentPoint = point
}

@_cdecl("basic_rt_gfx_line")
public func basic_rt_gfx_line(_ x1: Double, _ y1: Double, _ x2: Double, _ y2: Double, _ color: UnsafeMutableRawPointer?) {
    RTGraphics.require()
    RTGraphics.hostLine(x1: rtInt(x1), y1: rtInt(y1), x2: rtInt(x2), y2: rtInt(y2), color: rtColorArgument(color) ?? RTGraphics.currentColor)
    RTGraphics.currentPoint = (rtInt(x2), rtInt(y2))
}

/// `CIRCLE (x,y), r[, color][, aspect]`; `aspect` < 0 means absent.
@_cdecl("basic_rt_gfx_circle")
public func basic_rt_gfx_circle(_ cx: Double, _ cy: Double, _ radius: Double, _ color: UnsafeMutableRawPointer?, _ aspect: Double, _ hasAspect: Bool) {
    RTGraphics.require()
    let resolved = rtColorArgument(color) ?? RTGraphics.currentColor
    let r = rtInt(radius)
    if hasAspect {
        guard aspect > 0 else { basic_rt_fail("CIRCLE aspect must be greater than zero") }
        let safeRadius = max(0, r)
        let radii: (x: Int, y: Int) = aspect < 1
            ? (safeRadius, max(0, Int((Double(safeRadius) * aspect).rounded())))
            : (max(0, Int((Double(safeRadius) / aspect).rounded())), safeRadius)
        RTGraphics.hostEllipse(cx: rtInt(cx), cy: rtInt(cy), rx: radii.x, ry: radii.y, color: resolved)
    } else {
        RTGraphics.hostCircle(cx: rtInt(cx), cy: rtInt(cy), radius: r, color: resolved)
    }
    RTGraphics.currentPoint = (rtInt(cx), rtInt(cy))
}

@_cdecl("basic_rt_gfx_paint")
public func basic_rt_gfx_paint(_ x: Double, _ y: Double, _ color: UnsafeMutableRawPointer?, _ border: UnsafeMutableRawPointer?) {
    RTGraphics.require()
    RTGraphics.hostPaint(x: rtInt(x), y: rtInt(y), color: RTColor.resolve(rtValue(color)), border: rtColorArgument(border))
}

@_cdecl("basic_rt_gfx_draw")
public func basic_rt_gfx_draw(_ source: UnsafeMutableRawPointer?) {
    RTGraphics.require()
    RTGraphics.draw(rtText(source))
}

/// `POINT(x, y)`: the palette index in the shadow framebuffer.
@_cdecl("basic_rt_gfx_point")
public func basic_rt_gfx_point(_ x: Double, _ y: Double) -> Double {
    RTGraphics.require()
    let px = rtInt(x), py = rtInt(y)
    guard RTGraphics.width > 0, RTGraphics.height > 0, px >= 0, py >= 0, px < RTGraphics.width, py < RTGraphics.height else { return 0 }
    return Double(RTGraphics.pixels[py * RTGraphics.width + px])
}
