#if canImport(AppKit)
import AppKit
#else
import UIKit
#endif
import CoreText

enum StudioFonts {
    /// Every font family installed, for the font pickers.
    @MainActor
    static var installedFamilies: [String] {
        #if canImport(AppKit)
        NSFontManager.shared.availableFontFamilies
        #else
        UIFont.familyNames
        #endif
    }

    static let defaultFamily = "MesloLGS NF"
    static let legacyDefaultFamily = "SF Mono"
    static let legacyPlainPromptTemplate = "${user}:${currentdir} ${gitstatus}> "

    static func registerBundledFonts() {
        guard let fontURLs = Bundle.main.urls(forResourcesWithExtension: "ttf", subdirectory: "Fonts") else { return }
        for url in fontURLs {
            var error: Unmanaged<CFError>?
            if !CTFontManagerRegisterFontsForURL(url as CFURL, .process, &error),
               let error = error?.takeRetainedValue() {
                NSLog("Unable to register bundled font \(url.lastPathComponent): \(error.localizedDescription)")
            }
        }
    }
}
