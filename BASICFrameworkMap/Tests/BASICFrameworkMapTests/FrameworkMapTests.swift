import ActiveUI
import BASICDialectSwift
import BASICFrameworkMap
import BASICRT
import BASICRTSwift
import Foundation
import Testing

/// The map as Studio carries it (BASIC-45): what the compiler reads must name
/// exactly the shims compiled in, and the entries must reach them.
struct FrameworkMapTests {
    /// The bundled graph and export list give the API the shims were made
    /// from — no shim the compiler cannot name, no name without a shim. A map
    /// left stale by a framework change fails here, not in a program.
    @Test("A bundled graph gives back exactly the shims compiled in", arguments: ["ActiveUI", "TUIKit"])
    func graphMatchesShims(module: String) throws {
        let framework = try #require(BASICFrameworkMap.frameworks.first { $0.module == module })
        var api = try SwiftAPI.read(fileAt: framework.symbolGraph.path)
        let exported = try String(contentsOf: framework.exported, encoding: .utf8)
            .split(separator: "\n").map(String.init)
        api.keepOnly(exported: Set(exported))
        let source = try #require(SwiftPackageResolver.shimModel(for: api, mapped: true).source())
        let names = Set(SwiftFrameworkMap.signatures(in: source).map(\.name))
        let entries = module == "ActiveUI" ? ActiveUIEntries : TUIKitEntries
        #expect(names.count > 1000)
        #expect(names.subtracting(entries.keys).sorted() == [])
        #expect(Set(entries.keys).subtracting(names).sorted() == [])
    }

    /// An object made, a property set and read, and the object recognized,
    /// through the entries, as a WebAssembly import calls them: numbers.
    @Test("Entries make an ActiveUI label, set its text and know its class")
    @MainActor
    func entriesReachActiveUI() throws {
        // What a module's start does first: among other things, it gives
        // BASICRTSwift the runtime's strings.
        basic_rt_start()
        let entries = BASICFrameworkMap.entries
        func call(_ name: String, _ arguments: [Double]) throws -> Double {
            let entry = try #require(entries[name], "no entry \(name)")
            return arguments.withUnsafeBufferPointer { entry.call($0.baseAddress!) }
        }
        func string(_ text: String) -> Double { Double(UInt(bitPattern: basicRTSwiftStringOut(text))) }
        func text(_ bits: Double) -> String { basicRTSwiftStringIn(UnsafeMutableRawPointer(bitPattern: UInt(bits))) }

        let label = try call("basic_new_AUILabel_1", [string("Ready")])
        #expect(label != 0)
        #expect(text(try call("basic_get_AUILabel_text", [label])) == "Ready")
        _ = try call("basic_set_AUILabel_text", [label, string("Done")])
        #expect(text(try call("basic_get_AUILabel_text", [label])) == "Done")
        let object = Unmanaged<AnyObject>.fromOpaque(UnsafeMutableRawPointer(bitPattern: UInt(label))!).takeUnretainedValue()
        #expect((object as? AUILabel)?.text == "Done")
        #expect(try call("basic_classid_ActiveUI", [label]) >= 0)
        _ = try call("swift_release", [label])
    }
}
