//
//  StudioAppTheme.swift
//  BASICStudio
//
//  The ActiveUI shell's themes.
//

import ActiveUI
#if canImport(AppKit)
import AppKit
#else
import UIKit
#endif
import Foundation

/// The themes the ActiveUI shell offers: the ones FreebirdStudio, VGTerm and
/// the ActiveUI catalog offer, applied to the whole window.
///
/// A theme is a file, `Resources/Themes/<name>.css`, as in each of those apps.
/// Native is no file at all: the system's own look. Light is light; every
/// other theme is dark.
///
/// The editor follows: its light colors under Light, its high-contrast ones
/// under High Contrast, the system's light or dark under Native, and dark
/// otherwise. The SwiftUI shell keeps `EditorTheme` for Monaco alone.
enum StudioAppTheme {
    /// The system look: no stylesheet.
    static let native = "Native"
    /// The themes on offer, in menu order.
    static let names = [native, "Light", "Dark", "High Contrast", "NC State", "Blue", "moneyBags", "Slate", "Freebird"]
    /// Themes whose file is not simply the theme's name.
    private static let resourceNames = ["Freebird": "freebird"]

    /// `name` if it is a theme, and Native if not.
    static func validated(_ name: String) -> String {
        names.contains(name) ? name : native
    }

    /// Applies a theme to the app: its stylesheet, and the system appearance
    /// it is drawn for, so native popups match the cards around them.
    @MainActor
    static func install(_ name: String) {
        let theme = validated(name)
        switch theme {
        case native: AUIApplication.appearance = .system
        case "Light": AUIApplication.appearance = .light
        default: AUIApplication.appearance = .dark
        }
        AUITheme.install(stylesheet(for: theme))
    }

    /// A theme's stylesheet, or nil for Native.
    static func stylesheet(for name: String) -> AUIStylesheet? {
        guard name != native, let css = css(for: name) else { return nil }
        return AUIStylesheet(css: css)
    }

    /// A theme file's contents: from the app's Resources, or under SwiftPM
    /// from the module's bundle.
    static func css(for name: String) -> String? {
        let resource = resourceNames[name] ?? name
        var bundles = [Bundle.main]
        #if SWIFT_PACKAGE
        bundles.append(Bundle.module)
        #endif
        for bundle in bundles {
            if let url = bundle.url(forResource: resource, withExtension: "css", subdirectory: "Themes"),
               let css = try? String(contentsOf: url, encoding: .utf8) {
                return css
            }
        }
        return nil
    }

    /// The editor's colors under a theme.
    @MainActor
    static func editorTheme(for name: String) -> EditorTheme {
        switch validated(name) {
        case "Light": return .light
        case "High Contrast": return .highContrast
        case native: break
        default: return .dark
        }
        #if canImport(AppKit)
        let appearance = NSApp?.effectiveAppearance ?? NSAppearance.currentDrawing()
        return appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua ? .dark : .light
        #else
        return UITraitCollection.current.userInterfaceStyle == .dark ? .dark : .light
        #endif
    }

    /// `input` with the editor's colors taken from the app theme.
    @MainActor
    static func themed(_ input: EditorRenderInput, _ model: StudioModel) -> EditorRenderInput {
        var input = input
        input.theme = editorTheme(for: model.appTheme)
        return input
    }

    /// The toolbar's theme pull-down, in the projection's menu shape.
    @MainActor
    static func menu(_ model: StudioModel) -> StudioShellModel.Menu {
        let current = validated(model.appTheme)
        return StudioShellModel.Menu(
            label: current,
            symbol: "paintpalette",
            help: "Theme",
            items: names.map { StudioShellModel.Item(title: $0, isChecked: $0 == current) }
        )
    }

    /// Picks the theme menu's `index`th item.
    @MainActor
    static func choose(_ index: Int, on model: StudioModel) {
        model.appTheme = names[index]
    }
}
