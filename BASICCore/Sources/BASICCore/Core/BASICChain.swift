//
//  BASICChain.swift
//  BASICCore
//
//  What survives when one program hands off to another.
//

import Foundation

/// The rules for `CHAIN`, `RUN file$` and `LOAD file$, R`, as one table.
///
/// ```text
///                      variables that survive        open files   starts at
///   CHAIN f$           those COMMON names            kept         start, else first line
///   CHAIN f$, , ALL    all of them                   kept         start, else first line
///   RUN f$             none                          closed       first line
///   RUN f$, R          none                          kept         first line
///   LOAD f$, R         none (it is RUN f$, R)        kept         first line
/// ```
///
/// Everything else starts fresh: `GOSUB` and `FOR` frames, the `ON ERROR`
/// trap, `DATA` (a fresh `RESTORE`), and timers and event handlers, which
/// belong to the program that is going away. These are GW-BASIC's rules (its
/// User's Guide, CHAIN and COMMON), with TRS-80 Model III Disk BASIC's
/// `RUN f$, R` (decision B5 in BBC_ADINS.md).
///
/// The file is found the way `IMPORT` finds one — relative to the program
/// doing the chaining — and GW's `.BAS` is assumed when the name has no
/// extension and nothing matches without one.
enum BASICChain {
    /// The names every `COMMON` in `lines` declares, normalized.
    ///
    /// `COMMON` is declarative: GW allows it anywhere, so a `CHAIN` reads all
    /// of them, not just those already executed.
    static func commonNames(in lines: [ParsedLine]) -> Set<String> {
        var names: Set<String> = []
        func collect(_ statement: Statement) {
            switch statement {
            case .common(let variables):
                names.formUnion(variables.map(\.normalized))
            case .sequence(let statements):
                statements.forEach(collect)
            case .labeled(_, let inner):
                collect(inner)
            default:
                break
            }
        }
        lines.forEach { collect($0.statement) }
        return names
    }

    /// The paths to try for `path`, in order: as resolved beside the chaining
    /// program, as written, and each with `.bas` when it has no extension.
    static func candidatePaths(for path: String, resolvedBesideProgram resolved: String) -> [String] {
        var candidates = [resolved]
        if resolved != path { candidates.append(path) }
        if (path as NSString).pathExtension.isEmpty {
            candidates += candidates.map { $0 + ".bas" }
        }
        return candidates
    }
}
