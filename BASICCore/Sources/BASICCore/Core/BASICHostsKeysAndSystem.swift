import Foundation
#if canImport(Darwin)
import Darwin
#endif

enum BASICFileListFormatter {
    static func columns(_ names: [String], terminalColumns: Int) -> String {
        guard !names.isEmpty else { return "" }

        let availableColumns = max(1, terminalColumns)
        let longestNameWidth = names.map(\.count).max() ?? 0
        let paddedColumnWidth = longestNameWidth + 2
        let columnCount = max(1, (availableColumns + 2) / max(1, paddedColumnWidth))
        let rowCount = Int(ceil(Double(names.count) / Double(columnCount)))

        return (0..<rowCount).map { row in
            var cells: [String] = []
            for column in 0..<columnCount {
                let index = column * rowCount + row
                guard index < names.count else { continue }
                cells.append(names[index])
            }

            return cells.enumerated().map { index, name in
                guard index < cells.count - 1 else { return name }
                return name.padding(toLength: paddedColumnWidth, withPad: " ", startingAt: 0)
            }.joined()
        }.joined(separator: "\n")
    }
}

extension BASICType {
    var name: String {
        switch self {
        case .scalar(let scalar): return scalar.rawValue
        case .void: return "VOID"
        case .record(let name): return name
        case .classType(let name): return name
        case .interfaceType(let name): return name
        case .functionType(let name): return name
        case .dictionary: return "DICTIONARY"
        }
    }
}

/// Minimal host interface used by the interpreter for terminal-like I/O.
public protocol BASICHost: AnyObject {
    /// Writes text without forcing a line break.
    func print(_ text: String, terminator: String)
    /// Writes one complete line of text.
    func printLine(_ text: String)
    /// Reads one line of input for INPUT and LINE INPUT.
    func readLine(prompt: String) -> String?
}

/// Session-shared serialization boundary for console and log output.
///
/// Async BASIC interpreters may execute on different Swift lanes. They retain the real host
/// for capability checks, while all user-visible output passes through this coordinator so
/// terminal writes cannot interleave and UI hosts keep their own main-actor adapter intact.
final class BASICHostOutputCoordinator: @unchecked Sendable {
    private let lock = NSRecursiveLock()
    private let host: BASICHost

    init(host: BASICHost) {
        self.host = host
    }

    func print(_ text: String, terminator: String) {
        lock.lock()
        defer { lock.unlock() }
        host.print(text, terminator: terminator)
    }

    func printLine(_ text: String) {
        lock.lock()
        defer { lock.unlock() }
        host.printLine(text)
    }

    func log(level: String, issuer: String, module: String, text: String) {
        lock.lock()
        defer { lock.unlock() }
        (host as? any BASICLoggingHost)?.log(level: level, issuer: issuer, module: module, text: text)
    }
}

/// Optional host capability for ANSI-colored LIST output.
public protocol BASICListingStyleHost: BASICHost {
    /// True when the host can safely render ANSI syntax coloring for LIST output.
    var usesColoredListing: Bool { get }
}

/// Optional host capability for restoring any alternate display surface before errors are printed.
public protocol BASICRunDisplayHost: BASICHost {
    func prepareToPrintRunResult()
}

/// Result returned by hosts that can stop LINE INPUT on special keys.
public struct BASICLineInputResult: Equatable, Sendable {
    /// Text typed before completion or special-key exit.
    public let text: String
    /// Normalized special key that ended input, if any.
    public let exitKey: String?

    /// Creates a line-input result.
    public init(text: String, exitKey: String? = nil) {
        self.text = text
        self.exitKey = exitKey
    }
}

/// Field constraints for configured LINE INPUT operations.
public struct BASICLineInputOptions: Equatable, Sendable {
    /// Visible field width, if the host should render a fixed-width entry field.
    public let fieldLength: Int?
    /// Maximum accepted input length.
    public let maxLength: Int?
    /// Text used to prefill the input buffer.
    public let defaultText: String?

    /// Creates line-input rendering and validation options.
    public init(fieldLength: Int? = nil, maxLength: Int? = nil, defaultText: String? = nil) {
        self.fieldLength = fieldLength
        self.maxLength = maxLength
        self.defaultText = defaultText
    }
}

/// Host extension point for LINE INPUT EXITVAR support.
public protocol BASICLineInputHost: BASICHost {
    /// Reads one line, optionally exiting early on special keys.
    func readLine(prompt: String, exitOnSpecialKey: Bool) -> BASICLineInputResult?
}

/// Host extension point for configured LINE INPUT field behavior.
public protocol BASICConfiguredLineInputHost: BASICLineInputHost {
    /// Reads one configured line-input field.
    func readLine(prompt: String, exitOnSpecialKey: Bool, options: BASICLineInputOptions) -> BASICLineInputResult?
}

/// Host interface for BASIC file-system operations.
public protocol BASICFileHost: BASICHost {
    /// Loads a UTF-8 text file.
    func loadTextFile(path: String) throws -> String
    /// Saves a UTF-8 text file.
    func saveTextFile(path: String, text: String) throws
    /// Returns whether a path exists.
    func fileExists(path: String) throws -> Bool
    /// Returns the BASIC working directory.
    func currentDirectoryPath() throws -> String
    /// Changes the BASIC working directory.
    func changeDirectory(path: String) throws
    /// Lists files in the current BASIC working directory.
    func listFiles() throws -> [String]
    /// Lists files in a specific directory path.
    func listFiles(path: String) throws -> [String]
}

/// A host-provided HTTP response returned by asynchronous network operations.
public struct BASICHTTPResponse: Equatable, Sendable {
    /// Final response URL after redirects, when known.
    public let url: String
    /// HTTP status code.
    public let statusCode: Int
    /// UTF-8 response body. Hosts may replace invalid UTF-8 with the Unicode replacement character.
    public let body: String
    /// Response headers represented as display strings.
    public let headers: [String: String]

    /// Creates an HTTP response value for the BASIC network boundary.
    public init(url: String, statusCode: Int, body: String, headers: [String: String] = [:]) {
        self.url = url
        self.statusCode = statusCode
        self.body = body
        self.headers = headers
    }
}

/// Host interface for asynchronous network operations.
public protocol BASICNetworkHost: BASICHost {
    /// Performs an HTTP GET without blocking the serialized BASIC runtime lane.
    func httpGet(url: String) async throws -> BASICHTTPResponse
}

/// Host interface for SYSTEM and SYSTEM$ command execution.
public protocol BASICSystemHost: BASICHost {
    /// Runs a shell command and returns combined output.
    func runSystemCommand(_ command: String) throws -> String
    /// Runs a shell command and returns combined output plus process status.
    func runSystemCommandResult(_ command: String, environment: BASICEnvironmentPatch) throws -> BASICSystemCommandResult
}

/// Host interface for structured foreground process execution.
public protocol BASICProcessHost: BASICHost {
    /// Runs an executable directly with argv-style arguments.
    func runProcess(_ request: BASICProcessRequest) throws -> BASICProcessResult
    /// Runs argv-style processes as a foreground pipeline.
    func runPipeline(_ requests: [BASICProcessRequest]) throws -> BASICProcessResult
}

/// Optional host capability for running shell-mode fallback commands on the foreground terminal.
public protocol BASICForegroundTTYProcessHost: BASICHost {
    /// True when the host wants shell-mode external commands to inherit terminal stdin/stdout/stderr.
    var supportsForegroundTTYProcesses: Bool { get }
}

