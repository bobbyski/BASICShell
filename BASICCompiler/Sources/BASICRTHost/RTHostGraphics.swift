import Foundation
import VectorTerminalSDK

// BASICRTHost — the graphics half of the runtime: the hooks BASICRT's
// RTGraphics calls, over a VectorTerminalSDK canvas on stdout, the way
// BASICShell's ConsoleHost draws. Linked when the archive is present;
// BASICRTHostStubs answers otherwise.

enum RTHostCanvas {
    nonisolated(unsafe) static var canvas: VectorTerminalCanvas?
    nonisolated(unsafe) static var probed = false
    nonisolated(unsafe) static var liveSize = (width: 0, height: 0)

    /// The Shell's probe: a terminal on stdout that answers `capabilities?`
    /// within 750 ms, else no graphics.
    static func probe() -> VectorTerminalCanvas? {
        if probed { return canvas }
        probed = true
        guard isatty(STDOUT_FILENO) == 1 else { return nil }
        fflush(stdout)
        guard let created = try? VectorTerminalCanvas(timeoutMilliseconds: 750) else { return nil }
        canvas = created
        if let current = created.queryCurrentCanvas(timeoutMilliseconds: 750) {
            liveSize = (current.width, current.height)
        }
        return created
    }
}

@_cdecl("basic_rt_host_graphics_available")
public func basic_rt_host_graphics_available() -> Bool {
    RTHostCanvas.probe() != nil
}

@_cdecl("basic_rt_host_gfx_canvas_size")
public func basic_rt_host_gfx_canvas_size(_ width: UnsafeMutablePointer<Int>, _ height: UnsafeMutablePointer<Int>) -> Bool {
    guard RTHostCanvas.probe() != nil else { return false }
    width.pointee = RTHostCanvas.liveSize.width
    height.pointee = RTHostCanvas.liveSize.height
    return true
}

@_cdecl("basic_rt_host_gfx_pixel")
public func basic_rt_host_gfx_pixel(_ id: UnsafePointer<CChar>, _ x: Int, _ y: Int, _ color: UnsafePointer<CChar>) {
    RTHostCanvas.canvas?.pixel(id: String(cString: id), x: x, y: y, color: VTGColor(String(cString: color)), layer: nil)
}

@_cdecl("basic_rt_host_gfx_line")
public func basic_rt_host_gfx_line(_ id: UnsafePointer<CChar>, _ x1: Int, _ y1: Int, _ x2: Int, _ y2: Int, _ color: UnsafePointer<CChar>, _ width: Int) {
    RTHostCanvas.canvas?.line(id: String(cString: id), x1: x1, y1: y1, x2: x2, y2: y2, stroke: VTGColor(String(cString: color)), width: width, layer: nil)
}

@_cdecl("basic_rt_host_gfx_draw")
public func basic_rt_host_gfx_draw(_ id: UnsafePointer<CChar>, _ count: Int, _ xs: UnsafePointer<Int>, _ ys: UnsafePointer<Int>, _ color: UnsafePointer<CChar>, _ width: Int) {
    let points = (0..<count).map { VTGPoint(x: xs[$0], y: ys[$0]) }
    RTHostCanvas.canvas?.draw(id: String(cString: id), points: points, stroke: VTGColor(String(cString: color)), width: width, layer: nil)
}

@_cdecl("basic_rt_host_gfx_circle")
public func basic_rt_host_gfx_circle(_ id: UnsafePointer<CChar>, _ cx: Int, _ cy: Int, _ radius: Int, _ color: UnsafePointer<CChar>, _ lineWidth: Int) {
    RTHostCanvas.canvas?.circle(id: String(cString: id), cx: cx, cy: cy, radius: radius, stroke: VTGColor(String(cString: color)), fill: nil, lineWidth: lineWidth, layer: nil)
}

@_cdecl("basic_rt_host_gfx_ellipse")
public func basic_rt_host_gfx_ellipse(_ id: UnsafePointer<CChar>, _ cx: Int, _ cy: Int, _ rx: Int, _ ry: Int, _ color: UnsafePointer<CChar>, _ lineWidth: Int) {
    RTHostCanvas.canvas?.ellipse(id: String(cString: id), cx: cx, cy: cy, rx: rx, ry: ry, stroke: VTGColor(String(cString: color)), fill: nil, lineWidth: lineWidth, layer: nil)
}

@_cdecl("basic_rt_host_gfx_clear")
public func basic_rt_host_gfx_clear() {
    RTHostCanvas.canvas?.clear()
}

@_cdecl("basic_rt_host_gfx_present")
public func basic_rt_host_gfx_present() {
    RTHostCanvas.canvas?.present()
}
