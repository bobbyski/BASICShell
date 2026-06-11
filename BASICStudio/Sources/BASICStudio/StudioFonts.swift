import AppKit
import CoreText

enum StudioFonts {
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