/// Optional host capability for resolving executables against a shell-like environment.
public protocol BASICExecutableResolverHost: BASICHost {
    /// Resolves a command name or path to an executable path.
    func resolveExecutable(_ command: String, environment: BASICEnvironmentPatch) throws -> String?
}

/// Optional host capability for interactive command history.
public protocol BASICCommandHistoryHost: BASICHost {
    /// Returns persisted command history in oldest-to-newest order.
    func commandHistoryEntries() -> [String]
    /// Removes all persisted command history.
    func clearCommandHistory()
    /// Deletes a command history entry using a zero-based index.
    func deleteCommandHistoryEntry(at index: Int) throws
}

/// Public canvas snapshot returned by VectorTerminal host adapters.
public struct BASICVectorTerminalCanvasSnapshot: Sendable {
    /// VTG pixel width.
    public let width: Int
    /// VTG pixel height.
    public let height: Int
    /// Source query or host source that produced the snapshot.
    public let source: String?
    /// Raw response text, when available.
    public let rawResponse: String?

    public init(width: Int, height: Int, source: String? = nil, rawResponse: String? = nil) {
        self.width = width
        self.height = height
        self.source = source
        self.rawResponse = rawResponse
    }
}

/// Public terminal cell snapshot returned by VectorTerminal host adapters.
public struct BASICVectorTerminalCellSnapshot: Sendable {
    /// Visible terminal columns.
    public let columns: Int
    /// Visible terminal rows.
    public let rows: Int
    /// Pixel width of one normal-width terminal glyph cell, when known.
    public let width: Double?
    /// Pixel height of one normal-width terminal glyph cell, when known.
    public let height: Double?

    public init(columns: Int, rows: Int, width: Double? = nil, height: Double? = nil) {
        self.columns = columns
        self.rows = rows
        self.width = width
        self.height = height
    }
}

/// Public retained UI layout returned by VectorTerminal host adapters.
public struct BASICVectorTerminalLayoutSnapshot: Sendable {
    /// Left edge in VTG pixel space.
    public let x: Int
    /// Top edge in VTG pixel space.
    public let y: Int
    /// Width in VTG pixels.
    public let width: Int
    /// Height in VTG pixels.
    public let height: Int
    /// Terminal row used to anchor the layout.
    public let row: Int?
    /// Terminal column used to anchor the layout.
    public let column: Int?

    public init(x: Int, y: Int, width: Int, height: Int, row: Int? = nil, column: Int? = nil) {
        self.x = x
        self.y = y
        self.width = width
        self.height = height
        self.row = row
        self.column = column
    }
}

