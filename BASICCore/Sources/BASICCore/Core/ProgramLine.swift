import Foundation
#if canImport(Darwin)
import Darwin
#endif

struct ProgramLine {
    let number: Int?
    var source: String
    var fileName: String?
    var sourceLineNumber: Int?
    var isImported: Bool
}
