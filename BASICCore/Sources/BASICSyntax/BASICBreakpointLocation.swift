import Foundation

public struct BASICBreakpointLocation: Hashable, Sendable {
    /// Optional BASIC source file path.
    public var fileName: String?
    /// One-based source line number.
    public var lineNumber: Int
    /// Zero-based statement index within a colon-separated line.
    public var statementNumber: Int

    /// Creates a breakpoint location.
    public init(fileName: String? = nil, lineNumber: Int, statementNumber: Int = 0) {
        self.fileName = fileName
        self.lineNumber = lineNumber
        self.statementNumber = statementNumber
    }

    public func matches(_ currentLocation: BASICBreakpointLocation) -> Bool {
        let sameFile = fileName == nil
            || currentLocation.fileName == nil
            || fileName == currentLocation.fileName
        let sameLine = lineNumber == currentLocation.lineNumber
        let sameStatement = statementNumber == currentLocation.statementNumber
            || statementNumber == 0
        return sameFile && sameLine && sameStatement
    }
}
