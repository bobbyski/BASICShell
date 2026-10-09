//
//  WasmSpike.swift
//  BASICStudio
//
//  BASIC-43, a spike: can BASICStudio run WebAssembly in JavaScriptCore on
//  an iPad, and can the module call back into the app to open an ActiveUI
//  window? Debug builds only, reached by typing WASMSPIKE at the console or
//  launching with --wasm-spike. Throwaway: it answers the question in
//  Documents/WASM_SPIKE.md and is not shipped.
//
//  It tries two engines, as the ticket asks:
//
//    JSContext   Studio's own process. Imports are Swift blocks, so a call
//                into the app is synchronous and can return a value.
//    WKWebView   WebKit's content process, which has JIT. The app is reached
//                only by messages, and a reply comes back as a Promise.
//
//  and times one loop three ways on the same device: WebAssembly, plain
//  JavaScript, and BASIC through today's interpreter.
//

#if DEBUG
import BASICCore
import Foundation
import JavaScriptCore
import WebKit
#if canImport(UIKit)
import UIKit
#endif

/// A WebAssembly module, assembled here byte by byte so the iPad needs no
/// toolchain. In the text format it is:
///
/// ```text
/// (module
///   (import "host" "print"      (func (param i32 i32)))
///   (import "host" "openWindow" (func (param i32 i32)))
///   (import "host" "answer"     (func (result f64)))
///   (memory (export "memory") 1)
///   (data (i32.const 0)  "Hello from WebAssembly.")
///   (data (i32.const 32) "BASIC-43 spike")
///   (func (export "run") (result f64)            ;; print, open a window,
///     (call 0 (i32.const 0) (i32.const 23))        ;; then ask the app for a
///     (call 1 (i32.const 32) (i32.const 14))       ;; number and double it
///     (f64.mul (call 2) (f64.const 2)))
///   (func (export "sum") (param $n i32) (result f64)  ;; 1 + 2 + … + n
///     (local $i i32) (local $total f64)
///     (local.set $i (i32.const 1))
///     (block (loop
///       (br_if 1 (i32.gt_s (local.get $i) (local.get $n)))
///       (local.set $total (f64.add (local.get $total) (f64.convert_i32_s (local.get $i))))
///       (local.set $i (i32.add (local.get $i) (i32.const 1)))
///       (br 0)))
///     (local.get $total)))
/// ```
enum WasmSpikeModule {
    static let greeting = "Hello from WebAssembly."
    static let windowTitle = "BASIC-43 spike"