/// Host interface for direct VectorTerminal Graphics (VTG) SDK operations.
public protocol BASICVectorTerminalHost: BASICHost {
    /// Indicates whether direct VTG operations are available on the current host.
    var isVectorTerminalAvailable: Bool { get }
    /// Clears retained VTG scene primitives.
    func vectorTerminalClear() throws
    /// Presents pending VTG scene updates.
    func vectorTerminalPresent() throws
    /// Deletes one retained VTG primitive by id.
    func vectorTerminalDelete(id: String) throws
    /// Clears a retained VTG rectangular region by id.
    func vectorTerminalClearRect(id: String, x: Int, y: Int, width: Int, height: Int, layer: Int?) throws
    /// Draws or replaces one VTG pixel primitive.
    func vectorTerminalPixel(id: String, x: Int, y: Int, color: String, layer: Int?) throws
    /// Draws or replaces one VTG line primitive.
    func vectorTerminalLine(id: String, x1: Int, y1: Int, x2: Int, y2: Int, stroke: String, width: Int, lineCap: String?, layer: Int?) throws
    /// Draws or replaces one VTG polyline primitive.
    func vectorTerminalDraw(id: String, points: [(x: Int, y: Int)], stroke: String, width: Int, lineCap: String?, lineJoin: String?, layer: Int?) throws
    /// Draws or replaces one VTG quadratic curve.
    func vectorTerminalQuadraticCurve(id: String, x1: Int, y1: Int, cx: Int, cy: Int, x2: Int, y2: Int, stroke: String, width: Int, lineCap: String?, lineJoin: String?, layer: Int?) throws
    /// Draws or replaces one VTG cubic curve.
    func vectorTerminalCubicCurve(id: String, x1: Int, y1: Int, c1x: Int, c1y: Int, c2x: Int, c2y: Int, x2: Int, y2: Int, stroke: String, width: Int, lineCap: String?, lineJoin: String?, layer: Int?) throws
    /// Draws or replaces one VTG path primitive.
    func vectorTerminalPath(id: String, payload: String, stroke: String?, fill: String?, lineWidth: Int, lineCap: String?, lineJoin: String?, layer: Int?) throws
    /// Draws or replaces one VTG triangle primitive.
    func vectorTerminalTriangle(id: String, x1: Int, y1: Int, x2: Int, y2: Int, x3: Int, y3: Int, stroke: String?, fill: String?, lineWidth: Int, radius: Int, lineJoin: String?, layer: Int?) throws
    /// Draws or replaces one VTG rectangle primitive.
    func vectorTerminalRect(id: String, x: Int, y: Int, width: Int, height: Int, stroke: String?, fill: String?, lineWidth: Int, radius: Int, corners: String?, lineJoin: String?, layer: Int?) throws
    /// Draws or replaces one VTG circle primitive.
    func vectorTerminalCircle(id: String, cx: Int, cy: Int, radius: Int, stroke: String?, fill: String?, lineWidth: Int, layer: Int?) throws
    /// Draws or replaces one VTG ellipse primitive.
    func vectorTerminalEllipse(id: String, cx: Int, cy: Int, rx: Int, ry: Int, stroke: String?, fill: String?, lineWidth: Int, layer: Int?) throws
    /// Draws or replaces host-rendered VTG text.
    func vectorTerminalText(id: String, x: Int, y: Int, value: String, color: String, size: Int, layer: Int?) throws
    /// Draws or replaces vector text.
    func vectorTerminalVectorPrint(id: String, x: Int, y: Int, height: Int, value: String, stroke: String, width: Int, layer: Int?) throws
    /// Measures vector text using the same advance rules as `vectorPrint`.
    func vectorTerminalVectorTextSize(height: Int, value: String) throws -> BASICVectorTerminalCanvasSnapshot
    /// Draws a terminal-cell-aligned pill behind normal terminal text.
    func vectorTerminalPillButton(id: String, text: String, fill: String, stroke: String?, lineWidth: Int, layer: Int?, target: String?, timeoutMilliseconds: Int) throws -> BASICVectorTerminalLayoutSnapshot?
    /// Draws or replaces a retained PNG image.
    func vectorTerminalImagePNG(id: String, x: Int, y: Int, width: Int, height: Int, data: Data, filter: String, layer: Int?) throws
    /// Draws or replaces a retained JPEG image.
    func vectorTerminalImageJPEG(id: String, x: Int, y: Int, width: Int, height: Int, data: Data, filter: String, layer: Int?) throws
    /// Uploads a PNG sprite asset.
    func vectorTerminalUploadSpritePNG(id: String, width: Int, height: Int, data: Data, filter: String) throws
    /// Uploads a JPEG sprite asset.
    func vectorTerminalUploadSpriteJPEG(id: String, width: Int, height: Int, data: Data, filter: String) throws
    /// Uploads a vector sprite asset.
    func vectorTerminalUploadVectorSprite(id: String, width: Int, height: Int, path: String, stroke: String?, fill: String?, lineWidth: Double) throws
    /// Uploads a palette-indexed sprite asset.
    func vectorTerminalUploadIndexedSprite(id: String, width: Int, height: Int, pixels: [Int], palette: [String], transparentIndex: Int?, filter: String) throws
    /// Places or replaces a retained sprite instance.
    func vectorTerminalSprite(id: String, imageID: String, x: Int, y: Int, rotation: Double, scale: Double, anchorX: Double, anchorY: Double, layer: Int?) throws
    /// Moves a retained sprite instance.
    func vectorTerminalMoveSprite(id: String, x: Int, y: Int) throws
    /// Rotates a retained sprite instance.
    func vectorTerminalRotateSprite(id: String, rotation: Double) throws
    /// Sets a retained sprite anchor.
    func vectorTerminalAnchorSprite(id: String, anchorX: Double, anchorY: Double) throws
    /// Transforms a retained sprite instance.
    func vectorTerminalTransformSprite(id: String, x: Int, y: Int, rotation: Double, scale: Double, anchorX: Double?, anchorY: Double?) throws
    /// Removes a sprite asset and dependent instances.
    func vectorTerminalRemoveSprite(id: String) throws
    /// Removes all sprite assets and instances.
    func vectorTerminalClearSprites() throws
    /// Changes the default VTG layer.
    func vectorTerminalSetDefaultLayer(_ layer: Int) throws
    /// Moves a retained VTG object to a layer.
    func vectorTerminalSetLayer(id: String, layer: Int) throws
    /// Scrolls an overlay layer.
    func vectorTerminalScrollLayer(_ layer: Int, x: Int, y: Int) throws
    /// Sets an overlay layer alpha.
    func vectorTerminalSetLayerAlpha(_ layer: Int, alpha: Double) throws
    /// Clips a VTG layer.
    func vectorTerminalClipLayer(_ layer: Int, x: Int, y: Int, width: Int, height: Int) throws
    /// Clears a VTG layer clip.
    func vectorTerminalClearLayerClip(_ layer: Int) throws
    /// Enables fixed-resolution viewport mapping for a VTG layer.
    func vectorTerminalSetViewportMode(layer: Int, width: Int, height: Int, scale: String) throws
    /// Clears fixed-resolution viewport mapping for a VTG layer.
    func vectorTerminalClearViewportMode(layer: Int) throws
    /// Overrides fixed-resolution viewport placement.
    func vectorTerminalSetViewportScale(layer: Int, scale: Double, x: Int, y: Int) throws
    /// Registers a VTG hit region.
    func vectorTerminalHitRegion(id: String, x: Int, y: Int, width: Int, height: Int, layer: Int?, target: String?) throws
    /// Clears VTG hit regions.
    func vectorTerminalClearHitRegions(id: String?, layer: Int?) throws
    /// Starts an offscreen VTG frame.
    func vectorTerminalStartFrame(id: String, timeoutMilliseconds: Int) throws
    /// Ends an offscreen VTG frame.
    func vectorTerminalEndFrame(id: String) throws
    /// Cancels an offscreen VTG frame.
    func vectorTerminalCancelFrame(id: String) throws
    /// Queries raw VTG capabilities.
    func vectorTerminalQueryCapabilities(timeoutMilliseconds: Int) throws -> String?
    /// Queries parsed VTG capabilities as JSON.
    func vectorTerminalQueryCapabilityInfo(timeoutMilliseconds: Int) throws -> String?
    /// Queries VTG canvas size.
    func vectorTerminalQueryCanvas(timeoutMilliseconds: Int) throws -> BASICVectorTerminalCanvasSnapshot?
    /// Queries legacy VTG size.
    func vectorTerminalQuerySize(timeoutMilliseconds: Int) throws -> BASICVectorTerminalCanvasSnapshot?
    /// Queries current VTG canvas size using SDK fallback order.
    func vectorTerminalQueryCurrentCanvas(timeoutMilliseconds: Int) throws -> BASICVectorTerminalCanvasSnapshot?
    /// Queries terminal cell size.
    func vectorTerminalQueryTerminalCellSize() throws -> BASICVectorTerminalCellSnapshot?
    /// Enables VTG resize events.
    func vectorTerminalEnableResizeEvents() throws
    /// Disables VTG resize events.
    func vectorTerminalDisableResizeEvents() throws
    /// Enables VTG mouse reporting.
    func vectorTerminalEnableMouseReporting(mode: String?) throws
    /// Disables VTG mouse reporting.
    func vectorTerminalDisableMouseReporting() throws
    /// Reads one VTG event.
    func vectorTerminalReadEvent(timeoutMilliseconds: Int) throws -> String?
    /// Enters alternate screen mode.
    func vectorTerminalEnterAlternateScreen() throws
    /// Leaves alternate screen mode.
    func vectorTerminalLeaveAlternateScreen() throws
    /// Enables bracketed paste.
    func vectorTerminalEnableBracketedPaste() throws
    /// Disables bracketed paste.
    func vectorTerminalDisableBracketedPaste() throws
    /// Enables focus reporting.
    func vectorTerminalEnableFocusReporting() throws
    /// Disables focus reporting.
    func vectorTerminalDisableFocusReporting() throws
    /// Clears the ANSI text screen through the SDK helper.
    func vectorTerminalClearScreen() throws
    /// Clears scrollback and the ANSI text screen through the SDK helper.
    func vectorTerminalClearScrollbackAndScreen() throws
    /// Clears the current ANSI line.
    func vectorTerminalClearLine() throws
    /// Clears the current ANSI line to the end.
    func vectorTerminalClearToEndOfLine() throws
    /// Writes plain ANSI text through the SDK helper.
    func vectorTerminalWriteText(_ value: String) throws
    /// Moves the ANSI cursor through the SDK helper.
    func vectorTerminalMoveCursor(row: Int, column: Int) throws
    /// Sets the ANSI cursor through the SDK helper.
    func vectorTerminalSetCursor(row: Int, column: Int) throws
    /// Moves the ANSI cursor up.
    func vectorTerminalMoveCursorUp(_ count: Int) throws
    /// Moves the ANSI cursor down.
    func vectorTerminalMoveCursorDown(_ count: Int) throws
    /// Moves the ANSI cursor forward.
    func vectorTerminalMoveCursorForward(_ count: Int) throws
    /// Moves the ANSI cursor backward.
    func vectorTerminalMoveCursorBackward(_ count: Int) throws
    /// Saves the ANSI cursor.
    func vectorTerminalSaveCursor() throws
    /// Restores the ANSI cursor.
    func vectorTerminalRestoreCursor() throws
    /// Hides the ANSI cursor.
    func vectorTerminalHideCursor() throws
    /// Shows the ANSI cursor.
    func vectorTerminalShowCursor() throws
    /// Resets ANSI text attributes.
    func vectorTerminalResetTextAttributes() throws
    /// Toggles ANSI bold.
    func vectorTerminalBold(_ enabled: Bool) throws
    /// Toggles ANSI underline.
    func vectorTerminalUnderline(_ enabled: Bool) throws
    /// Toggles ANSI inverse video.
    func vectorTerminalInverse(_ enabled: Bool) throws
    /// Sets ANSI foreground color.
    func vectorTerminalSetForeground(_ color: String, bright: Bool) throws
    /// Sets ANSI background color.
    func vectorTerminalSetBackground(_ color: String, bright: Bool) throws
    /// Sets ANSI RGB foreground color.
    func vectorTerminalSetForegroundRGB(red: Int, green: Int, blue: Int) throws
    /// Sets ANSI RGB background color.
    func vectorTerminalSetBackgroundRGB(red: Int, green: Int, blue: Int) throws
    /// Emits ANSI bell.
    func vectorTerminalBell() throws
}

