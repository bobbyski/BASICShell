import Foundation
#if canImport(Darwin)
import Darwin
#endif

public struct ProgramLine {
    public let number: Int?
    public var source: String
    public var fileName: String?
    public var sourceLineNumber: Int?
    public var isImported: Bool

    /// Creates a value from its parts.
    public init(number: Int?, source: String, fileName: String?, sourceLineNumber: Int?, isImported: Bool) {
        self.number = number
        self.source = source
        self.fileName = fileName
        self.sourceLineNumber = sourceLineNumber
        self.isImported = isImported
    }
}
