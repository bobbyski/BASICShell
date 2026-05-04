import BASICCore
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
    print("READY> ", terminator: "")
    guard let line = readLine() else { break }
    if !session.submit(line) { break }
}
