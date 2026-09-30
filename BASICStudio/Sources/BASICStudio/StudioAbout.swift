#if canImport(AppKit)
import AppKit
#else
import UIKit
#endif
import Foundation

/// The About panel, and the badge it shows.
///
/// AppKit's standard panel rather than a window of our own: it already knows how
/// to lay out a name, a version and a copyright, it picks up
/// `CFBundleShortVersionString` and `CFBundleVersion` from the Info.plist
/// without being told, and it is the shape a Mac user expects from
/// ⌘-About. What it does *not* do by itself is show artwork other than the app
/// icon — so the badge is handed to it explicitly.
enum StudioAbout {

    /// Shows the panel, centred, in front of everything.
    static func show() {
        NSApplication.shared.orderFrontStandardAboutPanel(options: options())
        NSApplication.shared.activate(ignoringOtherApps: true)
    }

    private static func options() -> [NSApplication.AboutPanelOptionKey: Any] {
        var options: [NSApplication.AboutPanelOptionKey: Any] = [
            .applicationName: "BASICStudio",
            .credits: credits(),
        ]
        if let badge { options[.applicationIcon] = badge }
        return options
    }

    /// The badge, loaded the way every other bundled resource here is loaded.
    ///
    /// `Bundle.main` with a `subdirectory:`, not `Bundle.module`: the app is
    /// built as an app bundle, and the SwiftPM module-bundle accessor looks
    /// beside `Bundle.main.bundleURL` rather than inside `Contents/Resources`
    /// — which works on the machine that built it and fails everywhere else.
    private static let badge: NSImage? = {
        guard let url = Bundle.main.url(
            forResource: "BASICStudioLogo", withExtension: "png", subdirectory: "Assets"
        ) else { return nil }
        let image = NSImage(contentsOf: url)
        // The panel draws the icon at 64pt or so and scales whatever it is
        // given; saying the size in points keeps it crisp on Retina rather
        // than letting it be treated as 1024 points across.
        image?.size = NSSize(width: 256, height: 256)
        return image
    }()

    /// The line under the version. Kept short: the panel is not a README.
    private static func credits() -> NSAttributedString {
        let font = NSFont.systemFont(ofSize: NSFont.smallSystemFontSize)
        let paragraph = NSMutableParagraphStyle()
        paragraph.alignment = .center
        return NSAttributedString(
            string: "A BASIC that reads like BASIC, on a modern runtime.\n"
                  + "Interpreter, and two compilers that agree with it.",
            attributes: [
                .font: font,
                .foregroundColor: NSColor.secondaryLabelColor,
                .paragraphStyle: paragraph,
            ]
        )
    }
}
