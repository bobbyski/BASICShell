//
//  BASICMongoProvider.swift
//  BASICMongo
//
//  MongoDB, through MongoKitten (D8, DB13).
//

import BASICCore
import Foundation
import MongoKitten

// Its own target, not part of BASICCore, because DB11 says the drivers live
// with the hosts and MongoKitten brings thirteen packages with it -- NIO, BSON,
// DNSClient and the rest. `BASICCore` is linked by `BASICShell`, `BASICStudio`
// and every compiled program's runtime host; paying for a Mongo driver in a
// program that prints "HELLO, WORLD" is not a trade worth making. A host that
// wants Mongo links this target and calls `BASICMongo.register()`.
//
// MongoKitten rather than the official driver: that one was archived in 2023
// and wraps `libmongoc`, which does not travel to Windows the way pure Swift
// and NIO do (§5.1). MIT licensed, and maintained -- 7.16.3 at the time of
// writing.

/// MongoDB as a ``BASICDocumentProvider``.
public final class BASICMongoProvider: BASICDocumentProvider, @unchecked Sendable {

    public static let providerName = "MongoDB"

    /// `mongodb://…` and `mongodb+srv://…`.
    ///
    /// A match rather than a constant, as the protocol asks: `+srv` is a
    /// different scheme to a URL parser and the same database to a person.
    public static func handles(_ url: String) -> Bool {
        let lowered = url.lowercased()
        return lowered.hasPrefix("mongodb://") || lowered.hasPrefix("mongodb+srv://")
    }

    /// MongoKitten is pure Swift over NIO, so it exists wherever Swift does.
    ///
    /// Reaching a server is a different question, and one only `open` can
    /// answer — DB17 separates "this build has the driver" from "this machine
    /// can reach the database", and conflating them turns a firewall into a
    /// missing feature.
    public static var isAvailableOnThisPlatform: Bool { true }

    public static var unavailableMessage: String {
        "MongoDB is available wherever Swift is; if a connection fails, the server is the thing to check"
    }

    private let lock = NSLock()
    private var database: MongoDatabase?

    public init() {}

    private func locked<T>(_ body: () throws -> T) rethrows -> T {
        lock.lock()
        defer { lock.unlock() }
        return try body()
    }

    public var isOpen: Bool { locked { database != nil } }

    /// What a Mongo connection can do.
    ///
    /// Read rather than assumed, which for Mongo matters more than most:
    /// transactions need a replica set, and a standalone `mongod` has none.
    /// Reported as absent rather than attempted, so `store.Begin` says so
    /// instead of failing halfway through (DB14).
    public var capabilities: BASICDataCapabilities {
        BASICDataCapabilities(
            supportsTransactions: false,
            supportsAlterColumn: true,
            supportsIndexes: true,
            reportsGeneratedKeys: true,
            operators: Set(BASICPredicateOperator.allCases).subtracting([.matches]),
            booleanSpelling: "bool"
        )
    }

    public func open(_ url: String) async throws {
        guard Self.handles(url) else {
            throw BASICDataError.badConnectionString("\(url) is not a MongoDB connection string")
        }
        do {
            let connected = try await MongoDatabase.connect(to: url)
            locked { database = connected }
        } catch {
            throw BASICDataError.driver("Could not connect to MongoDB: \(error)")
        }
    }

    public func close() async {
        locked { database = nil }
    }

    public func ping() async throws -> Bool {
        guard let database = locked({ self.database }) else { return false }
        do {
            _ = try await database.listCollections()
            return true
        } catch {
            return false
        }
    }

    private func connected() throws -> MongoDatabase {
        guard let database = locked({ self.database }) else { throw BASICDataError.notConnected }
        return database
    }

    // MARK: - Documents

    public func insert(collection: String, document: BASICDocument) async throws -> BASICDataValue {
        let database = try connected()
        var bson = Self.bson(document)
        // The store assigns the key when the program did not, which is the
        // same contract the SQL side has for a generated integer key.
        let identifier: BASICDataValue
        if let existing = bson["_id"] {
            identifier = Self.value(existing) ?? .null
        } else {
            let assigned = ObjectId()
            bson["_id"] = assigned
            identifier = .text(assigned.hexString)
        }
        do {
            _ = try await database[collection].insert(bson)
        } catch {
            throw BASICDataError.driver("MongoDB insert failed: \(error)")
        }
        return identifier
    }

    public func upsert(collection: String, key: BASICDataValue, document: BASICDocument) async throws {
        let database = try connected()
        var bson = Self.bson(document)
        bson["_id"] = Self.primitive(key)
        do {
            _ = try await database[collection].upsert(bson, where: ["_id": Self.primitive(key)])
        } catch {
            throw BASICDataError.driver("MongoDB upsert failed: \(error)")
        }
    }

    public func find(
        collection: String,
        filter: BASICQueryPredicate,
        limit: Int?
    ) async throws -> [BASICDocument] {
        let database = try connected()
        let query = try Self.query(filter)
        do {
            var builder = database[collection].find(query)
            if let limit { builder = builder.limit(limit) }
            return try await builder.drain().map(Self.document)
        } catch let error as BASICDataError {
            throw error
        } catch {
            throw BASICDataError.driver("MongoDB find failed: \(error)")
        }
    }

    public func delete(collection: String, filter: BASICQueryPredicate) async throws -> Int {
        let database = try connected()
        let query = try Self.query(filter)
        do {
            return try await database[collection].deleteAll(where: query).deletes
        } catch {
            throw BASICDataError.driver("MongoDB delete failed: \(error)")
        }
    }

    public func ensureIndex(collection: String, fields: [String], unique: Bool) async throws {
        let database = try connected()
        var keys = Document()
        for field in fields { keys[field] = 1 as Int32 }
        let name = "ix_" + fields.joined(separator: "_")
        do {
            if unique {
                var index = CreateIndexes.Index(named: name, keys: keys)
                index.unique = true
                try await database[collection].createIndexes([index])
            } else {
                try await database[collection].createIndex(named: name, keys: keys)
            }
        } catch {
            throw BASICDataError.driver("MongoDB index failed: \(error)")
        }
    }

    public func collections() async throws -> [String] {
        let database = try connected()
        do {
            return try await database.listCollections().map(\.name)
        } catch {
            throw BASICDataError.driver("MongoDB listCollections failed: \(error)")
        }
    }
}
