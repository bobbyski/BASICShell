import Foundation
#if canImport(Darwin)
import Darwin
#endif

/// The reference document provider: real, in memory, no dependency.
///
/// Not a mock. It is a full `BASICDocumentProvider` conformance, which is what
/// lets D4's ORM be built and tested before MongoDB exists, and what any later
/// document provider runs as its conformance suite. Building it first is also
/// what stops the protocol being quietly shaped around one store.
public final class BASICMemoryDocumentProvider: BASICDocumentProvider, @unchecked Sendable {
    /// The key a document is identified by, matching MongoDB's own.
    public static let identifierField = "_id"

    public static let providerName = "Memory"

    public static func handles(_ url: String) -> Bool {
        let lowered = url.lowercased()
        return lowered == "memory:" || lowered.hasPrefix("memory://")
    }

    private struct Entry {
        var key: BASICDataValue
        var document: BASICDocument
    }

    private let lock = NSLock()
    private var collectionOrder: [String] = []
    private var entries: [String: [Entry]] = [:]
    private var indexes: [String: [BASICIndexSchema]] = [:]
    private var nextIdentifier: Int64 = 1
    private var open = false

    /// Creates an empty store.
    public init() {}

    /// Scoped locking, because Swift 6 forbids a bare `lock()` in an async
    /// context — it cannot see that the critical section never suspends.
    private func locked<T>(_ body: () throws -> T) rethrows -> T {
        lock.lock()
        defer { lock.unlock() }
        return try body()
    }

    public var capabilities: BASICDataCapabilities {
        // No transactions, matching a Mongo deployment without a replica set:
        // the reference provider should not let the ORM depend on something
        // the first real document store may not have (DB14).
        BASICDataCapabilities(
            supportsTransactions: false,
            supportsAlterColumn: true,
            supportsIndexes: true,
            reportsGeneratedKeys: true,
            booleanSpelling: "bool"
        )
    }

    public var isOpen: Bool {
        locked { open }
    }

    public func open(_ url: String) async throws {
        try Self.requireAvailable()
        locked { open = true }
    }

    public func close() async {
        locked { open = false }
    }

    public func ping() async throws -> Bool {
        isOpen
    }

    public func insert(collection: String, document: BASICDocument) async throws -> BASICDataValue {
        try requireOpen()
        return locked {
        var stored = document
        let key: BASICDataValue
        if let existing = stored.scalar(Self.identifierField), !existing.isNull {
            key = existing
        } else {
            key = .integer(nextIdentifier)
            nextIdentifier += 1
            stored.setScalar(Self.identifierField, key)
        }
        registerCollection(collection)
        entries[collection, default: []].append(Entry(key: key, document: stored))
        return key
        }
    }

    public func upsert(collection: String, key: BASICDataValue, document: BASICDocument) async throws {
        try requireOpen()
        return locked {
        var stored = document
        stored.setScalar(Self.identifierField, key)
        registerCollection(collection)
        var list = entries[collection] ?? []
        if let index = list.firstIndex(where: { BASICPredicateEvaluator.equal($0.key, key) }) {
            list[index].document = stored
        } else {
            list.append(Entry(key: key, document: stored))
        }
        entries[collection] = list
        }
    }

    public func find(
        collection: String,
        filter: BASICQueryPredicate,
        limit: Int?
    ) async throws -> [BASICDocument] {
        try requireOpen()
        try requireSupported(filter)
        return locked {
        var found: [BASICDocument] = []
        for entry in entries[collection] ?? [] {
            guard BASICPredicateEvaluator.matches(filter, { entry.document.scalar($0) }) else { continue }
            found.append(entry.document)
            if let limit, found.count >= limit { break }
        }
        return found
        }
    }

    public func delete(collection: String, filter: BASICQueryPredicate) async throws -> Int {
        try requireOpen()
        try requireSupported(filter)
        return locked {
        let before = entries[collection]?.count ?? 0
        entries[collection] = (entries[collection] ?? []).filter {
            !BASICPredicateEvaluator.matches(filter, $0.document.scalar)
        }
        return before - (entries[collection]?.count ?? 0)
        }
    }

    public func ensureIndex(collection: String, fields: [String], unique: Bool) async throws {
        try requireOpen()
        locked {
        registerCollection(collection)
        let name = "ix_\(collection)_\(fields.joined(separator: "_"))"
        var list = indexes[collection] ?? []
        guard !list.contains(where: { $0.name == name }) else { return }
        list.append(BASICIndexSchema(name: name, columns: fields, isUnique: unique))
        indexes[collection] = list
        }
    }

    public func collections() async throws -> [String] {
        try requireOpen()
        return locked { collectionOrder }
    }

    /// The indexes declared on a collection, for tests and diagnostics.
    public func declaredIndexes(collection: String) -> [BASICIndexSchema] {
        locked { indexes[collection] ?? [] }
    }

    private func registerCollection(_ name: String) {
        if entries[name] == nil && !collectionOrder.contains(name) {
            collectionOrder.append(name)
        }
    }

    private func requireOpen() throws {
        guard isOpen else { throw BASICDataError.notConnected }
    }

    private func requireSupported(_ predicate: BASICQueryPredicate) throws {
        let supported = capabilities.operators
        for op in predicate.usedOperators where !supported.contains(op) {
            throw BASICDataError.unsupportedOperator(op, provider: Self.providerName)
        }
    }
}
