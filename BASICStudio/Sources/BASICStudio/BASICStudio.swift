//
//  BASICStudio.swift
//  BASICStudio
//
//  The entry point.
//

/// Puts up Studio: the ActiveUI shell. Studio began as a SwiftUI app and
/// kept a SwiftUI shell to compare against for a while; that is gone (Bobby,
/// 2026-10-10: no SwiftUI, ever).
@main
enum StudioMain {
    @MainActor
    static func main() {
        StudioActiveUIShell.run(launch: .current)
    }
}
