import BASICCore
import BASICRT
import Foundation
import VectorTerminalSDK

// BASICRTHost — what a host gives a hosted run beyond its console (BASIC-45).
//
// A native program owns a terminal: it draws on it, reads its keys and mouse,
// and asks it its size. A program BASICStudio runs as WebAssembly has
// Studio instead, which the interpreter's programs already use: its canvas,
// its windows, its touch controls, the keys it sees go down and come up, and
// the events its console and windows post. Each is installed for one run and
// taken away after it, so nothing of one run reaches the next.

/// The services a hosted run has.
public enum RTHostHosted {
    /// Gives the run about to start what its host has. Anything nil is what
    /// a program has without a host: no windows, no touch screen, the
    /// terminal on stdout for graphics and size, KEYDOWN from INKEY$.
    public static func install(
        windows: BASICAUIHost?,
        touchControls: BASICTouchControlsHost?,
        canvas: VectorTerminalCanvas?,
        canvasSize: (() -> (width: Int, height: Int))?,
        screenSize: (() -> (columns: Int, rows: Int))?,
        keyDown: ((String) -> Bool?)?,
        readKey: (() -> String?)?,
        tui: BASICTUIPresentationHost?
    ) {
        BASICCompiledEvents.reset()
        BASICCompiledAUI.reset()
        BASICCompiledTouchControls.reset()
        RTHostAUI.host = windows
        BASICCompiledTUI.presentationHost = tui
        RTHosted.collectEvents = collectEvents
        RTHosted.keyDown = keyDown
        RTHosted.readKey = readKey
        RTHosted.screenSize = screenSize
        RTHosted.touchControls = { method, arguments in
            callTouchControls(method, arguments, host: touchControls)
        }
        RTHosted.hasTouchScreen = { touchControls?.hasTouchScreen ?? false }
        if let canvas {
            RTHostCanvas.installHosted(canvas, size: canvasSize ?? { (width: 0, height: 0) })
            RTHosted.keepsGraphicsAtEnd = true
        }
    }

    /// The run is over.
    public static func uninstall() {
        RTHostAUI.host = nil
        BASICCompiledTUI.presentationHost = nil
        RTHosted.collectEvents = nil
        RTHosted.keyDown = nil
        RTHosted.readKey = nil
        RTHosted.screenSize = nil
        RTHosted.touchControls = nil
        RTHosted.hasTouchScreen = nil
        if RTHostCanvas.isHosted { RTHostCanvas.uninstallHosted() }
        RTHosted.keepsGraphicsAtEnd = false
        BASICCompiledEvents.reset()
        BASICCompiledAUI.reset()
        BASICCompiledTouchControls.reset()
    }

    /// Brings what the host posted into the program's queue: an ActiveUI
    /// event to its control's own handler when the control named one (and
    /// nowhere when that function is not in the program, as the
    /// interpreter does), anything else to `ON <type> CALL`. A resize also
    /// becomes the canvas's size, as a terminal's resize report does.
    static func collectEvents() {
        for event in BASICCompiledEvents.take() {
            var fields: [String: RTValue] = [:]
            for (name, value) in event.fields { fields[name] = runtimeValue(value) }
            var handler: RTEventHandler?
            if event.type == "AUI", case .number(let source)? = event.fields["source"],
               let name = BASICCompiledAUI.handler(id: Int(source), kind: event.subtype) {
                guard let trampoline = RTTUIHandlers.trampolines[name.uppercased()] else { continue }
                handler = RTEventHandler(trampoline: trampoline, typeIndex: RTTypes.index(ofType: "BASICAUIEVENT") ?? -1)
            }
            if event.type == "RESIZE", RTHostCanvas.isHosted,
               case .number(let width)? = event.fields["width"], case .number(let height)? = event.fields["height"] {
                RTHostCanvas.liveSize = (Int(width), Int(height))
                RTHostCanvas.liveSource = "resize"
            }
            RTEvents.post(type: event.type, subtype: event.subtype, fields: fields, handler: handler)
        }
    }

    private static func callTouchControls(_ method: String, _ arguments: [RTValue], host: BASICTouchControlsHost?) -> RTValue {
        let values = arguments.map { argument -> BASICCompiledTouchControls.Value in
            switch argument {
            case .number(let number): return .number(number)
            case .boolean(let flag): return .boolean(flag)
            case .string(let text): return .string(text.description)
            default:
                if let text = argument.string { return .string(text.description) }
                if let number = argument.number { return .number(number) }
                return .empty
            }
        }
        do {
            return runtimeValue(try BASICCompiledTouchControls.call(method: method, arguments: values, host: host))
        } catch let failure as BASICCompiledTouchControls.Failure {
            basic_rt_fail(failure.message)
        } catch {
            basic_rt_fail("\(error)")
        }
    }

    private static func runtimeValue(_ value: BASICCompiledEvents.Value) -> RTValue {
        switch value {
        case .number(let number): return .number(number)
        case .boolean(let flag): return .boolean(flag)
        case .string(let text): return .string(RTText(text))
        case .handle, .empty: return .empty
        }
    }
}
