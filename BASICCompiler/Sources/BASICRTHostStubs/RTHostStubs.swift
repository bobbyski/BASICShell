import Foundation

// BASICRTHostStubs — what a program links when the host half of the runtime
// (BASICRTHost: VTG graphics, TUIKit, events) is not available: every host
// entry point answers "not supported by this terminal", the interpreter's
// own message when its host lacks the surface.

@_cdecl("basic_rt_host_graphics_available")
public func basic_rt_host_graphics_available() -> Bool { false }