    static var bytes: [UInt8] {
        var types = Section(id: 1)
        types.vector([
            [0x60, 0x02, 0x7F, 0x7F, 0x00],     // 0: (i32, i32) -> ()
            [0x60, 0x00, 0x01, 0x7C],           // 1: () -> f64
            [0x60, 0x01, 0x7F, 0x01, 0x7C],     // 2: (i32) -> f64
        ])
        var imports = Section(id: 2)
        imports.vector([
            name("host") + name("print") + [0x00, 0x00],
            name("host") + name("openWindow") + [0x00, 0x00],
            name("host") + name("answer") + [0x00, 0x01],
        ])
        var functions = Section(id: 3)
        functions.vector([[0x01], [0x02]])          // run: type 1, sum: type 2
        var memory = Section(id: 5)
        memory.vector([[0x00, 0x01]])               // one page, no maximum
        var exports = Section(id: 7)
        exports.vector([
            name("memory") + [0x02, 0x00],
            name("run") + [0x00, 0x03],
            name("sum") + [0x00, 0x04],
        ])
        let run: [UInt8] = [0x00]                   // no locals
            + [0x41, 0x00, 0x41, UInt8(greeting.utf8.count), 0x10, 0x00]      // print(0, 23)
            + [0x41, 0x20, 0x41, UInt8(windowTitle.utf8.count), 0x10, 0x01]   // openWindow(32, 14)
            + [0x10, 0x02]                                                    // answer()
            + [0x44] + float64(2) + [0xA2]                                    // * 2.0
            + [0x0B]
        let sum: [UInt8] = [0x02, 0x01, 0x7F, 0x01, 0x7C]   // locals: i32 $i, f64 $total
            + [0x41, 0x01, 0x21, 0x01]                      // $i = 1
            + [0x02, 0x40, 0x03, 0x40]                      // block, loop
            + [0x20, 0x01, 0x20, 0x00, 0x4A, 0x0D, 0x01]    // br_if 1 ($i > $n)
            + [0x20, 0x02, 0x20, 0x01, 0xB7, 0xA0, 0x21, 0x02]  // $total += f64($i)
            + [0x20, 0x01, 0x41, 0x01, 0x6A, 0x21, 0x01]    // $i += 1
            + [0x0C, 0x00, 0x0B, 0x0B]                      // br 0, end loop, end block
            + [0x20, 0x02, 0x0B]                            // $total
        var code = Section(id: 10)
        code.vector([sized(run), sized(sum)])
        var data = Section(id: 11)
        data.vector([
            [0x00, 0x41, 0x00, 0x0B] + sized(Array(greeting.utf8)),
            [0x00, 0x41, 0x20, 0x0B] + sized(Array(windowTitle.utf8)),
        ])
        return header + types.bytes + imports.bytes + functions.bytes + memory.bytes
            + exports.bytes + code.bytes + data.bytes
    }

    /// Valid only where WebAssembly exception handling is: a tag, and a
    /// function that throws it. ON ERROR could be built on this instead of
    /// setjmp and longjmp.
    static var exceptionHandlingProbe: [UInt8] {
        var types = Section(id: 1)
        types.vector([[0x60, 0x00, 0x00]])
        var functions = Section(id: 3)
        functions.vector([[0x00]])
        var tags = Section(id: 13)
        tags.vector([[0x00, 0x00]])                 // an exception, of type 0
        var code = Section(id: 10)
        code.vector([sized([0x00, 0x08, 0x00, 0x0B])])  // throw 0
        return header + types.bytes + functions.bytes + tags.bytes + code.bytes
    }

    /// Valid only where WebAssembly garbage collection is: one struct type.
    /// Strings and arrays could live in GC objects instead of a hand-made
    /// heap in linear memory.
    static var garbageCollectionProbe: [UInt8] {
        var types = Section(id: 1)
        types.vector([[0x5F, 0x01, 0x7C, 0x01]])    // (struct (field (mut f64)))
        return header + types.bytes
    }

    private static let header: [UInt8] = [0x00, 0x61, 0x73, 0x6D, 0x01, 0x00, 0x00, 0x00]

    private struct Section {
        let id: UInt8
        var content: [UInt8] = []
        init(id: UInt8) { self.id = id }
        mutating func vector(_ items: [[UInt8]]) {
            content = leb128(UInt32(items.count)) + items.flatMap { $0 }
        }
        var bytes: [UInt8] { [id] + leb128(UInt32(content.count)) + content }
    }

    private static func name(_ text: String) -> [UInt8] { sized(Array(text.utf8)) }
    private static func sized(_ bytes: [UInt8]) -> [UInt8] { leb128(UInt32(bytes.count)) + bytes }
    private static func float64(_ value: Double) -> [UInt8] {
        withUnsafeBytes(of: value.bitPattern.littleEndian) { Array($0) }
    }
    fileprivate static func leb128(_ value: UInt32) -> [UInt8] {
        var value = value
        var out: [UInt8] = []
        repeat {
            var byte = UInt8(value & 0x7F)
            value >>= 7
            if value != 0 { byte |= 0x80 }
            out.append(byte)
        } while value != 0
        return out
    }