public extension BASICVectorTerminalHost {
    /// Default for hosts that conform only when VTG is available.
    var isVectorTerminalAvailable: Bool { true }
}

/// Host interface for non-blocking INKEY$ keyboard input.
public protocol BASICKeyboardHost: BASICHost {
    /// Reads one pending raw key sequence, or nil when no key is pending.
    func readKey() -> String?
}

/// Optional host capability for INPUT$ keyboard reads that wait for key presses.
public protocol BASICBlockingKeyboardHost: BASICKeyboardHost {
    /// Reads one raw key sequence, waiting until a key is available or input is cancelled.
    func readBlockingKey() -> String?
}

/// Host interface for cursor positioning and screen-size queries.
public protocol BASICConsoleHost: BASICHost {
    /// Current console column count.
    func screenColumns() -> Int
    /// Current console row count.
    func screenRows() -> Int
    /// Moves the console cursor to a one-based row and column.
    func locate(row: Int, column: Int) throws
}

/// Host marker for UI surfaces whose mutations must run on the main actor.
public protocol BASICMainActorHost: BASICHost {
    /// Runs a UI-bound operation synchronously on the host's main actor.
    func runOnMainActorSync(_ operation: @MainActor () -> Void)
}

/// Runtime-owned timer scheduling bridge.
protocol BASICTimerHost: AnyObject {
    /// Starts or restarts a BASIC timer object.
    func startTimer(id: Int, intervalSeconds: Double, repeating: Bool)

    /// Stops a BASIC timer object.
    func stopTimer(id: Int)
}

/// Host interface for BASIC and system log collection.
public protocol BASICLoggingHost: BASICHost {
    /// Whether BASIC LOG statements and interpreter log hooks should be emitted.
    var isBASICLoggingEnabled: Bool { get }
    /// Whether the interpreter should emit one TRACE log for each executed BASIC statement.
    var isBASICTraceEnabled: Bool { get }
    /// Appends a log entry.
    func log(level: String, issuer: String, module: String, text: String)
}

public extension BASICLoggingHost {
    var isBASICTraceEnabled: Bool { false }
}

public extension BASICConsoleHost {
    /// Default console width for hosts that do not report a live size.
    func screenColumns() -> Int { 80 }

    /// Default console height for hosts that do not report a live size.
    func screenRows() -> Int { 25 }

    /// Default ANSI cursor-positioning implementation.
    func locate(row: Int, column: Int) throws {
        let safeRow = max(1, row)
        let safeColumn = max(1, column)
        print("\u{001B}[\(safeRow);\(safeColumn)H", terminator: "")
    }
}

/// Raw key constants and helpers for terminal key sequences.
public enum BASICRawKey {
    /// Raw escape character.
    public static let escape = "\u{1B}"
    /// Raw delete character.
    public static let delete = "\u{7F}"
    /// Raw backspace character.
    public static let backspace = "\u{8}"

    /// Returns a terminal escape sequence for a function key number.
    public static func functionKeySequence(_ number: Int) -> String? {
        switch number {
        case 1: return "\u{1B}OP"
        case 2: return "\u{1B}OQ"
        case 3: return "\u{1B}OR"
        case 4: return "\u{1B}OS"
        case 5: return "\u{1B}[15~"
        case 6: return "\u{1B}[17~"
        case 7: return "\u{1B}[18~"
        case 8: return "\u{1B}[19~"
        case 9: return "\u{1B}[20~"
        case 10: return "\u{1B}[21~"
        case 11: return "\u{1B}[23~"
        case 12: return "\u{1B}[24~"
        case 13: return "\u{1B}[25~"
        case 14: return "\u{1B}[26~"
        case 15: return "\u{1B}[28~"
        case 16: return "\u{1B}[29~"
        case 17: return "\u{1B}[31~"
        case 18: return "\u{1B}[32~"
        case 19: return "\u{1B}[33~"
        case 20: return "\u{1B}[34~"
        case 21: return "\u{1B}[35~"
        case 22: return "\u{1B}[36~"
        default: return nil
        }
    }
}

/// Output encoding used when normalizing special keys for INKEY$.
public enum BASICKeyEncoding {
    /// AIBasic textual key names such as `[K`, `[F1`, and `[GP:A`.
    case aibasic
    /// IBM/GW-BASIC-style extended key strings prefixed with CHR$(0).
    case ibm
}

/// Converts raw terminal or gamepad key events into BASIC INKEY$ strings.
public struct BASICKeyNormalizer {
    /// Normalizes a raw key sequence using the requested BASIC key encoding.
    public static func normalize(_ rawKey: String, encoding: BASICKeyEncoding = .aibasic) -> String {
        guard !rawKey.isEmpty else { return "" }
        if rawKey.hasPrefix("[GP:") {
            return rawKey
        }
        if rawKey.count == 1 {
            if rawKey == BASICRawKey.delete { return BASICRawKey.backspace }
            return rawKey
        }

        if let normalized = normalizedEscapeSequence(rawKey, encoding: encoding) {
            return normalized
        }

        return extended(code: 255, encoding: encoding)
    }

    private static func normalizedEscapeSequence(_ rawKey: String, encoding: BASICKeyEncoding) -> String? {
        guard rawKey.first == Character(BASICRawKey.escape) else { return nil }
        if rawKey == BASICRawKey.escape { return BASICRawKey.escape }

        let suffix = String(rawKey.dropFirst())
        let modifiers = modifiers(from: suffix)

        if let modifiedCharacter = modifiedCharacter(from: suffix) {
            return modifiedCharacter
        }

        if let code = modifiedNavigationCode(from: suffix) {
            return extended(code: code, shift: modifiers.shift, command: modifiers.command, option: modifiers.option, encoding: encoding)
        }

        if let key = modifiedFunctionKey(from: suffix) {
            return functionKey(key.number, ibmCode: key.ibmCode, shift: modifiers.shift, command: modifiers.command, option: modifiers.option, encoding: encoding)
        }

        switch suffix {
        case "[Z": return shiftTab(encoding: encoding)
        case "[A": return extended(code: 72, encoding: encoding)
        case "[B": return extended(code: 80, encoding: encoding)
        case "[C": return extended(code: 77, encoding: encoding)
        case "[D": return extended(code: 75, encoding: encoding)
        case "[H", "OH", "[1~", "[7~": return extended(code: 71, encoding: encoding)
        case "[F", "OF", "[4~", "[8~": return extended(code: 79, encoding: encoding)
        case "[2~": return extended(code: 82, encoding: encoding)
        case "[3~": return extended(code: 83, encoding: encoding)
        case "[5~": return extended(code: 73, encoding: encoding)
        case "[6~": return extended(code: 81, encoding: encoding)
        case "OP": return functionKey(1, ibmCode: 59, encoding: encoding)
        case "OQ": return functionKey(2, ibmCode: 60, encoding: encoding)
        case "OR": return functionKey(3, ibmCode: 61, encoding: encoding)
        case "OS": return functionKey(4, ibmCode: 62, encoding: encoding)
        case "[15~": return functionKey(5, ibmCode: 63, encoding: encoding)
        case "[17~": return functionKey(6, ibmCode: 64, encoding: encoding)
        case "[18~": return functionKey(7, ibmCode: 65, encoding: encoding)
        case "[19~": return functionKey(8, ibmCode: 66, encoding: encoding)
        case "[20~": return functionKey(9, ibmCode: 67, encoding: encoding)
        case "[21~": return functionKey(10, ibmCode: 68, encoding: encoding)
        case "[23~": return functionKey(11, ibmCode: 133, encoding: encoding)
        case "[24~": return functionKey(12, ibmCode: 134, encoding: encoding)
        default:
            if let number = functionKeyNumber(from: suffix), (13...22).contains(number) {
                return functionKey(number, ibmCode: 255, encoding: encoding)
            }
            return nil
        }
    }

