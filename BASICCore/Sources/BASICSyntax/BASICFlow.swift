import Foundation

// Where control goes after a statement. Part of the syntax module because
// `BranchTarget` (an AST node) answers with one.

public enum Flow: Equatable {
    case next
    case jump(Int)
    case goto(Int)
    case gotoLabel(String)
    case returnTo(Int)
    case exitSelect
    case functionReturn
    case end
}
