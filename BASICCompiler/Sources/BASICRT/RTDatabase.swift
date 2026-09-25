import Foundation

// BASICRT database objects — SqlDatabase, DocumentDatabase, Recordset and
// DataStore, for a compiled program.
//
// This file holds a handle and an ABI, and nothing else. The providers, the
// predicate lowering, the schema comparison and the ORM all live in BASICCore,
// where the interpreter reads them, and a compiled program reaches the same
// code across the same host seam TUIKit and RichSwift use.
//
// That is deliberate, and it is D12's whole point here: two implementations of
// an ORM would not merely drift in behavior, they would drift in *stored
// data* — one engine writing a column the other could not read. So there is
// one, and this is how a compiled program calls it.

/// The host's database bridge (BASICRTHost) — or the stub that says no.
@_silgen_name("basic_rt_host_db_new") func rtHostDBNew(_ typeName: UnsafePointer<CChar>, _ count: Int, _ arguments: UnsafePointer<UnsafeMutableRawPointer?>) -> UnsafeMutableRawPointer
@_silgen_name("basic_rt_host_db_call") func rtHostDBCall(_ typeName: UnsafePointer<CChar>, _ id: Int, _ method: UnsafePointer<CChar>, _ count: Int, _ arguments: UnsafePointer<UnsafeMutableRawPointer?>) -> UnsafeMutableRawPointer
@_silgen_name("basic_rt_host_db_schema") func rtHostDBSchema(_ json: UnsafePointer<CChar>)

/// A handle to a database object the host holds: an id and what it is, as the
/// interpreter's `.systemObject(kind, id)` is.
package final class RTDataHandle {
    package let id: Int
    package let typeName: String
    package init(id: Int, typeName: String) {
        self.id = id
        self.typeName = typeName
    }
}

enum RTDatabase {
    /// The pseudo classes this file answers for, spelled as the interpreter
    /// spells them. `Recordset` is here because a cursor *is* one of these —
    /// it simply comes from `Query` rather than from a constructor.
    static let classNames: [String: String] = [
        "SQLDATABASE": "SqlDatabase",
        "DOCUMENTDATABASE": "DocumentDatabase",
        "DATASTORE": "DataStore",
        "RECORDSET": "Recordset",
    ]

    /// The program's class and ENUM declarations, as the compiler emitted
    /// them, held until a database is opened.
    ///
    /// Pushed lazily so a program that never touches a database never calls
    /// the host at all: with the stubs linked, that call would fail, and a
    /// program with a CLASS in it and no database has done nothing wrong.
    nonisolated(unsafe) private static var schema: String?
    nonisolated(unsafe) private static var schemaSent = false

    static func register(schema json: String) {
        schema = json
        schemaSent = false
    }

    /// Hands the host the declarations, once.
    private static func sendSchema() {
        guard !schemaSent, let json = schema else { return }
        schemaSent = true
        json.withCString { rtHostDBSchema($0) }
    }

    /// `SqlDatabase(url$)`, `DocumentDatabase(url$)`, `DataStore(database)`.
    static func new(_ name: String, _ values: [RTValue]) -> RTValue {
        sendSchema()
        let boxes = values.map { Optional(rtOwned($0)) }
        defer { boxes.forEach { basic_rt_value_release($0) } }
        let handle = boxes.withUnsafeBufferPointer { buffer in
            name.withCString { rtHostDBNew($0, buffer.count, buffer.baseAddress!) }
        }
        defer { basic_rt_value_release(handle) }
        return rtValue(handle)
    }

    /// `database.Method(args…)`.
    static func call(_ handle: RTDataHandle, method: String, arguments: [RTValue]) -> RTValue {
        let boxes = arguments.map { Optional(rtOwned($0)) }
        defer { boxes.forEach { basic_rt_value_release($0) } }
        let result = boxes.withUnsafeBufferPointer { buffer in
            handle.typeName.withCString { type in
                method.withCString { name in
                    rtHostDBCall(type, handle.id, name, buffer.count, buffer.baseAddress!)
                }
            }
        }
        defer { basic_rt_value_release(result) }
        return rtValue(result)
    }
}

/// Registers the program's class and ENUM declarations for the ORM.
///
/// Emitted once, at start, for a program that declares any class the ORM
/// could be asked to map. The string is the compiler's; BASICCore reads it.
@_cdecl("basic_rt_db_schema")
public func basic_rt_db_schema(_ json: UnsafePointer<CChar>) {
    RTDatabase.register(schema: String(cString: json))
}