    private static func modifiedCharacter(from suffix: String) -> String? {
        guard suffix.hasPrefix("[") else { return nil }
        let body = suffix.dropFirst()
        guard body.count >= 2 else { return nil }
        var index = body.startIndex
        var sawModifier = false
        while index < body.endIndex {
            let character = body[index]
            guard character == "!" || character == "$" || character == "#" else { break }
            sawModifier = true
            index = body.index(after: index)
        }
        guard sawModifier, index < body.endIndex else { return nil }
        let character = body[index]
        guard character.unicodeScalars.allSatisfy({ (32...126).contains(Int($0.value)) }) else { return nil }
        guard body.index(after: index) == body.endIndex else { return nil }
        return suffix
    }

    private static func modifiedNavigationCode(from suffix: String) -> Int? {
        guard suffix.hasPrefix("[") else { return nil }
        if suffix.hasPrefix("[1;"), let last = suffix.last {
            switch last {
            case "A": return 72
            case "B": return 80
            case "C": return 77
            case "D": return 75
            case "H": return 71
            case "F": return 79
            default: return nil
            }
        }

        guard suffix.hasSuffix("~") else { return nil }
        let body = suffix.dropFirst().dropLast()
        let base = body.split(separator: ";").first ?? ""
        switch base {
        case "2": return 82
        case "3": return 83
        case "5": return 73
        case "6": return 81
        default: return nil
        }
    }

    private static func modifiedFunctionKey(from suffix: String) -> (number: Int, ibmCode: Int)? {
        if suffix.hasPrefix("[1;"), let last = suffix.last {
            switch last {
            case "P": return (1, 59)
            case "Q": return (2, 60)
            case "R": return (3, 61)
            case "S": return (4, 62)
            default: break
            }
        }

        guard suffix.hasPrefix("["), suffix.hasSuffix("~") else { return nil }
        let body = suffix.dropFirst().dropLast()
        guard let base = Int(body.split(separator: ";").first ?? "") else { return nil }
        switch base {
        case 15: return (5, 63)
        case 17: return (6, 64)
        case 18: return (7, 65)
        case 19: return (8, 66)
        case 20: return (9, 67)
        case 21: return (10, 68)
        case 23: return (11, 133)
        case 24: return (12, 134)
        default:
            guard let number = functionKeyNumber(from: suffix), (13...22).contains(number) else { return nil }
            return (number, 255)
        }
    }

    private static func modifiers(from suffix: String) -> (shift: Bool, command: Bool, option: Bool) {
        guard let parameter = modifierParameter(from: suffix) else {
            return (false, false, false)
        }

        switch parameter {
        case 2: return (true, false, false)
        case 3: return (false, false, true)
        case 4: return (true, false, true)
        case 5: return (false, false, false)
        case 6: return (true, false, false)
        case 7: return (false, false, true)
        case 8: return (true, false, true)
        case 9: return (false, true, false)
        case 10: return (true, true, false)
        case 11: return (false, true, true)
        case 12: return (true, true, true)
        default: return (false, false, false)
        }
    }

    private static func modifierParameter(from suffix: String) -> Int? {
        guard let semicolon = suffix.lastIndex(of: ";") else { return nil }
        var digits = ""
        var index = suffix.index(after: semicolon)
        while index < suffix.endIndex {
            let character = suffix[index]
            guard character.isNumber else { break }
            digits.append(character)
            index = suffix.index(after: index)
        }
        return Int(digits)
    }

    private static func functionKeyNumber(from suffix: String) -> Int? {
        guard suffix.hasPrefix("["), suffix.hasSuffix("~") else { return nil }
        let body = suffix.dropFirst().dropLast()
        guard let value = Int(body.split(separator: ";").first ?? "") else { return nil }
        switch value {
        case 25: return 13
        case 26: return 14
        case 28: return 15
        case 29: return 16
        case 31: return 17
        case 32: return 18
        case 33: return 19
        case 34: return 20
        case 35: return 21
        case 36: return 22
        default: return nil
        }
    }

    private static func functionKey(_ number: Int, ibmCode: Int, shift: Bool = false, command: Bool = false, option: Bool = false, encoding: BASICKeyEncoding) -> String {
        switch encoding {
        case .aibasic:
            var modifiers = ""
            if shift { modifiers += "!" }
            if command { modifiers += "$" }
            if option { modifiers += "#" }
            return "[\(modifiers)F\(number)"
        case .ibm:
            return extended(code: ibmCode, encoding: encoding)
        }
    }

    private static func shiftTab(encoding: BASICKeyEncoding) -> String {
        switch encoding {
        case .aibasic:
            return "[!T"
        case .ibm:
            return extended(code: 255, encoding: encoding)
        }
    }

    private static func extended(code: Int, shift: Bool = false, command: Bool = false, option: Bool = false, encoding: BASICKeyEncoding) -> String {
        let scalar = String(UnicodeScalar(code) ?? UnicodeScalar(255)!)
        switch encoding {
        case .aibasic:
            var modifiers = ""
            if shift { modifiers += "!" }
            if command { modifiers += "$" }
            if option { modifiers += "#" }
            return "[\(modifiers)\(scalar)"
        case .ibm:
            return "\u{0}\(scalar)"
        }
    }
}

public extension BASICFileHost {
    /// Default implementation for hosts that do not support saving.
    func saveTextFile(path: String, text: String) throws {
        throw BASICError.runtime("SAVE is not supported by this host")
    }

    /// Default implementation for hosts that do not expose file existence.
    func fileExists(path: String) throws -> Bool {
        false
    }

    /// Default current directory implementation backed by Foundation.
    func currentDirectoryPath() throws -> String {
        FileManager.default.currentDirectoryPath
    }

    /// Default current directory mutation backed by Foundation.
    func changeDirectory(path: String) throws {
        guard FileManager.default.changeCurrentDirectoryPath(path) else {
            throw BASICError.runtime("Could not change directory to \(path)")
        }
    }

    /// Default implementation for hosts that do not support FILES.
    func listFiles() throws -> [String] {
        throw BASICError.runtime("FILES is not supported by this host")
    }

    /// Default implementation for hosts that do not support directory imports.
    func listFiles(path: String) throws -> [String] {
        throw BASICError.runtime("Directory IMPORT is not supported by this host")
    }
}

