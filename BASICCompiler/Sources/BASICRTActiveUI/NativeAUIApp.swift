//
//  NativeAUIApp.swift
//  BASICRTActiveUI
//
//  A compiled BASIC program that opens ActiveUI windows, as an application.
//

#if os(macOS)
import ActiveUI
import AppKit
import BASICCore
import BASICRTHost
import Foundation

/// A BASIC program's `main`, as the compiler emits it: the program's own
/// statements, start to END, answering the process's exit status.
public typealias BASICProgramEntry = @convention(c) (Int32, UnsafeMutablePointer<UnsafeMutablePointer<CChar>?>?) -> Int32

/// Where a compiled program that uses BASIC's AUI classes starts (BASIC-31).
///
/// The compiler names its statements `basic.program` and gives the process
/// a `main` that calls this, so the program never has the main thread:
/// ActiveUI's application does. Never returns; the process ends with the
/// program, or when the user quits.
@_cdecl("basic_rt_aui_main")
public func basic_rt_aui_main(
    _ argc: Int32,
    _ argv: UnsafeMutablePointer<UnsafeMutablePointer<CChar>?>?,
    _ program: BASICProgramEntry
) -> Int32 {
    let launch = ProgramLaunch(argc: argc, argv: argv, program: program)
    return MainActor.assumeIsolated {
        NativeAUIApp.run(launch)
    }
}

/// The program to start, and its arguments, handed to its thread.
struct ProgramLaunch: @unchecked Sendable {
    /// How many arguments.
    let argc: Int32
    /// The arguments, as the process got them.
    let argv: UnsafeMutablePointer<UnsafeMutablePointer<CChar>?>?
    /// The program's statements.
    let program: BASICProgramEntry
}

/// The application around a compiled program's windows.
///
/// ```text
///   main thread                               program thread
///   AUIApplication.run ── launched ──► start ─► basic.program(argc, argv)
///     menus: app (Quit ⌘Q), File, Edit,          AUIWindow(…), win.run() …
///     Window                                     ◄── each request, synced
///   ⌘Q / File ▸ Quit ─► close every window ──►   run() returns, END
///                                                 └─► exit(status) on main
/// ```
///
/// The program runs on a thread of its own, as BASICStudio's interpreter
/// runs one: its AUI requests hop to the main thread (``NativeAUIHost``),
/// and a window's `run` waits on the program's thread, running handlers as
/// the user works. The process lasts as long as the program does:
///
/// - **The program ends** (END, or its last statement): the process exits
///   with its status, and any window still up goes with it.
/// - **Its window closes** (the close box, File ▸ Close, `win.close()`): the
///   program hears CLOSE and its `run` returns, so a program that waits on
///   its window ends when the window does. Closing the last window does not
///   quit on its own; the program decides what comes after.
/// - **Quit** (⌘Q, the app menu, File ▸ Quit): every window closes as its
///   close box would, so the program finishes its own way. A program that
///   has not finished two seconds later, or had no window up, is quit then.
///
/// `AUI_BACKGROUND=1` keeps the windows from taking the keyboard, and
/// ``NativeAUIAutomation`` can work them; both are for runs nobody watches.
@MainActor
enum NativeAUIApp {
    /// The program's windows.
    private static var bridge: NativeAUIBridge?
    /// Whether the user has asked to quit once already.
    private static var quitRequested = false
    /// How long a Quit waits for the program to finish once its windows are
    /// closed.
    static let quitGracePeriod: TimeInterval = 2

    /// Starts the application, and the program once it has launched.
    static func run(_ launch: ProgramLaunch) -> Never {
        let automation = NativeAUIAutomation(environment: ProcessInfo.processInfo.environment)
        let bridge = NativeAUIBridge(automation: automation)
        Self.bridge = bridge
        RTHostHosted.installNativeWindows(NativeAUIHost(bridge: bridge))

        // The program's windows are the only windows: no main window, and no
        // quitting behind the program's back when the last one closes.
        AUIApplication.mainWindowIsVisible = false
        AUIApplication.terminatesAfterLastWindowClosed = false
        AUIApplication.shouldTerminate = { reply in quit(reply) }
        AUIApplication.onLaunch = { startProgram(launch) }
        let name = ProcessInfo.processInfo.processName
        return AUIApplication.run(AUIView(), placement: .fill, menuBar: menuBar(named: name), title: name)
    }

    /// The menu bar every Mac app has: the app menu (About, Hide, Quit),
    /// File with Close and Quit, Edit for the program's fields, and Window.
    static func menuBar(named name: String) -> AUIMenuBar {
        AUIMenuBar(menus: [
            AUIMenu.application(name: name),
            AUIMenu("File", items: [
                AUIMenuItem.command(.closeDocument),
                .separator(),
                AUIMenuItem("Quit", shortcut: AUIKeyboardShortcut("q")) {
                    MainActor.assumeIsolated { AUIApplication.terminate() }
                },
            ]),
            AUIMenu.standardEdit(),
            AUIMenu.standardWindow(),
        ])
    }

    /// Runs the program on a thread of its own, with the main thread's stack
    /// size and more: BASIC recursion that runs as a command-line program
    /// must run here too.
    private static func startProgram(_ launch: ProgramLaunch) {
        let thread = Thread {
            let status = launch.program(launch.argc, launch.argv)
            programEnded(status)
        }
        thread.name = "BASIC program"
        thread.stackSize = 64 << 20
        thread.start()
    }

    /// The program is done: the process ends with its status, on the main
    /// thread, between events. The program's thread waits for it there.
    nonisolated private static func programEnded(_ status: Int32) -> Never {
        fflush(stdout)
        fflush(stderr)
        DispatchQueue.main.async {
            exit(status)
        }
        while true { sleep(60) }
    }

    /// The user asked to quit: close the windows and let the program finish,
    /// or quit at once when there is nothing to close or this is the second
    /// time of asking.
    private static func quit(_ reply: @escaping @MainActor (Bool) -> Void) {
        guard !quitRequested, let bridge, bridge.hasOpenWindows else {
            fflush(stdout)
            reply(true)
            return
        }
        quitRequested = true
        bridge.closeAllWindows()
        reply(false)
        AUIApplication.after(quitGracePeriod) {
            AUIApplication.terminate()
        }
    }
}
#endif
