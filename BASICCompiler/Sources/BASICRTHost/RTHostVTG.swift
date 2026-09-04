import Darwin
import Foundation
import VectorTerminalSDK
import BASICRT

// The `VectorTerminal()` object's methods, over the SDK canvas — the
// interpreter's `callVectorTerminalMethod` and the Shell's
// `BASICVectorTerminalHost` conformance, one dispatcher. Arguments and
// the result are VARIANT boxes.

enum RTHostVTG {
    nonisolated(unsafe) static var pollingEnabled = false
    nonisolated(unsafe) static var originalTermios: termios?

    /// The Shell's `requireVectorTerminal`: the canvas, and on first use the
    /// terminal in raw mode with resize events enabled.
    static func require() -> VectorTerminalCanvas {
        guard let canvas = RTHostCanvas.probe() else {
            basic_rt_fail("VectorTerminal graphics are not supported by this terminal")
        }
        startPolling(canvas)
        return canvas
    }

    static func startPolling(_ canvas: VectorTerminalCanvas) {
        guard !pollingEnabled, isatty(STDIN_FILENO) == 1 else { return }
        var original = termios()
        if tcgetattr(STDIN_FILENO, &original) == 0 {
            var raw = original
            raw.c_lflag &= ~tcflag_t(ICANON | ECHO)
            raw.c_lflag |= tcflag_t(ISIG)
            raw.c_cc.16 = 0
            raw.c_cc.17 = 0
            if tcsetattr(STDIN_FILENO, TCSANOW, &raw) == 0 { originalTermios = original }
        }
        canvas.enableResizeEvents()
        pollingEnabled = true
    }

    static func stopPolling() {
        guard pollingEnabled else { return }
        pollingEnabled = false
        // The Shell's stopVectorTerminalEventPolling: mouse reporting off
        // (VTG and ANSI), resize events off, then the terminal restored.
        RTHostCanvas.canvas?.disableMouseReporting()
        FileHandle.standardOutput.write(Data("\u{1B}[?1003l\u{1B}[?1002l\u{1B}[?1000l\u{1B}[?1006l".utf8))
        RTHostCanvas.canvas?.disableResizeEvents()
        if var original = originalTermios {
            _ = tcsetattr(STDIN_FILENO, TCSANOW, &original)
            originalTermios = nil
        }
    }

    // Argument coercions — the runtime's messages.
    static func string(_ value: RTValue) -> String {
        guard let string = value.string else { basic_rt_fail("Expected a string") }
        return string.description
    }
    static func integer(_ value: RTValue) -> Int {
        guard let number = value.number, number.rounded() == number else { basic_rt_fail("Expected an integer") }
        return Int(number)
    }
    static func present(_ arguments: [RTValue], _ index: Int) -> Bool {
        guard arguments.indices.contains(index) else { return false }
        switch arguments[index] {
        case .empty, .null: return false
        default: return true
        }
    }
    static func optionalString(_ arguments: [RTValue], _ index: Int) -> String? {
        present(arguments, index) ? string(arguments[index]) : nil
    }
    static func optionalInteger(_ arguments: [RTValue], _ index: Int) -> Int? {
        present(arguments, index) ? integer(arguments[index]) : nil
    }
    static func color(_ value: String?) -> VTGColor? {
        guard let value, value.lowercased() != "none" else { return nil }
        return VTGColor(value)
    }
    static func lineCap(_ value: String?) -> VTGLineCap? { value.flatMap { VTGLineCap(rawValue: $0.lowercased()) } }
    static func lineJoin(_ value: String?) -> VTGLineJoin? { value.flatMap { VTGLineJoin(rawValue: $0.lowercased()) } }
    static func count(_ arguments: [RTValue], _ range: ClosedRange<Int>, _ name: String) {
        guard range.contains(arguments.count) else {
            if range.lowerBound == range.upperBound {
                basic_rt_fail("\(name) expects \(range.lowerBound) argument\(range.lowerBound == 1 ? "" : "s")")
            }
            basic_rt_fail("\(name) expects \(range.lowerBound) to \(range.upperBound) arguments")
        }
    }

    /// `line`'s trailing `[lineCap][, layer]`: a string is the cap, a number the layer.
    static func lineStyle(_ arguments: [RTValue]) -> (lineCap: String?, layer: Int?) {
        var lineCap: String?, layer: Int?
        if present(arguments, 7) {
            if arguments[7].string != nil { lineCap = string(arguments[7]) } else { layer = integer(arguments[7]) }
        }
        if present(arguments, 8) { layer = integer(arguments[8]) }
        return (lineCap, layer)
    }

    /// `rect`'s trailing `[corners][, lineJoin][, layer]`.
    static func rectStyle(_ arguments: [RTValue]) -> (corners: String?, lineJoin: String?, layer: Int?) {
        var corners: String?, lineJoin: String?, layer: Int?
        var index = 9
        while index < arguments.count, index <= 11 {
            if present(arguments, index) {
                if arguments[index].string != nil {
                    if corners == nil, index == 9 { corners = string(arguments[index]) } else { lineJoin = string(arguments[index]) }
                } else {
                    guard index == arguments.count - 1 else { basic_rt_fail("rect layer must be the final argument") }
                    layer = integer(arguments[index])
                }
            }
            index += 1
        }
        return (corners, lineJoin, layer)
    }

