//
//  StudioFrameworkMap.swift
//  BASICStudio
//
//  IMPORT of the frameworks Studio contains (BASIC-45, slice 11): a program
//  Studio runs as WebAssembly may `IMPORT "ActiveUI"` or `IMPORT "TUIKit"`
//  and use their own classes. Nothing is built where it runs: the map
//  (Code/BASICFrameworkMap) carries each framework's symbol graph for the
//  compiler, and a shim for every member, compiled into Studio, that the
//  runner calls by name. Anything Studio does not contain cannot be imported.
//

import ActiveUI
import BASICDialectSwift
import BASICFrameworkMap
import BASICWasmRunner
import Foundation

enum StudioFrameworkMap {
    /// What `IMPORT` reads for a framework Studio contains.
    static let imports = SwiftMappedImports(
        frameworks: BASICFrameworkMap.frameworks.map {
            SwiftMappedImports.Framework(module: $0.module, symbolGraph: $0.symbolGraph.path, exported: $0.exported.path)
        },
        shims: Set(BASICFrameworkMap.entries.keys))

    /// The map's entries for a run, with Studio's own where the framework's
    /// would start a second application inside Studio.
    static func entries(for model: StudioModel?, title: String) -> [String: WasmEntryPoint] {
        var entries = BASICFrameworkMap.entries
        // `AUIApplication.run(root, placement)` starts the platform's
        // application and keeps the main thread until it quits. In Studio the
        // root goes in a window of Studio's, and the program waits until that
        // window closes — as the app would until it quit — handling what the
        // user does meanwhile. Stop ends the wait; the run's end closes it.
        entries["basic_handler_AUIApplication_shared_run"] = WasmEntryPoint(arity: 2) { [weak model] a in
            // The view's address, carried as a number: a pointer is not
            // Sendable, and the view is the main actor's anyway.
            let rootBits = UInt(a[0])
            let closed = DispatchSemaphore(value: 0)
            _ = WasmMainThread.run {
                MainActor.assumeIsolated {
                    guard let root = UnsafeMutableRawPointer(bitPattern: rootBits), let model else {
                        closed.signal()
                        return
                    }
                    let view = Unmanaged<AUIView>.fromOpaque(root).takeUnretainedValue()
                    model.auiBridge.openAppWindow(view, title: title) { closed.signal() }
                }
                return 0
            }
            WasmMainThread.wait(for: closed)
            return 0
        }
        return entries
    }
}