    /// A JavaScript array literal of the bytes.
    static func javaScriptArray(_ bytes: [UInt8]) -> String {
        "new Uint8Array([" + bytes.map(String.init).joined(separator: ",") + "])"
    }
}

/// The same loop in JavaScript and in BASIC, so the three can be compared.
enum WasmSpikeBenchmark {
    static let javaScript = "function __jsSum(n) { let total = 0; for (let i = 1; i <= n; i++) total += i; return total; }"
    static func basic(_ n: Int) -> String {
        "t = 0: for i = 1 to \(n): t = t + i: next i: print t"
    }
    /// 1 + 2 + … + n, for checking every engine's answer.
    static func expected(_ n: Int) -> Double { Double(n) * Double(n + 1) / 2 }
}

/// Runs the spike and reports each finding as one line.
@MainActor
final class WasmSpike {
    private let report: @Sendable (String) -> Void
    private let openWindow: @Sendable (String) -> Void
    private var webProbe: WebViewWasmProbe?
    /// The spike running now: it outlives the command that started it.
    static var running: WasmSpike?
    nonisolated static let loopCounts = [1_000_000, 10_000_000]
    nonisolated static let interpreterLoopCount = 1_000_000

    init(report: @escaping @Sendable (String) -> Void, openWindow: @escaping @Sendable (String) -> Void) {
        self.report = report
        self.openWindow = openWindow
    }

    func run(done: @escaping @MainActor () -> Void) {
        report("BASIC-43 WebAssembly spike")
        #if os(iOS)
        let device = UIDevice.current
        report("device: \(device.model) \(Self.machine()), \(device.systemName) \(device.systemVersion)")
        #else
        report("device: Mac \(Self.machine()), macOS \(ProcessInfo.processInfo.operatingSystemVersionString)")
        #endif
        #if targetEnvironment(simulator)
        report("note: the simulator's JavaScriptCore is the Mac's and has JIT; only a device answers the question")
        #endif
        report("module: \(WasmSpikeModule.bytes.count) bytes")

        let report = self.report
        let openWindow = self.openWindow
        DispatchQueue.global(qos: .userInitiated).async {
            JSContextWasmProbe(report: report, openWindow: openWindow).run()
            Self.interpreterBenchmark(report: report)
            DispatchQueue.main.async {
                let probe = WebViewWasmProbe(report: report) { [weak self] in
                    self?.webProbe = nil
                    report("spike: done")
                    done()
                }
                self.webProbe = probe
                probe.run()
            }
        }
    }

    /// BASIC, through a fresh session of today's interpreter, off the main
    /// thread.
    nonisolated static func interpreterBenchmark(report: @Sendable (String) -> Void) {
        let host = CapturingHost()
        let session = BASICSession(host: host, promptTemplate: "")
        let n = interpreterLoopCount
        let start = DispatchTime.now()
        _ = session.submit(WasmSpikeBenchmark.basic(n))
        let milliseconds = Self.milliseconds(since: start)
        let answer = host.output.trimmingCharacters(in: .whitespacesAndNewlines)
        report("interpreter: sum(\(n)) = \(answer) in \(Self.format(milliseconds)) ms")
    }

    nonisolated static func milliseconds(since start: DispatchTime) -> Double {
        Double(DispatchTime.now().uptimeNanoseconds - start.uptimeNanoseconds) / 1_000_000
    }

    nonisolated static func format(_ milliseconds: Double) -> String {
        String(format: "%.1f", milliseconds)
    }

    nonisolated static func machine() -> String {
        var info = utsname()
        uname(&info)
        return withUnsafeBytes(of: &info.machine) { String(decoding: $0.prefix { $0 != 0 }, as: UTF8.self) }
    }
}

/// A BASIC host that keeps what is printed.
private final class CapturingHost: BASICHost, @unchecked Sendable {
    private(set) var output = ""
    func print(_ text: String, terminator: String) { output += text + terminator }
    func printLine(_ text: String) { output += text + "\n" }
    func readLine(prompt: String) -> String? { nil }
}