    static func call(_ method: String, _ arguments: [RTValue]) -> RTValue {
        let canvas = require()
        switch method.uppercased() {
        case "CLEAR":
            count(arguments, 0...0, "clear"); canvas.clear()
        case "PRESENT":
            count(arguments, 0...0, "present"); canvas.present()
        case "DELETE":
            count(arguments, 1...1, "delete"); canvas.delete(id: string(arguments[0]))
        case "SETDEFAULTLAYER":
            count(arguments, 1...1, "setDefaultLayer"); canvas.setDefaultLayer(integer(arguments[0]))
        case "PIXEL":
            count(arguments, 4...5, "pixel")
            canvas.pixel(id: string(arguments[0]), x: integer(arguments[1]), y: integer(arguments[2]), color: VTGColor(string(arguments[3])), layer: optionalInteger(arguments, 4))
        case "LINE":
            count(arguments, 6...9, "line")
            let style = lineStyle(arguments)
            canvas.line(id: string(arguments[0]), x1: integer(arguments[1]), y1: integer(arguments[2]), x2: integer(arguments[3]), y2: integer(arguments[4]),
                        stroke: VTGColor(string(arguments[5])), width: optionalInteger(arguments, 6) ?? 1, lineCap: lineCap(style.lineCap), layer: style.layer)
        case "RECT":
            count(arguments, 5...12, "rect")
            let style = rectStyle(arguments)
            canvas.rect(id: string(arguments[0]), x: integer(arguments[1]), y: integer(arguments[2]), width: integer(arguments[3]), height: integer(arguments[4]),
                        stroke: color(optionalString(arguments, 5)), fill: color(optionalString(arguments, 6)), lineWidth: optionalInteger(arguments, 7) ?? 1,
                        radius: optionalInteger(arguments, 8) ?? 0, corners: style.corners, lineJoin: lineJoin(style.lineJoin), layer: style.layer)
        case "CIRCLE":
            count(arguments, 4...8, "circle")
            canvas.circle(id: string(arguments[0]), cx: integer(arguments[1]), cy: integer(arguments[2]), radius: integer(arguments[3]),
                          stroke: color(optionalString(arguments, 4)), fill: color(optionalString(arguments, 5)), lineWidth: optionalInteger(arguments, 6) ?? 1, layer: optionalInteger(arguments, 7))
        case "ELLIPSE":
            count(arguments, 5...9, "ellipse")
            canvas.ellipse(id: string(arguments[0]), cx: integer(arguments[1]), cy: integer(arguments[2]), rx: integer(arguments[3]), ry: integer(arguments[4]),
                           stroke: color(optionalString(arguments, 5)), fill: color(optionalString(arguments, 6)), lineWidth: optionalInteger(arguments, 7) ?? 1, layer: optionalInteger(arguments, 8))
        case "TEXT":
            count(arguments, 5...7, "text")
            canvas.text(id: string(arguments[0]), x: integer(arguments[1]), y: integer(arguments[2]), value: string(arguments[3]), color: VTGColor(string(arguments[4])),
                        size: optionalInteger(arguments, 5) ?? 14, layer: optionalInteger(arguments, 6))
        case "VECTORPRINT":
            count(arguments, 5...8, "vectorPrint")
            canvas.vectorPrint(id: string(arguments[0]), x: integer(arguments[1]), y: integer(arguments[2]), height: integer(arguments[3]), value: string(arguments[4]),
                               stroke: VTGColor(optionalString(arguments, 5) ?? "#f8fafc"), width: optionalInteger(arguments, 6) ?? 1, layer: optionalInteger(arguments, 7))
        case "CANVASWIDTH":
            return .number(Double(RTHostCanvas.liveSize.width))
        case "CANVASHEIGHT":
            return .number(Double(RTHostCanvas.liveSize.height))
        default:
            basic_rt_fail("VectorTerminal has no method \(method)")
        }
        return .empty
    }
}

@_cdecl("basic_rt_host_vtg_call")
public func basic_rt_host_vtg_call(_ method: UnsafePointer<CChar>, _ count: Int, _ arguments: UnsafePointer<UnsafeMutableRawPointer?>) -> UnsafeMutableRawPointer {
    let values = (0..<count).map { rtValue(arguments[$0]) }
    return rtOwned(RTHostVTG.call(String(cString: method), values))
}

@_cdecl("basic_rt_host_gfx_finish")
public func basic_rt_host_gfx_finish() {
    RTHostVTG.stopPolling()
}

/// Mouse reporting: what the Shell turns on when a program registers an
/// `ON MOUSE … CALL` handler — the VTG stream and the ANSI modes together.
@_cdecl("basic_rt_host_mouse_reporting")
public func basic_rt_host_mouse_reporting(_ enabled: Bool) {
    guard let canvas = RTHostCanvas.probe() else { return }
    if enabled {
        // The Shell's `requireVectorTerminal`: a program reading events keeps
        // the terminal raw, so a report is never held back by the line
        // discipline waiting for a newline.
        RTHostVTG.startPolling(canvas)
        canvas.enableMouseReporting(mode: "all")
        FileHandle.standardOutput.write(Data("\u{1B}[?1000h\u{1B}[?1002h\u{1B}[?1003h\u{1B}[?1006h".utf8))
    } else {
        canvas.disableMouseReporting()
        FileHandle.standardOutput.write(Data("\u{1B}[?1003l\u{1B}[?1002l\u{1B}[?1000l\u{1B}[?1006l".utf8))
    }
}
