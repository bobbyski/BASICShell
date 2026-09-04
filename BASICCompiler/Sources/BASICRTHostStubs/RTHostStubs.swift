import Foundation

// The core's failure entry, by symbol: the stubs are compiled either as
// their own module (SwiftPM) or alongside the core sources (the driver's
// fallback), so they import nothing.
@_silgen_name("basic_rt_fail") private func rtStubFail(_ message: UnsafePointer<CChar>) -> Never

// BASICRTHostStubs — what a program links when the host half of the runtime
// (BASICRTHost: VTG graphics, TUIKit, events) is not available: every host
// entry point answers "not supported by this terminal", the interpreter's
// own message when its host lacks the surface.

@_cdecl("basic_rt_host_graphics_available")
public func basic_rt_host_graphics_available() -> Bool { false }

@_cdecl("basic_rt_host_gfx_canvas_size")
public func basic_rt_host_gfx_canvas_size(_ width: UnsafeMutablePointer<Int>, _ height: UnsafeMutablePointer<Int>) -> Bool { false }

@_cdecl("basic_rt_host_gfx_pixel")
public func basic_rt_host_gfx_pixel(_ id: UnsafePointer<CChar>, _ x: Int, _ y: Int, _ color: UnsafePointer<CChar>) {}

@_cdecl("basic_rt_host_gfx_line")
public func basic_rt_host_gfx_line(_ id: UnsafePointer<CChar>, _ x1: Int, _ y1: Int, _ x2: Int, _ y2: Int, _ color: UnsafePointer<CChar>, _ width: Int) {}

@_cdecl("basic_rt_host_gfx_draw")
public func basic_rt_host_gfx_draw(_ id: UnsafePointer<CChar>, _ count: Int, _ xs: UnsafePointer<Int>, _ ys: UnsafePointer<Int>, _ color: UnsafePointer<CChar>, _ width: Int) {}

@_cdecl("basic_rt_host_gfx_circle")
public func basic_rt_host_gfx_circle(_ id: UnsafePointer<CChar>, _ cx: Int, _ cy: Int, _ radius: Int, _ color: UnsafePointer<CChar>, _ lineWidth: Int) {}

@_cdecl("basic_rt_host_gfx_ellipse")
public func basic_rt_host_gfx_ellipse(_ id: UnsafePointer<CChar>, _ cx: Int, _ cy: Int, _ rx: Int, _ ry: Int, _ color: UnsafePointer<CChar>, _ lineWidth: Int) {}

@_cdecl("basic_rt_host_gfx_clear")
public func basic_rt_host_gfx_clear() {}

@_cdecl("basic_rt_host_gfx_present")
public func basic_rt_host_gfx_present() {}

@_cdecl("basic_rt_host_gfx_finish")
public func basic_rt_host_gfx_finish() {}

@_cdecl("basic_rt_host_vtg_call")
public func basic_rt_host_vtg_call(_ method: UnsafePointer<CChar>, _ count: Int, _ arguments: UnsafePointer<UnsafeMutableRawPointer?>) -> UnsafeMutableRawPointer {
    rtStubFail("VectorTerminal graphics are not supported by this host")
}

@_cdecl("basic_rt_host_mouse_reporting")
public func basic_rt_host_mouse_reporting(_ enabled: Bool) {}

@_cdecl("basic_rt_host_canvas_update")
public func basic_rt_host_canvas_update(_ width: Int, _ height: Int, _ source: UnsafePointer<CChar>) {}
