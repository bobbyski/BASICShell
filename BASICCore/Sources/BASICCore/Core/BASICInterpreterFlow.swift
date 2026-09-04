import Foundation

// Interpreter execution state that used to share a file with the AST. These
// are how the interpreter *walks* statements, not part of their syntax.

struct ForFrame {
    let variable: VariableName
    let endValue: Double
    let stepValue: Double
    let loopStartIndex: Int
}

enum LoopEvent {
    case forLoop
    case nextLoop
}