public extension BASICSystemHost {
    /// Default SYSTEM implementation using `/bin/sh -lc`.
    func runSystemCommand(_ command: String) throws -> String {
        try runSystemCommandResult(command, environment: .empty).output
    }

    /// Default SYSTEM result implementation using `/bin/sh -lc`.
    func runSystemCommandResult(_ command: String, environment: BASICEnvironmentPatch = .empty) throws -> BASICSystemCommandResult {
        let dimensions = self as? BASICConsoleHost
        let workingDirectoryPath = try (self as? BASICFileHost)?.currentDirectoryPath()
        let workingDirectory = workingDirectoryPath.map { URL(fileURLWithPath: $0, isDirectory: true) }
        return try BASICSystemCommand.runResult(
            command,
            workingDirectory: workingDirectory,
            columns: dimensions?.screenColumns(),
            rows: dimensions?.screenRows(),
            environment: environment
        )
    }
}

public struct BASICEnvironmentPatch: Equatable, Sendable {
    public static let empty = BASICEnvironmentPatch(values: [:], removals: [])

    public let values: [String: String]
    public let removals: Set<String>

    public init(values: [String: String], removals: Set<String>) {
        self.values = values
        self.removals = removals
    }

    public func applying(to environment: [String: String]) -> [String: String] {
        var updated = environment
        for name in removals {
            updated.removeValue(forKey: name)
        }
        for (name, value) in values {
            updated[name] = value
        }
        return updated
    }
}

public struct BASICSystemCommandResult: Equatable, Sendable {
    public let output: String
    public let exitCode: Int

    public init(output: String, exitCode: Int) {
        self.output = output
        self.exitCode = exitCode
    }
}

/// Structured argv-style process I/O mode.
public enum BASICProcessIOMode: Equatable, Sendable {
    /// Capture stdout and stderr into a `BASICProcessResult`.
    case captured
    /// Inherit the host process terminal streams for interactive foreground tools.
    case inheritedTerminal
}

/// Structured argv-style process request.
public struct BASICProcessRequest: Equatable, Sendable {
    public let executable: String
    public let arguments: [String]
    public let workingDirectory: String?
    public let columns: Int?
    public let rows: Int?
    public let environment: BASICEnvironmentPatch
    public let standardInput: String?
    public let timeoutSeconds: Double?
    public let ioMode: BASICProcessIOMode

    public init(
        executable: String,
        arguments: [String] = [],
        workingDirectory: String? = nil,
        columns: Int? = nil,
        rows: Int? = nil,
        environment: BASICEnvironmentPatch = .empty,
        standardInput: String? = nil,
        timeoutSeconds: Double? = nil,
        ioMode: BASICProcessIOMode = .captured
    ) {
        self.executable = executable
        self.arguments = arguments
        self.workingDirectory = workingDirectory
        self.columns = columns
        self.rows = rows
        self.environment = environment
        self.standardInput = standardInput
        self.timeoutSeconds = timeoutSeconds
        self.ioMode = ioMode
    }

    public func withStandardInput(_ input: String) -> BASICProcessRequest {
        BASICProcessRequest(
            executable: executable,
            arguments: arguments,
            workingDirectory: workingDirectory,
            columns: columns,
            rows: rows,
            environment: environment,
            standardInput: input,
            timeoutSeconds: timeoutSeconds,
            ioMode: ioMode
        )
    }

    public func withIOMode(_ mode: BASICProcessIOMode) -> BASICProcessRequest {
        BASICProcessRequest(
            executable: executable,
            arguments: arguments,
            workingDirectory: workingDirectory,
            columns: columns,
            rows: rows,
            environment: environment,
            standardInput: standardInput,
            timeoutSeconds: timeoutSeconds,
            ioMode: mode
        )
    }

    public func withTimeoutSeconds(_ seconds: Double?) -> BASICProcessRequest {
        BASICProcessRequest(
            executable: executable,
            arguments: arguments,
            workingDirectory: workingDirectory,
            columns: columns,
            rows: rows,
            environment: environment,
            standardInput: standardInput,
            timeoutSeconds: seconds,
            ioMode: ioMode
        )
    }
}

/// Structured process result with stdout and stderr kept separate.
public struct BASICProcessResult: Equatable, Sendable {
    public let stdout: String
    public let stderr: String
    public let exitCode: Int

    public init(stdout: String, stderr: String, exitCode: Int) {
        self.stdout = stdout
        self.stderr = stderr
        self.exitCode = exitCode
    }
}

/// Foreground process identity reported to interactive hosts that want to forward signals.
public struct BASICForegroundProcessSnapshot: Equatable, Sendable {
    public let processID: Int32
    public let processGroupID: Int32
    public let command: String

    public init(processID: Int32, processGroupID: Int32, command: String) {
        self.processID = processID
        self.processGroupID = processGroupID
        self.command = command
    }
}

/// Optional observer used by shell hosts to track the active foreground process group.
public protocol BASICForegroundProcessObserver: AnyObject {
    func foregroundProcessStarted(_ process: BASICForegroundProcessSnapshot)
    func foregroundProcessEnded(_ process: BASICForegroundProcessSnapshot)
}

private final class BASICProcessOutputBox: @unchecked Sendable {
    private let lock = NSLock()
    private var data = Data()

    func set(_ newData: Data) {
        lock.lock()
        data = newData
        lock.unlock()
    }

    func value() -> Data {
        lock.lock()
        defer { lock.unlock() }
        return data
    }
}

public extension BASICProcessHost {
    /// Default structured process implementation.
    func runProcess(_ request: BASICProcessRequest) throws -> BASICProcessResult {
        try BASICSystemCommand.runProcess(request)
    }

    /// Default structured pipeline implementation.
    func runPipeline(_ requests: [BASICProcessRequest]) throws -> BASICProcessResult {
        try BASICSystemCommand.runPipeline(requests)
    }
}

/// Helper for running shell commands for hosts that allow SYSTEM support.
public enum BASICSystemCommand {
    /// Runs a command through `/bin/sh -lc` and returns combined stdout/stderr text.
    public static func run(
        _ command: String,
        workingDirectory: URL? = nil,
        columns: Int? = nil,
        rows: Int? = nil
    ) throws -> String {
        try runResult(command, workingDirectory: workingDirectory, columns: columns, rows: rows).output
    }

    public static func runResult(
        _ command: String,
        workingDirectory: URL? = nil,
        columns: Int? = nil,
        rows: Int? = nil,
        environment: BASICEnvironmentPatch = .empty
    ) throws -> BASICSystemCommandResult {
        #if canImport(Darwin)
        if columns != nil || rows != nil {
            return try runWithPseudoTerminal(
                command,
                workingDirectory: workingDirectory,
                columns: columns,
                rows: rows,
                environment: environment
            )
        }
        #endif

        return try runWithPipe(
            command,
            workingDirectory: workingDirectory,
            columns: columns,
            rows: rows,
            environment: environment
        )
    }