/// WebAssembly in a JSContext in Studio's own process.
private struct JSContextWasmProbe {
    let report: @Sendable (String) -> Void
    let openWindow: @Sendable (String) -> Void

    func run() {
        guard let context = JSContext() else {
            report("JSContext: could not be made")
            return
        }
        var thrown: String?
        context.exceptionHandler = { _, value in thrown = value?.toString() }

        let typeOf = context.evaluateScript("typeof WebAssembly")?.toString() ?? "?"
        report("JSContext: typeof WebAssembly = \(typeOf)")
        report("JSContext: typeof WebAssembly.Suspending (JSPI) = \(context.evaluateScript("typeof WebAssembly === 'object' ? typeof WebAssembly.Suspending : 'n/a'")?.toString() ?? "?")")

        // The app's side of the imports: Swift, called synchronously.
        let report = self.report
        let openWindow = self.openWindow
        let printBlock: @convention(block) (String) -> Void = { text in
            report("JSContext: host.print from WebAssembly: \(text) [main thread: \(Thread.isMainThread)]")
        }
        let windowBlock: @convention(block) (String) -> Void = { title in
            report("JSContext: host.openWindow from WebAssembly: \(title) [main thread: \(Thread.isMainThread)]")
            DispatchQueue.main.async { openWindow(title) }
        }
        let answerBlock: @convention(block) () -> Double = { 21 }
        context.setObject(printBlock, forKeyedSubscript: "__swiftPrint" as NSString)
        context.setObject(windowBlock, forKeyedSubscript: "__swiftOpenWindow" as NSString)
        context.setObject(answerBlock, forKeyedSubscript: "__swiftAnswer" as NSString)
        context.evaluateScript(Self.glue)
        context.evaluateScript(WasmSpikeBenchmark.javaScript)

        guard typeOf == "object" else {
            report("JSContext: no WebAssembly here")
            timeJavaScript(in: context)
            return
        }
        for (label, bytes) in [("exception handling", WasmSpikeModule.exceptionHandlingProbe),
                               ("garbage collection", WasmSpikeModule.garbageCollectionProbe)] {
            let valid = context.evaluateScript("WebAssembly.validate(\(WasmSpikeModule.javaScriptArray(bytes)))")?.toBool() ?? false
            report("JSContext: \(label) module validates: \(valid)")
        }

        thrown = nil
        let start = DispatchTime.now()
        let instantiated = context.evaluateScript("__instantiate(\(WasmSpikeModule.javaScriptArray(WasmSpikeModule.bytes)))")?.toBool() ?? false
        let instantiateTime = WasmSpike.milliseconds(since: start)
        guard instantiated, thrown == nil else {
            report("JSContext: instantiate FAILED: \(thrown ?? "no error, but no instance")")
            timeJavaScript(in: context)
            return
        }
        report("JSContext: instantiated in \(WasmSpike.format(instantiateTime)) ms")

        let result = context.evaluateScript("__instance.exports.run()")?.toDouble() ?? .nan
        report("JSContext: run() returned \(result) (expected 42: the app's answer, 21, doubled in WebAssembly)")
        if let thrown { report("JSContext: run() threw: \(thrown)") }

        for n in WasmSpike.loopCounts {
            let start = DispatchTime.now()
            let total = context.evaluateScript("__instance.exports.sum(\(n))")?.toDouble() ?? .nan
            report("JSContext: WebAssembly sum(\(n)) = \(Int64(total)) in \(WasmSpike.format(WasmSpike.milliseconds(since: start))) ms"
                + (total == WasmSpikeBenchmark.expected(n) ? "" : " WRONG"))
        }
        timeJavaScript(in: context)
    }

