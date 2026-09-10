import Foundation

/// Where a `GOTO` is allowed to land.
///
/// BASIC has always let a program `GOTO` a label in another routine, and it
/// has always been a bad idea. What made it worth *forbidding* rather than
/// merely discouraging is that no two engines here agreed on what it did:
///
/// | | interpreter | both compilers |
/// |---|---|---|
/// | out of a `FUNCTION` | silently ends the function, returns the default | `Missing label` at run time |
/// | into a `FUNCTION` body | jumps in, then dies `RETURN value outside FUNCTION` | `Missing label` at run time |
///
/// Neither is defensible and the two disagree, so this is a divergence in the
/// language rather than a feature anyone relies on — 160 `.bas` files in this
/// tree contain no cross-scope `GOTO` at all.
///
/// The rule is deliberately narrow:
///
/// - a target that exists **in another routine** is an error, found before
///   anything runs;
/// - a target that exists **nowhere** is left alone. `GOTO 99999` in a line
///   never reached is legal BASIC, and the interpreter's rule — complain when
///   you get there — is the one this compiler already matches;
/// - `GOSUB` is untouched. Calling a main-body subroutine from inside a
///   function is a supported affordance, and the compiler outlines one;
/// - `ON ERROR GOTO` is untouched here, being a different question about a
///   handler's frame rather than about a jump.
///
/// One implementation, two callers: the interpreter checks in `prepare`, the
/// compiler in its front end, so they cannot drift.
public enum BranchScope {
    /// A `GOTO` whose target lives in another routine.
    public struct Violation {
        /// The offending line.
        public let line: ParsedLine
        /// The label or line number as written.
        public let target: String
        /// The routine the jump is in, for the message: nil is the main body.
        public let from: String?
        /// The routine the target lives in, nil for the main body.
        public let to: String?

        public var message: String {
            let here = from.map { "FUNCTION \($0)" } ?? "the main body"
            let there = to.map { "FUNCTION \($0)" } ?? "the main body"
            return "GOTO \(target) leaves \(here): \(target) is in \(there). "
                + "A GOTO may only reach a label in the same routine — "
                + "use GOSUB to run a main-body subroutine, or call a FUNCTION"
        }
    }

    /// One routine's labels and the jumps it makes.
    private struct Scope {
        var name: String?
        var labels: Set<String> = []
        var lineNumbers: Set<Int> = []
        var jumps: [(line: ParsedLine, target: String, key: String)] = []
    }

    /// Every cross-scope `GOTO` in a parsed program, in source order.
    public static func violations(in lines: [ParsedLine]) -> [Violation] {
        var scopes: [Scope] = [Scope(name: nil)]
        // Indices into `scopes`, innermost last. A nested routine is not a
        // thing BASIC has, but a class method is a routine inside a class
        // body, so the walk is a stack rather than a flag.
        var open: [Int] = [0]

        func note(_ statement: Statement, on line: ParsedLine, into scope: inout Scope) {
            switch statement {
            case .label(let name):
                scope.labels.insert(name.uppercased())
            case .labeled(let name, let inner):
                scope.labels.insert(name.uppercased())
                note(inner, on: line, into: &scope)
            case .sequence(let inner):
                for statement in inner { note(statement, on: line, into: &scope) }
            case .goto(let number):
                scope.jumps.append((line, "\(number)", "#\(number)"))
            case .gotoLabel(let name):
                scope.jumps.append((line, name, name.uppercased()))
            case .computedGoto(let targets, _):
                for target in targets { noteTarget(target, on: line, into: &scope) }
            case .ifThen(let _condition, let thenAction, let elseAction):
                _ = _condition
                noteAction(thenAction, on: line, into: &scope)
                if let elseAction { noteAction(elseAction, on: line, into: &scope) }
            // Everything else either cannot branch or is deliberately exempt:
            // GOSUB, computed GOSUB and ON ERROR GOTO are all allowed to name
            // a label outside the routine they appear in.
            default:
                break
            }
        }
        func noteTarget(_ target: BranchTarget, on line: ParsedLine, into scope: inout Scope) {
            switch target {
            case .line(let number): scope.jumps.append((line, "\(number)", "#\(number)"))
            case .label(let name): scope.jumps.append((line, name, name.uppercased()))
            }
        }
        func noteAction(_ action: ConditionalAction, on line: ParsedLine, into scope: inout Scope) {
            switch action {
            case .branch(let target): noteTarget(target, on: line, into: &scope)
            case .statement(let inner): note(inner, on: line, into: &scope)
            }
        }

        for line in lines {
            // A routine's header and footer belong to the body around it, so
            // the boundary is handled before anything is recorded.
            if let name = routineName(of: line.statement) {
                scopes.append(Scope(name: name))
                open.append(scopes.count - 1)
                continue
            }
            if endsRoutine(line.statement) {
                if open.count > 1 { open.removeLast() }
                continue
            }
            let index = open[open.count - 1]
            if let number = line.number { scopes[index].lineNumbers.insert(number) }
            note(line.statement, on: line, into: &scopes[index])
        }

        // A target counts as "somewhere else" only if some other scope has it.
        // A target nobody has stays a run-time failure, which is BASIC's rule.
        var out: [Violation] = []
        for (index, scope) in scopes.enumerated() {
            for jump in scope.jumps {
                let key = jump.key
                if scope.labels.contains(key) { continue }
                if key.hasPrefix("#"), let number = Int(key.dropFirst()), scope.lineNumbers.contains(number) { continue }
                guard let owner = scopes.indices.first(where: { other in
                    guard other != index else { return false }
                    if scopes[other].labels.contains(key) { return true }
                    if key.hasPrefix("#"), let number = Int(key.dropFirst()) {
                        return scopes[other].lineNumbers.contains(number)
                    }
                    return false
                }) else { continue }
                out.append(Violation(line: jump.line, target: jump.target,
                                     from: scope.name, to: scopes[owner].name))
            }
        }
        return out
    }

    /// The name of the routine this statement opens, if it opens one.
    private static func routineName(of statement: Statement) -> String? {
        switch statement {
        case .functionDeclaration(let name, _, _, _, _, _, _): return name.name
        case .labeled(_, let inner): return routineName(of: inner)
        default: return nil
        }
    }

    private static func endsRoutine(_ statement: Statement) -> Bool {
        switch statement {
        case .endFunction: return true
        case .labeled(_, let inner): return endsRoutine(inner)
        default: return false
        }
    }
}
