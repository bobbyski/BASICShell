//
//  BASICDataCompiledBridge.swift
//  BASICCore
//
//  The database, reached from a compiled program.
//

import Foundation

/// The database pseudo classes as a compiled program sees them.
///
/// The same arrangement as ``BASICCompiledRich`` beside it, and for the same
/// reason: D12 says a language surface lands in every engine or in none, and
/// a second copy of the providers, the predicate lowering and the ORM in the
/// compiler's runtime would drift from this one the first time either changed.
/// So the compiled runtime owns no database knowledge at all. It owns a
/// handle and an ABI; everything it means is here.
///
/// One `BASICDataRuntime` for the life of the process, for the reason the
/// Rich bridge holds one `BASICRuntime`: a connection, an open transaction
/// and a cursor's current row are state, and a fresh runtime per call would
/// hand back a handle whose database was closed before the next statement.
public enum BASICCompiledData {

    /// A value crossing between the two runtimes.
    ///
    /// `object` is the one case the Rich bridge has no need of: the ORM takes
    /// an object and gives one back, so the shape has to survive the trip.
    /// Fields are keyed by their normalized (uppercased) names, as
    /// ``BASICValue/object(_:_:)`` keys them.
    public indirect enum Value: Sendable, Equatable {
        case number(Double)
        case string(String)
        case boolean(Bool)
        /// A handle to a database object, with what it is.
        case handle(id: Int, kind: String)
        /// A CLASS instance: the class name as declared, and its fields.
        case object(typeName: String, fields: [String: Value])
        case empty
    }

    /// What went wrong, as the interpreter would have said it.
    public struct Failure: Error {
        public let message: String
        public init(message: String) { self.message = message }
    }

    /// The one runtime the handles live on, reached under a lock: a compiled
    /// program is single-threaded through here, and the lock says so rather
    /// than leaving it to be assumed.
    private static let runtime = BASICDataRuntime()
    nonisolated(unsafe) private static var schema = BASICDataCompiledSchema()
    /// How a registered migration reaches the program (D7).
    ///
    /// Set by the host half, which owns the trampoline table the compiler
    /// registered its functions in. `BASICCore` cannot reach it — a compiled
    /// function is machine code — so the route is handed in, exactly as the
    /// interpreter hands in its own.
    nonisolated(unsafe) private static var invokeHandler: ((String) throws -> Void)?
    private static let lock = NSLock()

    /// Sets how a migration reaches the program.
    public static func setMigrationInvoker(_ invoke: @escaping (String) throws -> Void) {
        lock.lock()
        defer { lock.unlock() }
        invokeHandler = invoke
    }

    // MARK: - The schema a compiled program declares

    /// Registers what the compiler knows about the program's classes and
    /// enums, so the ORM can map them.
    ///
    /// A compiled program has no `BASICSession` to ask: its classes were
    /// lowered to slot lists long before it ran. The compiler therefore emits
    /// the declaration facts the mapper needs — names as written, visibility,
    /// `JSON` and `DATABASE` options, `meta`, and each ENUM's cases — and this
    /// reconstitutes them into the very definitions the interpreter's mapper
    /// reads. One mapper, two front ends.
    ///
    /// The argument is the JSON `Scripts/`-free format documented in
    /// ``BASICDataCompiledSchema``.
    public static func registerSchema(_ json: String) throws {
        let parsed: BASICDataCompiledSchema
        do {
            parsed = try BASICDataCompiledSchema(json: json)
        } catch let error as BASICDataError {
            throw Failure(message: error.description)
        }
        lock.lock()
        defer { lock.unlock() }
        schema.merge(parsed)
    }

    // MARK: - Construction and dispatch

    /// `SqlDatabase(url$)`, `DocumentDatabase(url$)`, `DataStore(database)`.
    public static func make(typeName: String, arguments: [Value]) throws -> Value {
        lock.lock()
        defer { lock.unlock() }
        return try translating {
            switch typeName.uppercased() {
            case "SQLDATABASE":
                return bridgeValue(try runtime.makeSQLDatabase(url: try text(arguments, "SqlDatabase")))
            case "DOCUMENTDATABASE":
                return bridgeValue(try runtime.makeDocumentDatabase(url: try text(arguments, "DocumentDatabase")))
            case "DATASTORE":
                guard arguments.count == 1 else {
                    throw BASICError.runtime("DataStore wants a database")
                }
                let invoke = invokeHandler
                let store = try runtime.makeDataStore(
                    from: basicValue(arguments[0]),
                    enumeration: { schema.enumeration(named: $0) },
                    invokeMigration: invoke.map { call in { name in try call(name) } }
                )
                return bridgeValue(store)
            case "RECORDSET":
                throw BASICError.runtime("A Recordset comes from SqlDatabase.Query, not from NEW")
            default:
                throw BASICError.runtime("Unknown CLASS \(typeName)")
            }
        }
    }

    /// Calls a method on a handle.
    public static func call(typeName: String, id: Int, method: String, arguments: [Value]) throws -> Value {
        lock.lock()
        defer { lock.unlock() }
        return try translating {
            let values = arguments.map(basicValue)
            switch typeName.uppercased() {
            case "SQLDATABASE":
                return bridgeValue(try runtime.callSQLDatabase(id: id, method: method, arguments: values))
            case "DOCUMENTDATABASE":
                return bridgeValue(try runtime.callDocumentDatabase(id: id, method: method, arguments: values))
            case "RECORDSET":
                return bridgeValue(try runtime.callRecordset(id: id, method: method, arguments: values))
            case "DATASTORE":
                return bridgeValue(try runtime.callDataStore(
                    id: id, method: method, arguments: values,
                    classDefinition: { schema.definition(named: $0) }
                ))
            default:
                throw BASICError.runtime("\(typeName) has no method \(method)")
            }
        }
    }

    // MARK: - Errors

    /// Runs a call and states its failure the way the interpreter would.
    private static func translating(_ body: () throws -> Value) throws -> Value {
        do {
            return try body()
        } catch let error as BASICDataError {
            throw Failure(message: error.description)
        } catch let error as BASICError {
            throw Failure(message: bare(error))
        } catch let failure as Failure {
            throw failure
        } catch {
            throw Failure(message: "\(error)")
        }
    }

    /// The message without the prefix the compiled runtime adds itself.
    private static func bare(_ error: BASICError) -> String {
        if case .runtime(let message) = error { return message }
        return error.description
    }

    private static func text(_ arguments: [Value], _ what: String) throws -> String {
        guard arguments.count == 1, case .string(let url) = arguments[0] else {
            throw BASICError.runtime("\(what) wants a connection string")
        }
        return url
    }

    // MARK: - The two value shapes

    private static func basicValue(_ value: Value) -> BASICValue {
        switch value {
        case .number(let number): return .number(number)
        case .string(let text): return .string(BASICString(text))
        case .boolean(let flag): return .boolean(flag)
        case .handle(let id, let kind): return .systemObject(kind, id)
        case .object(let typeName, let fields): return .object(typeName, fields.mapValues(basicValue))
        case .empty: return .empty
        }
    }

    private static func bridgeValue(_ value: BASICValue) -> Value {
        switch value {
        case .number(let number): return .number(number)
        case .string(let text): return .string(text.description)
        case .boolean(let flag): return .boolean(flag)
        case .systemObject(let kind, let id): return .handle(id: id, kind: kind)
        case .object(let typeName, let fields): return .object(typeName: typeName, fields: fields.mapValues(bridgeValue))
        default: return .empty
        }
    }
}
