//
//  BASICShellEditor.swift
//  BASICShell
//
//  The full-screen editor the `EDIT` command opens.
//
//      ┌ File ──────────────────────────────────────────────┐
//      │  10 PRINT "hello"                                  │
//      │  20 FOR I = 1 TO 3                                 │
//      │  30 NEXT I                                         │
//      └ <program> · modified ────────── ^S save  ^X exit ──┘
//
//  ## In-process, not a subprocess
//
//  The TermKit editor this replaced could not run in the shell's own process:
//  `Application.run()` never returns, so the shell re-executed *itself* with a
//  hidden `--basic-shell-edit-buffer` flag, handed the child a temporary file,
//  moved the terminal's foreground process group over, waited on it, and read
//  the file back. Roughly 160 lines of posix_spawn, tcsetpgrp, waitpid, and a
//  hand-written escape-sequence blast to put the terminal back afterwards.
//
//  TUIKit's `App.run` returns, so none of that is needed: the program listing
//  goes in as a string and comes back as a string, in this process, and the
//  terminal is the driver's problem rather than ours.
//
//  ## The screen comes back
//
//  TUIKit's `ANSIDriver` switches to the terminal's **alternate screen** on the
//  way in and back on the way out — `ESC[?1049h` / `ESC[?1049l`, the same
//  mechanism `vi` uses. Whatever was on screen before `EDIT` is exactly where
//  it was afterwards: scrollback intact, prompt in place, nothing scrolled away.
//

import BASICCore
import Foundation
import TUIKit

#if canImport(Darwin)
import Darwin
#endif

// MARK: - Main-actor bridge

/// Runs main-actor work from a synchronous caller, without deadlocking.
///
/// ## The deadlock this exists to avoid
///
/// The REPL is synchronous and runs on the main thread. TUIKit's `App` is
/// `@MainActor` and `async`. The obvious bridge —
///
/// ```swift
///   Task { @MainActor in result = await present() }
///   semaphore.wait()          // ← hangs, every time
/// ```
///
/// — cannot work: the semaphore blocks the main thread, the main actor's
/// executor *is* the main thread, so the task it is waiting for can never be
/// scheduled.
///
/// It pumps the run loop instead. The main thread keeps servicing the main
/// queue — which is where the main actor's work is enqueued — so the task
/// actually runs, and the loop exits when it finishes.
///
/// The alternative is making the whole REPL `async`, which is a much larger
/// change than one modal editor justifies.
enum MainActorBridge {

    /// Result box, since the closure's return has to cross a `Task` boundary.
    private final class Box<Value>: @unchecked Sendable {
        var value: Value?
        var isFinished = false
    }

    /// Lends the terminal to a full-screen application and takes it back.
    ///
    /// TUIKit's driver sets `O_NONBLOCK` on standard input when it starts and
    /// does not clear it when it stops. The shell's line editor saves and
    /// restores `termios` around every read, but `termios` is not where that
    /// flag lives — the next `read` would return `EAGAIN` forever, which the
    /// line editor cannot tell from end of input, and the session would end
    /// the moment someone closed the editor.
    static func lendingTerminal<Value>(_ body: () -> Value) -> Value {
        let descriptor = STDIN_FILENO
        let saved = fcntl(descriptor, F_GETFL)
        defer {
            if saved >= 0 { _ = fcntl(descriptor, F_SETFL, saved) }
        }
        return body()
    }

    /// Runs `body` on the main actor and waits for it, pumping the run loop.
    static func runBlocking<Value>(
        _ body: @escaping @MainActor () async -> Value
    ) -> Value? {
        guard Thread.isMainThread else {
            // Off the main thread there is no run loop to pump and no reason to
            // block one; a semaphore is correct here.
            let box = Box<Value>()
            let semaphore = DispatchSemaphore(value: 0)
            Task { @MainActor in
                box.value = await body()
                semaphore.signal()
            }
            semaphore.wait()
            return box.value
        }

        let box = Box<Value>()
        Task { @MainActor in
            box.value = await body()
            box.isFinished = true
        }

        // A short interval rather than `.distantFuture`: the run loop returns
        // as soon as it has work, and this only decides how often it wakes with
        // none. Long enough not to spin, short enough that quitting the editor
        // feels immediate.
        while !box.isFinished {
            RunLoop.current.run(mode: .default, before: Date().addingTimeInterval(0.01))
        }
        return box.value
    }
}

