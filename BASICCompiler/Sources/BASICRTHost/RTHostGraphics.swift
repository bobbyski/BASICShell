import Foundation
import VectorTerminalSDK

// BASICRTHost — the graphics half of the runtime, linked when present.
// Spike: proves the SDK links into a compiled program.

@_cdecl("basic_rt_host_graphics_available")
public func basic_rt_host_graphics_available() -> Bool {
    (try? VectorTerminalCanvas(timeoutMilliseconds: 100)) != nil
}
