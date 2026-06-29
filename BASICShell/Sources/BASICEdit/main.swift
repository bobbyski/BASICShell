import Foundation
import TermKit

@MainActor
final class BasicEditorHost: View {
    private let sessionPath: String
    private var currentFilePath: String?
    private let window: Window
    private let textView: TextView

    init(sessionPath: String) {
        self.sessionPath = sessionPath
        self.window = Window("BASICShell EDIT", internalPadding: 0)
        self.textView = TextView()
        super.init()

        fill()

        let menu = MenuBar(menus: [
            MenuBarItem(title: "_File", children: [
                MenuItem(title: "_Load", help: "Ctrl-O", action: { [weak self] in self?.loadFile() }, shortcut: .controlO),
                MenuItem(title: "_Save", help: "Ctrl-S", action: { [weak self] in self?.saveFile() }, shortcut: .controlS),
                nil,
                MenuItem(title: "_Close", help: "Ctrl-Q", action: { [weak self] in self?.closeEditor() }, shortcut: .controlQ)
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
            textView.text = try String(contentsOfFile: sessionPath, encoding: .utf8)
        } catch {
            textView.text = ""
            MessageBox.error("Load Error", message: error.localizedDescription, buttons: ["Ok"])
        }

        _ = textView.becomeFirstResponder()
    }

    private func loadFile() {
        let dialog = OpenDialog(title: "Load", message: "Choose a BASIC source file")
        dialog.allowsMultipleSelection = false
        dialog.canChooseDirectories = false
        dialog.canChooseFiles = true
        dialog.present { [weak self] dialog in
            guard let self, let filePath = dialog.filePaths?.first else { return }
            do {
                self.textView.text = try String(contentsOfFile: filePath, encoding: .utf8)
                self.currentFilePath = filePath
                self.window.title = URL(fileURLWithPath: filePath).lastPathComponent
            } catch {
                MessageBox.error("Load Error", message: error.localizedDescription, buttons: ["Ok"])
            }
        }
    }

    private func saveFile() {
        if let currentFilePath {
            save(to: currentFilePath)
            return
        }

        let dialog = SaveDialog(title: "Save", message: "Choose where to save this program")
        dialog.present { [weak self] dialog in
            guard let self, let filePath = dialog.fileName else { return }
            self.currentFilePath = filePath
            self.window.title = URL(fileURLWithPath: filePath).lastPathComponent
            self.save(to: filePath)
        }
    }

    private func save(to filePath: String) {
        do {
            try (textView.text ?? "").write(toFile: filePath, atomically: true, encoding: .utf8)
            try (textView.text ?? "").write(toFile: sessionPath, atomically: true, encoding: .utf8)
            textView.isDirty = false
        } catch {
            MessageBox.error("Save Error", message: error.localizedDescription, buttons: ["Ok"])
        }
    }

    private func closeEditor() {
        do {
            try (textView.text ?? "").write(toFile: sessionPath, atomically: true, encoding: .utf8)
        } catch {
            MessageBox.error("Close Error", message: error.localizedDescription, buttons: ["Ok"])
            return
        }
        Application.shutdown()
    }
}

guard let sessionPath = CommandLine.arguments.dropFirst().first else {
    fputs("usage: BASICEdit <session-file>\n", stderr)
    exit(64)
}

Application.prepare()
Application.top.addSubview(BasicEditorHost(sessionPath: sessionPath))
Application.run()