// MARK: - Editor

/// The editor `EDIT` opens on the current program.
enum BASICProgramEditor {

    /// What the editor was left holding.
    ///
    /// The distinction matters and used to be missing. `EDIT` opens the
    /// program, but the File menu can open `~/.BASICrc` — and when it has, the
    /// buffer is a *file*, not the program. Returning a bare string made those
    /// indistinguishable, so leaving the editor after reading an rc file loaded
    /// the rc into the program, silently replacing it.
    struct Outcome {
        /// The text the user left behind.
        let text: String
        /// The file it belongs to, or `nil` when it is still the program.
        let path: String?
    }

    /// Edits `text` and returns what the user left in the buffer, or `nil` if
    /// the editor could not start.
    ///
    /// - Parameter commit: Loads a buffer into the session and returns the
    ///   first diagnostic, or `nil` when it parsed. Passed in rather than
    ///   reached for, so this file knows nothing about the session and a test
    ///   can supply its own.
    ///
    /// Synchronous, because the caller is a REPL command in mid-flight. The
    /// shell has never had two things running at once and this is not the place
    /// to start.
    @MainActor
    static func edit(
        text: String,
        label: String,
        commit: @escaping @MainActor (String) -> String?
    ) -> Outcome? {
        MainActorBridge.lendingTerminal {
            MainActorBridge.runBlocking {
                await present(text: text, label: label, commit: commit, on: ANSIDriver())
            } ?? nil
        }
    }