    private func timeJavaScript(in context: JSContext) {
        for n in WasmSpike.loopCounts {
            let start = DispatchTime.now()
            let total = context.evaluateScript("__jsSum(\(n))")?.toDouble() ?? .nan
            report("JSContext: JavaScript sum(\(n)) = \(Int64(total)) in \(WasmSpike.format(WasmSpike.milliseconds(since: start))) ms")
        }
    }

    /// Reads a string out of the module's memory and hands it to Swift.
    /// JSContext has no TextDecoder, and the strings are ASCII.
    static let glue = """
    var __instance;
    function __text(pointer, length) {
        const bytes = new Uint8Array(__instance.exports.memory.buffer, pointer, length);
        let text = "";
        for (let i = 0; i < length; i++) text += String.fromCharCode(bytes[i]);
        return text;
    }
    function __instantiate(bytes) {
        const module = new WebAssembly.Module(bytes);
        __instance = new WebAssembly.Instance(module, { host: {
            print: (pointer, length) => __swiftPrint(__text(pointer, length)),
            openWindow: (pointer, length) => __swiftOpenWindow(__text(pointer, length)),
            answer: () => __swiftAnswer(),
        } });
        return true;
    }
    """
}

/// WebAssembly in a hidden WKWebView. The page reports by message; the app
/// can answer only asynchronously.
@MainActor
private final class WebViewWasmProbe: NSObject, WKScriptMessageHandler, WKScriptMessageHandlerWithReply {
    private let report: @Sendable (String) -> Void
    private let done: @MainActor () -> Void
    private var webView: WKWebView?
    private var finished = false

    init(report: @escaping @Sendable (String) -> Void, done: @escaping @MainActor () -> Void) {
        self.report = report
        self.done = done
    }

    func run() {
        let configuration = WKWebViewConfiguration()
        configuration.userContentController.add(self, name: "log")
        configuration.userContentController.addScriptMessageHandler(self, contentWorld: .page, name: "host")
        let webView = WKWebView(frame: CGRect(x: 0, y: 0, width: 4, height: 4), configuration: configuration)
        #if os(iOS)
        // On screen, if barely: a web view outside any window may be throttled.
        webView.alpha = 0.02
        UIApplication.shared.connectedScenes.compactMap { ($0 as? UIWindowScene)?.keyWindow }.first?.addSubview(webView)
        #endif
        self.webView = webView
        webView.loadHTMLString("<html><body><script>\(Self.page)</script></body></html>", baseURL: nil)
        DispatchQueue.main.asyncAfter(deadline: .now() + 60) { [weak self] in
            self?.finish("WKWebView: gave up after 60 s")
        }
    }

    private func finish(_ line: String? = nil) {
        guard !finished else { return }
        finished = true
        if let line { report(line) }
        webView?.configuration.userContentController.removeAllScriptMessageHandlers()
        webView?.removeFromSuperview()
        webView = nil
        done()
    }