    private static func runWithPipe(
        _ command: String,
        workingDirectory: URL?,
        columns: Int?,
        rows: Int?,
        environment: BASICEnvironmentPatch
    ) throws -> BASICSystemCommandResult {
        let process = Process()
        let pipe = Pipe()
        process.executableURL = URL(fileURLWithPath: "/bin/sh")
        process.arguments = ["-lc", command]
        process.currentDirectoryURL = workingDirectory
        process.environment = terminalEnvironment(columns: columns, rows: rows, patch: environment)
        process.standardOutput = pipe
        process.standardError = pipe

        do {
            try process.run()
        } catch {
            throw BASICError.runtime("Could not execute command: \(error.localizedDescription)")
        }

        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return BASICSystemCommandResult(output: String(decoding: data, as: UTF8.self), exitCode: Int(process.terminationStatus))
    }

    public static func runProcess(
        _ request: BASICProcessRequest,
        observer: BASICForegroundProcessObserver? = nil
    ) throws -> BASICProcessResult {
        if request.ioMode == .inheritedTerminal {
            return try runInheritedTerminalProcess(request, observer: observer)
        }
        let process = Process()
        let stdout = Pipe()
        let stderr = Pipe()
        let stdin = request.standardInput.map { _ in Pipe() }
        process.executableURL = executableURL(for: request.executable)
        process.arguments = executableArguments(for: request.executable, arguments: request.arguments)
        let workingDirectory = request.workingDirectory.map { URL(fileURLWithPath: $0, isDirectory: true) }
        if let workingDirectory {
            process.currentDirectoryURL = workingDirectory
        }
        process.environment = terminalEnvironment(
            columns: request.columns,
            rows: request.rows,
            patch: request.environment
        )
        process.standardOutput = stdout
        process.standardError = stderr
        if let stdin {
            process.standardInput = stdin.fileHandleForReading
        }

        do {
            try process.run()
        } catch {
            throw BASICError.runtime("Could not execute process: \(error.localizedDescription)")
        }
        let processGroupID = configureProcessGroup(for: process)
        let snapshot = BASICForegroundProcessSnapshot(
            processID: process.processIdentifier,
            processGroupID: processGroupID,
            command: processCommandDescription(request)
        )
        observer?.foregroundProcessStarted(snapshot)
        defer {
            observer?.foregroundProcessEnded(snapshot)
        }

        let stdoutData = BASICProcessOutputBox()
        let stderrData = BASICProcessOutputBox()
        let outputGroup = DispatchGroup()
        if let stdin, let input = request.standardInput {
            try? stdin.fileHandleForReading.close()
            writeStandardInput(input, to: stdin, group: outputGroup)
        }
        outputGroup.enter()
        DispatchQueue.global(qos: .utility).async {
            stdoutData.set(stdout.fileHandleForReading.readDataToEndOfFile())
            outputGroup.leave()
        }
        outputGroup.enter()
        DispatchQueue.global(qos: .utility).async {
            stderrData.set(stderr.fileHandleForReading.readDataToEndOfFile())
            outputGroup.leave()
        }
        let completed = waitForProcessExit(
            process,
            timeoutSeconds: request.timeoutSeconds,
            processGroupID: processGroupID
        )
        outputGroup.wait()
        let stderrText = String(decoding: stderrData.value(), as: UTF8.self)
        return BASICProcessResult(
            stdout: String(decoding: stdoutData.value(), as: UTF8.self),
            stderr: timedOutStderr(existing: stderrText, timeoutSeconds: request.timeoutSeconds, completed: completed),
            exitCode: completed ? Int(process.terminationStatus) : 124
        )
    }

    private static func runInheritedTerminalProcess(
        _ request: BASICProcessRequest,
        observer: BASICForegroundProcessObserver?
    ) throws -> BASICProcessResult {
        guard request.standardInput == nil else {
            throw BASICError.runtime("TTY process mode does not support BASIC string stdin")
        }
        let process = Process()
        process.executableURL = executableURL(for: request.executable)
        process.arguments = executableArguments(for: request.executable, arguments: request.arguments)
        if let workingDirectory = request.workingDirectory {
            process.currentDirectoryURL = URL(fileURLWithPath: workingDirectory, isDirectory: true)
        }
        process.environment = terminalEnvironment(
            columns: request.columns,
            rows: request.rows,
            patch: request.environment
        )
        process.standardInput = FileHandle.standardInput
        process.standardOutput = FileHandle.standardOutput
        process.standardError = FileHandle.standardError

        do {
            try process.run()
        } catch {
            throw BASICError.runtime("Could not execute process: \(error.localizedDescription)")
        }
        let processGroupID = configureProcessGroup(for: process)
        let snapshot = BASICForegroundProcessSnapshot(
            processID: process.processIdentifier,
            processGroupID: processGroupID,
            command: processCommandDescription(request)
        )
        observer?.foregroundProcessStarted(snapshot)
        defer {
            observer?.foregroundProcessEnded(snapshot)
        }

        let completed = waitForProcessExit(
            process,
            timeoutSeconds: request.timeoutSeconds,
            processGroupID: processGroupID
        )
        return BASICProcessResult(
            stdout: "",
            stderr: timedOutStderr(existing: "", timeoutSeconds: request.timeoutSeconds, completed: completed),
            exitCode: completed ? Int(process.terminationStatus) : 124
        )
    }

    public static func runPipeline(
        _ requests: [BASICProcessRequest],
        observer: BASICForegroundProcessObserver? = nil
    ) throws -> BASICProcessResult {
        guard !requests.isEmpty else {
            throw BASICError.runtime("PIPE expects at least one process")
        }
        guard requests.allSatisfy({ $0.ioMode == .captured }) else {
            throw BASICError.runtime("PIPE does not support TTY process mode")
        }
        if requests.count == 1 {
            return try runProcess(requests[0], observer: observer)
        }

        let processes = requests.map { request in
            let process = Process()
            process.executableURL = executableURL(for: request.executable)
            process.arguments = executableArguments(for: request.executable, arguments: request.arguments)
            if let workingDirectory = request.workingDirectory {
                process.currentDirectoryURL = URL(fileURLWithPath: workingDirectory, isDirectory: true)
            }
            process.environment = terminalEnvironment(
                columns: request.columns,
                rows: request.rows,
                patch: request.environment
            )
            return process
        }
        var intermediatePipes: [Pipe] = []
        let stdin = requests[0].standardInput.map { _ in Pipe() }
        if let stdin {
            processes[0].standardInput = stdin.fileHandleForReading
        }
        for index in 0..<(processes.count - 1) {
            let pipe = Pipe()
            processes[index].standardOutput = pipe.fileHandleForWriting
            processes[index + 1].standardInput = pipe.fileHandleForReading
            intermediatePipes.append(pipe)
        }

        let stdout = Pipe()
        let stderr = Pipe()
        processes[processes.count - 1].standardOutput = stdout.fileHandleForWriting
        processes.forEach { $0.standardError = stderr.fileHandleForWriting }

        var startedProcesses: [Process] = []
        do {
            for process in processes {
                try process.run()
                startedProcesses.append(process)
            }
        } catch {
            startedProcesses.forEach { $0.terminate() }
            throw BASICError.runtime("Could not execute pipeline: \(error.localizedDescription)")
        }
        let processGroupID = configureProcessGroup(for: processes)
        let snapshot = BASICForegroundProcessSnapshot(
            processID: processes[0].processIdentifier,
            processGroupID: processGroupID,
            command: requests.map(processCommandDescription).joined(separator: " | ")
        )
        observer?.foregroundProcessStarted(snapshot)
        defer {
            observer?.foregroundProcessEnded(snapshot)
        }

        intermediatePipes.forEach {
            try? $0.fileHandleForWriting.close()
            try? $0.fileHandleForReading.close()
        }
        try? stdout.fileHandleForWriting.close()
        try? stderr.fileHandleForWriting.close()

        let stdoutData = BASICProcessOutputBox()
        let stderrData = BASICProcessOutputBox()
        let outputGroup = DispatchGroup()
        if let stdin, let input = requests[0].standardInput {
            try? stdin.fileHandleForReading.close()
            writeStandardInput(input, to: stdin, group: outputGroup)
        }
        outputGroup.enter()
        DispatchQueue.global(qos: .utility).async {
            stdoutData.set(stdout.fileHandleForReading.readDataToEndOfFile())
            outputGroup.leave()
        }
        outputGroup.enter()
        DispatchQueue.global(qos: .utility).async {
            stderrData.set(stderr.fileHandleForReading.readDataToEndOfFile())
            outputGroup.leave()
        }

        processes.forEach { $0.waitUntilExit() }
        outputGroup.wait()
        return BASICProcessResult(
            stdout: String(decoding: stdoutData.value(), as: UTF8.self),
            stderr: String(decoding: stderrData.value(), as: UTF8.self),
            exitCode: Int(processes[processes.count - 1].terminationStatus)
        )
    }