    /// Runs the editor on a given driver.
    ///
    /// The driver is a parameter so a test can supply TUIKit's `HeadlessDriver`
    /// and drive the menu with real keystrokes. Without it the only thing a
    /// test could check is that the file compiles, which is not the same as
    /// knowing that "Open" opens anything.
    @MainActor
    static func present(
        text original: String,
        label: String,
        commit: @escaping @MainActor (String) -> String?,
        on driver: any TerminalDriver
    ) async -> Outcome? {
        let app = App(driver: driver)
        app.applyTheme(.modernTurbo)
        // `^C` is the editor's *copy* key, and `SyntaxTextView` only consumes it
        // when there is a selection. Left at its default the app would quit on
        // a `^C` pressed with nothing selected — losing the program to a
        // mistimed keystroke.
        app.stopsOnControlC = false

        let window = Window()
        window.fillsScreen = true

        var accepted: Outcome?

        // What a save last agreed on, which is what "modified" is measured
        // against. A `let` baseline would mean a freshly opened program read as
        // modified from the moment it appeared.
        var baseline = original

        // The content window: `.contentWindow` is what makes it the *document*
        // surface rather than a dialog, which in Turbo is the difference
        // between the blue editing field and a gray panel.
        let document = Panel(label)
        document.themeContext = ThemeContext.contentWindow
        document.anchors = AnchorSet(leading: 0, trailing: 0, top: 1, bottom: 1)

        let text = SyntaxTextView(text: original, language: "basic")
        text.highlighter = BASICHighlighter()
        text.anchors = AnchorSet(leading: 0, trailing: 0, top: 0, bottom: 0)
        document.content.addSubview(text)

        // Scrollbars ride the border rather than the content — the Borland
        // trick, and the reason the editing area keeps every column it has.
        document.embedScrollbars(for: text)

        let status = StatusBar()
        // The wide segment, and what anything with something to say writes to.
        //
        // It was the other way round at first — legend on the left, messages in
        // a 20-column segment on the right — and a syntax error came out as
        // `Line 2, column 19: …`, the ellipsis eating the only part anyone
        // needed. The keys are eight characters and never change; a diagnostic
        // is as long as it is. The wide one belongs to the message.
        let message = Label(label)
        let keys = Label("^S save   ^X exit")
        status.addSegment(message, percentage: 100)
        status.addSegment(keys, minimumWidth: 18)
        status.anchors = AnchorSet(leading: 0, trailing: 0, bottom: 0, height: 1)

        var path: String?

        func refreshTitle() {
            let modified = text.text != baseline
            let title = (path.map { ($0 as NSString).lastPathComponent } ?? label)
                + (modified ? " · modified" : "")
            // Both places it appears: the window wears the name, the status line
            // repeats it because the window can be moved off it — and because a
            // message displaces it there, so it needs somewhere to come back to.
            document.title = title
            message.text = title
        }

        text.onChanged = { _ in refreshTitle() }

        /// Loads the buffer into the session program, reporting the first
        /// diagnostic in the status line rather than on a screen nobody can see.
        ///
        /// The shell's transcript is behind the alternate screen while the
        /// editor is up, so `host.printLine` would write somewhere invisible
        /// and be gone by the time the editor closed. A syntax error found by
        /// `^S` has to be readable *here*.
        @discardableResult
        func save() -> Bool {
            // Where `^S` goes depends on what is open, because the editor has
            // two kinds of buffer and one save key. Editing the program, it
            // commits to the program; editing `~/.BASICrc`, it writes the file.
            // A single fixed meaning would be wrong half the time — and wrong
            // in the direction of loading a config file into the user's
            // program.
            if let path {
                return write(to: path)
            }
            if let problem = commit(text.text) {
                message.text = problem
                return false
            }
            baseline = text.text
            refreshTitle()
            message.text = "saved to program"
            return true
        }

        /// Leaves. Unsaved changes come back with the buffer rather than being
        /// discarded — the shell is not a place where closing a window throws
        /// work away, and `RUN` should execute what was just typed.
        func quit() {
            accepted = Outcome(text: text.text, path: path)
            app.stop()
        }

        /// Puts a dialog on screen and takes it back off when it closes.
        func present(_ dialog: Dialog) {
            dialog.onDismiss = { [weak dialog, weak app] in
                if let dialog, let app { app.dismiss(dialog) }
            }
            // Twice, as TUIKit's own document controller does: once to size the
            // dialog before it is placed, once after, when the desktop has
            // given it a frame to be measured against.
            dialog.sizeToFit(in: app.desktop.bounds.size)
            app.present(dialog)
            dialog.sizeToFit(in: app.desktop.bounds.size)
        }

        /// Runs `proceed` straight away when nothing would be lost, and asks
        /// first when something would.
        ///
        /// Replacing what is on screen is the one action here that can destroy
        /// work — `^X` deliberately keeps an unsaved buffer, so there is no
        /// other way to lose it.
        func ifNothingWouldBeLost(_ proceed: @escaping () -> Void) {
            guard text.text != baseline else {
                proceed()
                return
            }
            let dialog = Dialog(
                title: "Save changes to \(label)?",
                message: "Your changes will be lost if you don't save them."
            )
            dialog.addButton("&Don't Save", isDestructive: true) { proceed() }
            dialog.addButton("&Cancel", isCancel: true)
            dialog.addButton("&Save", isDefault: true) {
                // Only proceeds when the save worked. Losing the buffer because
                // a program did not parse is the same data loss by a longer
                // road.
                if save() { proceed() }
            }
            present(dialog)
        }

        /// Shows a file in the editor.
        ///
        /// A file that is not there yet is not an error: it opens empty with the
        /// path set, so `File ▸ Save to File` creates it.
        func open(_ candidate: String) {
            let expanded = (candidate as NSString).expandingTildeInPath
            let contents: String
            if FileManager.default.fileExists(atPath: expanded) {
                guard let loaded = try? String(contentsOfFile: expanded, encoding: .utf8) else {
                    message.text = "cannot read \((expanded as NSString).lastPathComponent)"
                    return
                }
                contents = loaded
            } else {
                contents = ""
            }
            text.setText(contents)
            baseline = contents
            path = expanded
            refreshTitle()
            _ = window.makeFirstResponder(text)
        }

        /// Asks where to write, then writes there.
        ///
        /// Arriving with the current name filled in makes "save a copy next to
        /// it" one keystroke rather than retyping what is already known.
        func saveAs() {
            let dialog = FileDialog(mode: .save, root: startingDirectory)
            if let path {
                dialog.suggestedName = (path as NSString).lastPathComponent
            }
            dialog.onConfirm = { write(to: $0) }
            present(dialog)
        }

        /// Puts the program back in the buffer after a file has been open.
        ///
        /// Without this, opening `~/.BASICrc` is a one-way door: `^S` writes the
        /// file, `^X` leaves, and the only route back to the program is to open
        /// the editor again. The program text is the one this editor was handed,
        /// which is what `EDIT` showed on the way in.
        func returnToProgram() {
            text.setText(original)
            baseline = original
            path = nil
            refreshTitle()
            message.text = "editing the program"
            _ = window.makeFirstResponder(text)
        }

        /// Where a file dialog should start: beside the file being edited, or in
        /// the working directory when there is not one yet.
        var startingDirectory: String {
            if let path {
                return (path as NSString).deletingLastPathComponent
            }
            return FileManager.default.currentDirectoryPath
        }

        /// Writes the buffer to a file. Separate from `save`, which commits to
        /// the *program* — the two are different destinations and `EDIT` is
        /// about the program, so the file is the one that has to say so.
        @discardableResult
        func write(to destination: String) -> Bool {
            do {
                // The directory may not exist — `~/.BASICprofile` is offered by
                // name on machines that have never had one, and a save that
                // could not finish the job the open started would make that
                // menu entry pointless.
                let directory = (destination as NSString).deletingLastPathComponent
                if !directory.isEmpty {
                    try FileManager.default.createDirectory(
                        atPath: directory, withIntermediateDirectories: true
                    )
                }
                try text.text.write(toFile: destination, atomically: true, encoding: .utf8)
                path = destination
                baseline = text.text
                refreshTitle()
                message.text = "wrote \((destination as NSString).lastPathComponent)"
                return true
            } catch {
                message.text = "cannot write \((destination as NSString).lastPathComponent)"
                return false
            }
        }

        // Closing the document is closing the editor. A window whose close box
        // left an empty desktop behind would be a dead end reachable in one
        // keystroke. Assigned here rather than at construction because `quit`
        // closes over the text view, which does not exist that early.
        document.showsCloseButton = true
        document.onClose = { quit() }

        let fileMenu = Menu("&File")
        // `^S` and `^X` reach the menu because `Window.routeKey` offers hot keys
        // to every visible view *before* the focused one — so a focused text
        // view does not swallow them as ordinary characters.
        fileMenu.addItem(
            "&Save", keyEquivalent: KeyInput(key: .character("s"), modifiers: .control)
        ) {
            save()
        }
        fileMenu.addItem("Save &As…") { saveAs() }
        fileMenu.addSeparator()
        fileMenu.addItem("&Open File…") {
            ifNothingWouldBeLost {
                let dialog = FileDialog(mode: .open, root: startingDirectory)
                dialog.onConfirm = { open($0) }
                present(dialog)
            }
        }
        fileMenu.addItem("&Back to Program") {
            ifNothingWouldBeLost { returnToProgram() }
        }
        fileMenu.addSeparator()
        // The three files a shell user edits more than any other, and the three
        // hardest to reach through a browser: all of them are dot-files or live
        // under Application Support. They open by name, and they open even when
        // they do not exist yet — with the path already set, so `^S` creates
        // the file. Sending someone to a file browser to find a dot-file they
        // have never opened is a worse answer than a menu item.
        fileMenu.addItem("Open .BASIC&rc") {
            ifNothingWouldBeLost { open(ShellStartupFiles.interactive) }
        }
        fileMenu.addItem("Open .BASIC&profile") {
            ifNothingWouldBeLost { open(ShellStartupFiles.login) }
        }
        fileMenu.addItem("Open prompt se&ttings") {
            ifNothingWouldBeLost { open(BASICPromptTemplateStore.settingsURL.path) }
        }
        fileMenu.addSeparator()
        fileMenu.addItem(
            "E&xit editor", keyEquivalent: KeyInput(key: .character("x"), modifiers: .control)
        ) {
            quit()
        }

        let bar = MenuBar()
        bar.addMenu(fileMenu)
        bar.anchors = AnchorSet(leading: 0, trailing: 0, top: 0, height: 1)

        window.addSubview(bar)
        window.addSubview(status)
        refreshTitle()

        window.addSubview(document)
        _ = window.makeFirstResponder(text)

        do {
            try await app.run(window)
        } catch {
            // A driver that cannot start is not a reason to lose the buffer —
            // but there is nothing to hand back that the caller did not already
            // have, so say so with nil and let it keep the program it had.
            return nil
        }
        return accepted
    }
}
