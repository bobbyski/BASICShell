//
//  BASICStudioiOS.swift
//  BASICStudio-iOS
//
//  The entry point on iPhone and iPad: the ActiveUI shell, the only one
//  there is off the Mac. The SwiftUI shell is macOS-only.
//

import Foundation

@main
enum StudioMainiOS {
    @MainActor
    static func main() {
        StudioActiveUIShell.run(launch: .current)
    }
}
