//
//  BASICDataProviderRegistry.swift
//  BASICCore
//
//  How a provider that BASICCore does not link makes itself available (DB11).
//

import Foundation

/// The providers a process can open a database with.
///
/// DB11 puts the protocols and the ORM in `BASICCore` and the **drivers in the
/// hosts**, and this is the seam that makes that possible. It is not ceremony:
/// MongoKitten brings thirteen packages with it — NIO, BSON, DNSClient and the
/// rest — and `BASICCore` is linked by `BASICShell`, `BASICStudio` and every
/// compiled program's runtime host. Paying for a Mongo driver in a program that
/// prints "HELLO, WORLD" is not a trade worth making.
///
/// So a driver is its own target, a host links it if it wants it, and it says so
/// here. A program that names a database nobody registered gets
/// ``BASICDataError/noProviderFor(url:)`` — the connection string is named, and
/// what is missing is a *driver*, which is a thing an operator can install.
public enum BASICDataProviders {

    /// A registered driver: what it answers to, and how to make one.
    public struct Registration: Sendable {
        /// Whether this driver recognizes a connection string.
        public let handles: @Sendable (String) -> Bool
        /// A short name for diagnostics: `MongoDB`, `ODBC`.
        public let providerName: String
        /// Builds one. Not `open`ed yet — the caller does that, so failure to
        /// connect is reported the same way for every driver.
        public let make: @Sendable () -> any BASICDocumentProvider

        public init(
            providerName: String,
            handles: @escaping @Sendable (String) -> Bool,
            make: @escaping @Sendable () -> any BASICDocumentProvider
        ) {
            self.providerName = providerName
            self.handles = handles
            self.make = make
        }
    }

    private final class Storage: @unchecked Sendable {
        private let lock = NSLock()
        private var documents: [Registration] = []

        func add(_ registration: Registration) {
            lock.lock()
            defer { lock.unlock() }
            // Re-registering replaces, so a host that registers twice — a test
            // process running two programs — does not accumulate duplicates.
            documents.removeAll { $0.providerName == registration.providerName }
            documents.append(registration)
        }

        func document(for url: String) -> Registration? {
            lock.lock()
            defer { lock.unlock() }
            return documents.first { $0.handles(url) }
        }

        var names: [String] {
            lock.lock()
            defer { lock.unlock() }
            return documents.map(\.providerName)
        }
    }

    private static let storage = Storage()

    /// Makes a document driver available to this process.
    public static func register(document registration: Registration) {
        storage.add(registration)
    }

    /// The driver that answers to a connection string, or nil.
    static func documentProvider(for url: String) -> (any BASICDocumentProvider)? {
        storage.document(for: url)?.make()
    }

    /// Every registered document driver's name, for diagnostics.
    public static var documentProviderNames: [String] { storage.names }
}
