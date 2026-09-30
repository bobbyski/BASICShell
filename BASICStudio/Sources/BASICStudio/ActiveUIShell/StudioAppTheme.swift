//
//  StudioAppTheme.swift
//  BASICStudio
//
//  The ActiveUI shell's themes.
//

import ActiveUI
import AppKit
import Foundation

/// The themes the ActiveUI shell offers: the ones FreebirdStudio, VGTerm and
/// the ActiveUI catalog offer, applied to the whole window.
///
/// A theme is a file, `Resources/Themes/<name>.css`, as in each of those apps.
/// Native is no file at all: the system's own look. Every other theme is dark.
///
/// The editor follows: dark under every theme but Native, and the system's
/// light or dark under Native. The SwiftUI shell keeps its own Dark, Light
/// and High Contrast for Monaco (`EditorTheme`).
enum StudioAppTheme {
    /// The system look: no stylesheet.
    static let native = "Native"
    /// The themes on offer, in menu order.
    static let names = [native, "NC State", "Blue", "moneyBags", "Slate", "Freebird"]
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
        AUIApplication.appearance = theme == native ? .system : .dark
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

    /// The editor's colors under a theme: dark, or under Native, the system's.
    @MainActor
    static func editorTheme(for name: String) -> EditorTheme {
        guard validated(name) == native else { return .dark }
        let appearance = NSApp?.effectiveAppearance ?? NSAppearance.currentDrawing()
        return appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua ? .dark : .light
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
