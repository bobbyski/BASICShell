import BASICCore
import Foundation

final class ConsoleHost: BASICFileHost {
    func printLine(_ text: String) {
        print(text)
    }

    func readLine(prompt: String) -> String? {
        Swift.print(prompt, terminator: "")
        return Swift.readLine()
    }

    func loadTextFile(path: String) throws -> String {
        let expandedPath: String
        if path == "~" || path.hasPrefix("~/") {
            expandedPath = FileManager.default.homeDirectoryForCurrentUser.path + String(path.dropFirst())
        } else {
            expandedPath = path
        }
        return try String(contentsOfFile: expandedPath, encoding: .utf8)
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
