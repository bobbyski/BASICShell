import Foundation
@preconcurrency import TermKit

let integratedEditorFlag = "--basic-shell-edit-buffer"

@MainActor
func runBASICShellIntegratedEditorIfRequested(arguments: [String]) -> Bool {
    guard arguments.count >= 3, arguments[1] == integratedEditorFlag else {
        return false
    }
    runBASICShellIntegratedEditor(bufferPath: arguments[2])
}

@MainActor
private final class BASICShellEditorHost: View {
    private let bufferPath: String
    private let window: Window
    private let textView: BASICShellEditorTextView

    init(bufferPath: String) {
        self.bufferPath = bufferPath
        self.window = Window("BASICShell EDIT", internalPadding: 0)
        self.textView = BASICShellEditorTextView()
        super.init()
        textView.saveRequested = { [weak self] in _ = self?.saveBuffer() }
        textView.closeRequested = { [weak self] in self?.closeEditor() }

        fill()

        let menu = MenuBar(menus: [
            MenuBarItem(title: "_File", children: [
                MenuItem(title: "_Save to Program", help: "Ctrl-S", action: { [weak self] in _ = self?.saveBuffer() }, shortcut: .controlS),
                nil,
                MenuItem(title: "_Close and Save", help: "Ctrl-Q", action: { [weak self] in self?.closeEditor() }, shortcut: .controlQ)
            ])
        ])
        addSubview(menu)

        window.fill()
        window.y = Pos.at(1)
        window.height = Dim.fill()
        window.closeClicked = { [weak self] _ in
            self?.closeEditor()
        }
        addSubview(window)

        textView.fill()
        window.addSubview(textView)

        do {
            textView.text = try String(contentsOfFile: bufferPath, encoding: .utf8)
        } catch {
            textView.text = ""
            MessageBox.error("Load Error", message: error.localizedDescription, buttons: ["Ok"])
        }

        _ = textView.becomeFirstResponder()
    }

    fileprivate func saveBuffer() -> Bool {
        do {
            try Data(textView.byteBuffer).write(to: URL(fileURLWithPath: bufferPath), options: .atomic)
            textView.isDirty = false
            window.title = "BASICShell EDIT - saved"
            return true
        } catch {
            MessageBox.error("Save Error", message: error.localizedDescription, buttons: ["Ok"])
            return false
        }
    }

    fileprivate func closeEditor() {
        if saveBuffer() {
            Application.shutdown()
        }
    }
}

@MainActor
private final class BASICShellEditorTextView: TextView {
    nonisolated(unsafe) var saveRequested: (() -> Void)?
    nonisolated(unsafe) var closeRequested: (() -> Void)?

    override func processKey(event: KeyEvent) -> Bool {
        switch event.key {
        case .controlS:
            saveRequested?()
            return true
        case .controlQ, .esc:
            closeRequested?()
            return true
        default:
            return super.processKey(event: event)
        }
    }
}

@MainActor
private func runBASICShellIntegratedEditor(bufferPath: String) -> Never {
    Application.prepare(driverType: .unix)
    Application.top.addSubview(BASICShellEditorHost(bufferPath: bufferPath))
    Application.run()
    fatalError("TermKit Application.run unexpectedly returned")
}
