import BASICCore
import Darwin
import Foundation

final class ConsoleHost: BASICFileHost {
    func print(_ text: String, terminator: String) {
        Swift.print(text, terminator: terminator)
    }

    func printLine(_ text: String) {
        Swift.print(text)
    }

    func readLine(prompt: String) -> String? {
        Swift.print(prompt, terminator: "")
        return Swift.readLine()
    }

    func loadTextFile(path: String) throws -> String {
        try String(contentsOfFile: expandedPath(path), encoding: .utf8)
    }

    func saveTextFile(path: String, text: String) throws {
        try text.write(toFile: expandedPath(path), atomically: true, encoding: .utf8)
    }

    func listFiles() throws -> [String] {
        try FileManager.default
            .contentsOfDirectory(atPath: FileManager.default.currentDirectoryPath)
            .filter { !$0.hasPrefix(".") }
            .sorted { $0.localizedStandardCompare($1) == .orderedAscending }
    }

    private func expandedPath(_ path: String) -> String {
        if path == "~" || path.hasPrefix("~/") {
            return FileManager.default.homeDirectoryForCurrentUser.path + String(path.dropFirst())
        }
        return path
    }
}

let host = ConsoleHost()
let session = BASICSession(host: host)

@MainActor
func runTermKitEditor() {
    let temporaryURL = FileManager.default.temporaryDirectory
        .appendingPathComponent("AIBasic-EDIT-\(UUID().uuidString).bas")

    do {
        try session.program.listing().write(to: temporaryURL, atomically: true, encoding: .utf8)
    } catch {
        host.printLine("Unable to prepare editor buffer: \(error.localizedDescription)")
        return
    }

    defer {
        try? FileManager.default.removeItem(at: temporaryURL)
    }

    let editorCandidates = SelfPackage.editorCandidateURLs(invokedExecutablePath: CommandLine.arguments[0])

    let command: String
    if let editorURL = editorCandidates.first(where: { FileManager.default.isExecutableFile(atPath: $0.path) }) {
        command = "\(shellQuoted(editorURL.path)) \(shellQuoted(temporaryURL.path))"
    } else if FileManager.default.fileExists(atPath: SelfPackage.rootURL.appendingPathComponent("Package.swift").path) {
        command = "cd \(shellQuoted(SelfPackage.rootURL.path)) && swift run BASICEdit \(shellQuoted(temporaryURL.path))"
    } else {
        host.printLine("Unable to find BASICEdit helper.")
        host.printLine("Searched:")
        for url in editorCandidates {
            host.printLine("  \(url.path)")
        }
        return
    }

    let result = runShellCommand(command)
    guard result == 0 else {
        host.printLine("Editor exited with status \(result).")
        return
    }

    do {
        session.program.loadSource(try String(contentsOf: temporaryURL, encoding: .utf8))
    } catch let error as BASICError {
        host.printLine(error.description)
    } catch {
        host.printLine("Unable to load edited program: \(error.localizedDescription)")
    }
}

func shellQuoted(_ value: String) -> String {
    "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'"
}

func runShellCommand(_ command: String) -> Int32 {
    var pid = pid_t()
    var arguments: [UnsafeMutablePointer<CChar>?] = [
        strdup("sh"),
        strdup("-lc"),
        strdup(command),
        nil
    ]
    defer {
        for argument in arguments where argument != nil {
            free(argument)
        }
    }

    let spawnStatus = posix_spawnp(&pid, "sh", nil, nil, &arguments, environ)
    guard spawnStatus == 0 else { return spawnStatus }

    var waitStatus: Int32 = 0
    guard waitpid(pid, &waitStatus, 0) >= 0 else { return errno }
    if waitStatus & 0x7f == 0 {
        return (waitStatus >> 8) & 0xff
    }
    return 128 + (waitStatus & 0x7f)
}

enum SelfPackage {
    static var rootURL: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
    }

    static func editorCandidateURLs(invokedExecutablePath: String) -> [URL] {
        let invokedDirectory = URL(fileURLWithPath: invokedExecutablePath).deletingLastPathComponent()
        return [
            invokedDirectory.appendingPathComponent("BASICEdit"),
            rootURL.appendingPathComponent(".build/debug/BASICEdit"),
            rootURL.appendingPathComponent(".build/arm64-apple-macosx/debug/BASICEdit"),
            rootURL.appendingPathComponent(".build/x86_64-apple-macosx/debug/BASICEdit")
        ]
    }
}

if let scriptPath = CommandLine.arguments.dropFirst().first {
    do {
        session.program.loadSource(try host.loadTextFile(path: scriptPath))
        try BASICInterpreter(program: session.program, host: host).run()
        exit(0)
    } catch let error as BASICError {
        host.printLine(error.description)
        exit(1)
    } catch {
        host.printLine("Error: \(error.localizedDescription)")
        exit(1)
    }
}

print("AIBasic Shell")
print("Type HELP for commands. Type QUIT to exit.")

while true {
    print(session.prompt, terminator: "")
    guard let line = readLine() else { break }
    if line.trimmingCharacters(in: .whitespacesAndNewlines).uppercased() == "EDIT" {
        runTermKitEditor()
        continue
    }
    if !session.submit(line) { break }
}
