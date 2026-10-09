import Foundation

// BASICRT, hosted — the runtime inside an app rather than owning a process
// (BASIC-42).
//
// A native program owns its process: the runtime writes to stdout, reads
// stdin, installs signal handlers, keeps its state in globals, and calls
// exit() on an error it cannot hand to ON ERROR. A program compiled to
// WebAssembly runs inside BASICStudio, or inside basicc's runner, where none
// of that is the runtime's to do. Hosted mode is switched on by setting
// `unwind`, which only those hosts do; a native program never sets it, and
// every path below is then exactly what it was.
//
//   - Console text, line input and keys go to the host's hooks.
//   - A runtime error does not exit, and does not longjmp into compiled code:
//     `unwind` is called instead, and must not return. The WebAssembly host
//     longjmps back to the C trampoline that made the call into the runtime,
//     and turns the code into an exception for the module.
//   - `basic_rt_start` puts every piece of runtime state back as a new
//     process has it, so a second run in the same app starts clean.

/// The hooks a host sets to run BASICRT inside itself.
public enum RTHosted {
    /// Why the runtime is giving control back.
    public enum Unwind: Int32, Sendable {
        /// An error with ON ERROR active, or inside an async body: the
        /// compiled code's `setjmp` would have landed.
        case landed = 1
        /// An error nothing handles. The message is already printed.
        case fatal = 2
    }

    /// Where console text goes. Nil: stdout.
    nonisolated(unsafe) public static var output: ((String) -> Void)?
    /// The next line typed, for INPUT and LINE INPUT. Nil: stdin.
    nonisolated(unsafe) public static var readLine: ((_ prompt: String) -> String?)?
    /// The next key pressed, or "" when none is waiting, for INKEY$. Nil: the
    /// terminal.
    nonisolated(unsafe) public static var inkey: (() -> String)?
    /// Gives control back to the host. Must not return.
    nonisolated(unsafe) public static var unwind: ((Unwind) -> Never)?
    /// Ends the run here if the host was asked to stop it, and returns
    /// otherwise. For a wait inside the runtime — an ActiveUI window's
    /// `run` — where the compiled code's own loop checks never come.
    nonisolated(unsafe) public static var checkStop: (() -> Void)?
    /// Brings events the host collected on other threads into the queue: an
    /// ActiveUI click. Called at every drain, before the queue is read.
    nonisolated(unsafe) public static var collectEvents: (() -> Void)?

    /// Whether a host has the runtime.
    public static var isActive: Bool { unwind != nil }

    /// What a Stop says: the interpreter's, and a native program's on Ctrl-C.
    public static func breakMessage() -> String {
        "Break at \(RTLocations.current()?.line ?? RTError.line)"
    }

    /// The runtime's end-of-program tidy-up, for a run that was stopped or
    /// failed before compiled code reached its own `basic_rt_finish`.
    public static func finish() {
        RTSound.finish()
        RTGraphics.finish()
        RTTasks.finish()
    }

    /// Writes console text where the host wants it, or to stdout.
    static func write(_ text: String) {
        if let output {
            output(text)
        } else {
            fputs(text, stdout)
        }
    }

    /// Every piece of runtime state, as a new process has it.
    static func reset() {
        RTData.kinds = nil
        RTData.numbers = nil
        RTData.strings = nil
        RTData.count = 0
        RTData.index = 0
        RTConsole.column = 0
        RTCapture.active = false
        RTCapture.text = ""
        RTCapture.column = 0
        RTGosubStack.entries = []
        RTRandom.state = 0x4d595df4d0f33173
        RTRandom.lastValue = 0
        RTError.jumpBuffer = nil
        RTError.handler = -1
        RTError.isHandling = false
        RTError.statement = 0
        RTError.line = 0
        RTError.lastNumber = 0
        RTError.lastLine = 0
        RTError.faultStatement = 0
        RTLocations.here = nil
        RTLocations.count = 0
        RTLocations.lines = nil
        RTLocations.columns = nil
        RTLocations.sources = nil
        RTEvents.handlers = [:]
        RTEvents.queue = []
        RTEvents.timers = [:]
        RTEvents.nextTimerID = 1
        RTEvents.dispatching = false
        RTEvents.wantsHostInput = false
        RTTerminalEvents.canvasSize = (width: 0, height: 0)
        RTFiles.open = [:]
        RTFiles.fieldValues = [:]
        RTFiles.pending = [:]
        RTKeys.encoding = .aibasic
        RTKeys.lastExitKey = ""
        RTKeys.partialEscape = []
        RTKeys.lastSeen = [:]
        RTKeys.repeating = []
        RTSound.numbers = [:]
        RTSound.texts = [:]
        RTGraphics.currentColor = RTColor.legacy(1)
        RTGraphics.currentPoint = (x: 0, y: 0)
        RTGraphics.width = 0
        RTGraphics.height = 0
        RTGraphics.pixels = []
        RTGraphics.operationID = 0
        RTGraphics.didUse = false
        RTGraphics.availability = nil
        RTUsing.format = ""
        RTUsing.values = []
        RTTasks.nextID = 2
        RTTasks.tasks = []
        RTTasks.currentTaskID = 1
        RTTasks.capture = nil
        RTTasks.restore = nil
        RTTasks.boundaries = []
        RTTasks.boundaryError = nil
        RTTasks.boundaryNumber = 0
        RTTypes.enumTables = [:]
        RTTypes.registry = []
    }
}