    private static func writeStandardInput(_ input: String, to pipe: Pipe, group: DispatchGroup) {
        group.enter()
        DispatchQueue.global(qos: .utility).async {
            let data = Data(input.utf8)
            pipe.fileHandleForWriting.write(data)
            try? pipe.fileHandleForWriting.close()
            group.leave()
        }
    }

    private static func configureProcessGroup(for process: Process) -> Int32 {
        #if canImport(Darwin)
        let pid = process.processIdentifier
        if setpgid(pid, pid) == 0 {
            return pid
        }
        return pid
        #else
        return process.processIdentifier
        #endif
    }

    private static func configureProcessGroup(for processes: [Process]) -> Int32 {
        guard let leader = processes.first else { return 0 }
        let groupID = configureProcessGroup(for: leader)
        #if canImport(Darwin)
        for process in processes.dropFirst() {
            _ = setpgid(process.processIdentifier, groupID)
        }
        #endif
        return groupID
    }

    private static func processCommandDescription(_ request: BASICProcessRequest) -> String {
        ([request.executable] + request.arguments).joined(separator: " ")
    }

    private static func waitForProcessExit(
        _ process: Process,
        timeoutSeconds: Double?,
        processGroupID: Int32? = nil
    ) -> Bool {
        guard let timeoutSeconds else {
            process.waitUntilExit()
            return true
        }

        let semaphore = DispatchSemaphore(value: 0)
        process.terminationHandler = { _ in
            semaphore.signal()
        }
        if !process.isRunning {
            return true
        }
        let timeoutNanoseconds = UInt64((timeoutSeconds * 1_000_000_000).rounded(.up))
        if semaphore.wait(timeout: .now() + .nanoseconds(Int(timeoutNanoseconds))) == .success {
            return true
        }

        terminateProcess(process, processGroupID: processGroupID)
        if semaphore.wait(timeout: .now() + .milliseconds(500)) == .success {
            return false
        }

        #if canImport(Darwin)
        killProcess(process, signal: SIGKILL, processGroupID: processGroupID)
        _ = semaphore.wait(timeout: .now() + .seconds(2))
        #else
        _ = semaphore.wait(timeout: .now() + .milliseconds(500))
        #endif
        return false
    }

    private static func terminateProcess(_ process: Process, processGroupID: Int32?) {
        #if canImport(Darwin)
        killProcess(process, signal: SIGTERM, processGroupID: processGroupID)
        #else
        process.terminate()
        #endif
    }

    private static func killProcess(_ process: Process, signal: Int32, processGroupID: Int32?) {
        #if canImport(Darwin)
        if let processGroupID, processGroupID > 0, kill(-processGroupID, signal) == 0 {
            return
        }
        kill(process.processIdentifier, signal)
        #else
        process.terminate()
        #endif
    }

    private static func timedOutStderr(existing: String, timeoutSeconds: Double?, completed: Bool) -> String {
        guard !completed, let timeoutSeconds else { return existing }
        let message = "Process timed out after \(formatTimeoutSeconds(timeoutSeconds)) seconds\n"
        return existing + message
    }

    private static func formatTimeoutSeconds(_ seconds: Double) -> String {
        if seconds.rounded() == seconds {
            return String(Int(seconds))
        }
        var text = String(format: "%.3f", seconds)
        while text.last == "0" {
            text.removeLast()
        }
        return text
    }

    private static func executableURL(for executable: String) -> URL {
        if executable.contains("/") {
            return URL(fileURLWithPath: executable)
        }
        return URL(fileURLWithPath: "/usr/bin/env")
    }

    private static func executableArguments(for executable: String, arguments: [String]) -> [String] {
        if executable.contains("/") {
            return arguments
        }
        return [executable] + arguments
    }

    #if canImport(Darwin)
    private static func runWithPseudoTerminal(
        _ command: String,
        workingDirectory: URL?,
        columns: Int?,
        rows: Int?,
        environment: BASICEnvironmentPatch
    ) throws -> BASICSystemCommandResult {
        var master: Int32 = -1
        var slave: Int32 = -1
        var windowSize = winsize(
            ws_row: UInt16(max(1, rows ?? 25)),
            ws_col: UInt16(max(1, columns ?? 80)),
            ws_xpixel: 0,
            ws_ypixel: 0
        )
        guard openpty(&master, &slave, nil, nil, &windowSize) == 0 else {
            throw BASICError.runtime("Could not create terminal for command")
        }

        let process = Process()
        let masterHandle = FileHandle(fileDescriptor: master, closeOnDealloc: true)
        let outputHandle = FileHandle(fileDescriptor: slave, closeOnDealloc: true)
        let errorHandle = FileHandle(fileDescriptor: dup(slave), closeOnDealloc: true)
        let inputHandle = FileHandle(fileDescriptor: open("/dev/null", O_RDONLY), closeOnDealloc: true)

        process.executableURL = URL(fileURLWithPath: "/bin/sh")
        process.arguments = ["-lc", command]
        process.currentDirectoryURL = workingDirectory
        process.environment = terminalEnvironment(columns: columns, rows: rows, patch: environment)
        process.standardInput = inputHandle
        process.standardOutput = outputHandle
        process.standardError = errorHandle

        do {
            try process.run()
        } catch {
            outputHandle.closeFile()
            errorHandle.closeFile()
            inputHandle.closeFile()
            throw BASICError.runtime("Could not execute command: \(error.localizedDescription)")
        }

        outputHandle.closeFile()
        errorHandle.closeFile()
        inputHandle.closeFile()
        let data = masterHandle.readDataToEndOfFile()
        process.waitUntilExit()
        return BASICSystemCommandResult(output: String(decoding: data, as: UTF8.self), exitCode: Int(process.terminationStatus))
    }
    #endif

    private static func terminalEnvironment(columns: Int?, rows: Int?, patch: BASICEnvironmentPatch) -> [String: String] {
        var environment = ProcessInfo.processInfo.environment
        if let columns {
            environment["COLUMNS"] = String(max(1, columns))
        }
        if let rows {
            environment["LINES"] = String(max(1, rows))
        }
        return patch.applying(to: environment)
    }
}
