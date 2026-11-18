//
//  NativeAUIAutomation.swift
//  BASICRTActiveUI
//
//  A scripted user, for a compiled ActiveUI program that no one watches.
//

import ActiveUI
import Foundation

/// What a compiled ActiveUI program does when it is run by a script rather
/// than a person: a smoke test, a CI job, an IDE checking that a starter
/// opens. Read from the environment once, at start; with none of it set the
/// program behaves exactly as it does for a person.
///
/// | Variable | Effect |
/// |---|---|
/// | `BASIC_AUI_TRACE=1` | Each window opening and closing, each label's new text and each dialog, on stderr |
/// | `BASIC_AUI_CLICK=Add,Done` | Once the first window is up, presses the buttons with those titles, in order |
/// | `BASIC_AUI_SELECT=1` | Then picks that row of the first list or table, as the user would |
/// | `BASIC_AUI_DIALOG=0` | Answers every dialog with that button at once, instead of showing it |
/// | `BASIC_AUI_CLOSE_AFTER=2` | Then, that many seconds after the first window opened, closes every window as its close box would |
/// | `BASIC_AUI_QUIT_AFTER=2` | Or quits, as File ▸ Quit and ⌘Q do, that many seconds after the first window opened |
///
/// With `AUI_BACKGROUND=1` too (ActiveUI's own), the windows appear without
/// taking the keyboard, so a run of them leaves the machine usable.
///
/// ```text
///   first window up ─► press each button ─► pick the row ─► wait ─► close all
///                      (0.2 s apart)                                  │
///                                          the program's run() returns ┘
/// ```
struct NativeAUIAutomation: Sendable {
    /// Whether to describe what the program's windows do, on stderr.
    var traces = false
    /// Buttons to press, by title, in order.
    var clicks: [String] = []
    /// The row of the first list or table to pick, if any.
    var selectRow: Int?
    /// The button every dialog is answered with, if dialogs are not shown.
    var dialogAnswer: Int?
    /// Seconds after the first window opens to close every window, if any.
    var closeAfter: Double?
    /// Seconds after the first window opens to quit, if any.
    var quitAfter: Double?

    /// No script: a person runs the program.
    init() {}

    /// The script the environment asks for.
    init(environment: [String: String]) {
        traces = environment["BASIC_AUI_TRACE"].map { $0 != "0" && !$0.isEmpty } ?? false
        clicks = environment["BASIC_AUI_CLICK"].map {
            $0.split(separator: ",").map { String($0).trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
        } ?? []
        selectRow = environment["BASIC_AUI_SELECT"].flatMap { Int($0) }
        dialogAnswer = environment["BASIC_AUI_DIALOG"].flatMap { Int($0) }.map { max(0, $0) }
        closeAfter = environment["BASIC_AUI_CLOSE_AFTER"].flatMap { Double($0) }.map { max(0, $0) }
        quitAfter = environment["BASIC_AUI_QUIT_AFTER"].flatMap { Double($0) }.map { max(0, $0) }
    }

    /// Writes `line` on stderr when tracing.
    func trace(_ line: String) {
        guard traces else { return }
        FileHandle.standardError.write(Data("aui: \(line)\n".utf8))
    }

    /// Plays the script against `bridge`, starting now: the first window has
    /// just opened. Each step is a moment apart, so the program's handlers
    /// run between them as they would between a person's clicks.
    @MainActor
    func start(on bridge: NativeAUIBridge) {
        var delay = 0.3
        for title in clicks {
            AUIApplication.after(delay) { [weak bridge] in
                guard let bridge else { return }
                let found = bridge.buttons(titled: title)
                if found.isEmpty { trace("no button \"\(title)\" to press") }
                for button in found {
                    trace("pressing \"\(title)\"")
                    button.onClick?()
                }
            }
            delay += 0.2
        }
        if let row = selectRow {
            AUIApplication.after(delay) { [weak bridge] in
                guard let list = bridge?.firstList() else {
                    trace("no list to pick row \(row) in")
                    return
                }
                trace("picking row \(row) of list \(list.id)")
                list.table.selectedRows = [row]
                list.table.onSelectionChange?([row])
            }
            delay += 0.2
        }
        if let closeAfter {
            AUIApplication.after(max(closeAfter, delay)) { [weak bridge] in
                trace("closing every window")
                bridge?.closeAllWindows()
            }
        }
        if let quitAfter {
            AUIApplication.after(max(quitAfter, delay)) {
                trace("quitting")
                AUIApplication.terminate()
            }
        }
    }
}
