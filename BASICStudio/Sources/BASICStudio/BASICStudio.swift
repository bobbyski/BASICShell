//
//  BASICStudio.swift
//  BASICStudio
//
//  The entry point: one binary, two shells.
//

import SwiftUI

/// Puts up the shell the command line asks for: the ActiveUI shell, which is
/// Studio, unless `--swiftui-reference` asks for the SwiftUI shell kept to
/// compare against (``StudioLaunchOptions``).
///
/// Both run over the same ``StudioModel`` and the same projections, which is
/// what lets ACTIVEUI_TRANSITION.md's parity walk be the same binary, the
/// same program and the same checklist, twice.
@main
enum StudioMain {
    @MainActor
    static func main() {
        switch StudioLaunchOptions.current.shell {
        case .swiftUI:
            BASICStudioApp.main()
        case .activeUI:
            StudioActiveUIShell.run(launch: .current)
        }
    }
}