    nonisolated func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
        let text = message.body as? String ?? "\(message.body)"
        MainActor.assumeIsolated {
            if text == "done" {
                finish()
            } else {
                report("WKWebView: " + text)
            }
        }
    }

    /// The asynchronous call into the app: a number back, as a Promise.
    nonisolated func userContentController(_ userContentController: WKUserContentController,
                                           didReceive message: WKScriptMessage,
                                           replyHandler: @escaping @MainActor @Sendable (Any?, String?) -> Void) {
        MainActor.assumeIsolated { replyHandler(21, nil) }
    }

    private static var page: String {
        let counts = WasmSpike.loopCounts.map(String.init).joined(separator: ",")
        return """
        const log = (text) => window.webkit.messageHandlers.log.postMessage(text);
        \(WasmSpikeBenchmark.javaScript)
        async function main() {
            log("typeof WebAssembly = " + typeof WebAssembly);
            log("typeof WebAssembly.Suspending (JSPI) = " + (typeof WebAssembly === "object" ? typeof WebAssembly.Suspending : "n/a"));
            log("crossOriginIsolated = " + self.crossOriginIsolated + ", typeof SharedArrayBuffer = " + typeof SharedArrayBuffer);
            const counts = [\(counts)];
            if (typeof WebAssembly === "object") {
                log("exception handling module validates: " + WebAssembly.validate(\(WasmSpikeModule.javaScriptArray(WasmSpikeModule.exceptionHandlingProbe))));
                log("garbage collection module validates: " + WebAssembly.validate(\(WasmSpikeModule.javaScriptArray(WasmSpikeModule.garbageCollectionProbe))));
                try {
                    let instance;
                    const text = (pointer, length) => new TextDecoder().decode(new Uint8Array(instance.exports.memory.buffer, pointer, length));
                    const start = performance.now();
                    const result = await WebAssembly.instantiate(\(WasmSpikeModule.javaScriptArray(WasmSpikeModule.bytes)), { host: {
                        print: (pointer, length) => log("host.print from WebAssembly: " + text(pointer, length)),
                        openWindow: (pointer, length) => log("host.openWindow from WebAssembly: " + text(pointer, length)),
                        // An import must answer at once, and the app can only answer later.
                        answer: () => 21,
                    } });
                    instance = result.instance;
                    log("instantiated in " + (performance.now() - start).toFixed(1) + " ms");
                    log("run() returned " + instance.exports.run() + " (the 21 came from JavaScript: the app cannot answer synchronously)");
                    for (const n of counts) {
                        const s = performance.now();
                        const total = instance.exports.sum(n);
                        log("WebAssembly sum(" + n + ") = " + total + " in " + (performance.now() - s).toFixed(1) + " ms");
                    }
                } catch (error) {
                    log("WebAssembly FAILED: " + error);
                }
            }
            for (const n of counts) {
                const s = performance.now();
                const total = __jsSum(n);
                log("JavaScript sum(" + n + ") = " + total + " in " + (performance.now() - s).toFixed(1) + " ms");
            }
            const calls = 200;
            const s = performance.now();
            let answer = 0;
            for (let i = 0; i < calls; i++) answer = await window.webkit.messageHandlers.host.postMessage(i);
            log("asynchronous call into the app and back: " + ((performance.now() - s) / calls).toFixed(3) + " ms each (answer " + answer + ")");
            log("done");
        }
        main().catch((error) => { log("page FAILED: " + error); log("done"); });
        """
    }
}

extension StudioModel {
    /// Runs the spike, printing each finding to the console and to stdout
    /// (`WASMSPIKE: …`, which `devicectl device process launch --console`
    /// shows).
    func runWasmSpike() {
        guard WasmSpike.running == nil else { return }
        selectedPane = .console
        let bridge = auiBridge
        let spike = WasmSpike(report: { [weak self] line in
            Swift.print("WASMSPIKE: \(line)")
            DispatchQueue.main.async { self?.appendJITOutput(line + "\n") }
        }, openWindow: { title in
            DispatchQueue.main.async {
                // The window a BASIC program would make, through the same bridge.
                let window = 9_043_001, label = 9_043_002
                _ = try? bridge.perform(.create(id: window, kind: .window, arguments: [title]))
                _ = try? bridge.perform(.create(id: label, kind: .label,
                                                arguments: ["Opened by a WebAssembly module running in JavaScriptCore."]))
                _ = try? bridge.perform(.add(parent: window, child: label))
                _ = try? bridge.perform(.show(id: window))
            }
        })
        WasmSpike.running = spike
        spike.run { [weak self] in
            WasmSpike.running = nil
            guard let self else { return }
            self.appendJITOutput(self.prompt)
            // On an iPad the window is a scene of its own, in front of the
            // console: close it after a moment so the findings can be seen.
            DispatchQueue.main.asyncAfter(deadline: .now() + 8) {
                _ = try? bridge.perform(.close(id: 9_043_001))
            }
        }
    }
}
#endif
