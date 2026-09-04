import Testing
import TUIKit
@testable import BASICCore
@testable import BASICSyntax

@Suite("TUI desktop colour")
struct BASICTUIDesktopTests {
    /// The desktop a plain terminal paints must match the one a VectorTerminal
    /// draws, or the same theme looks like two themes.
    @Test("every built-in theme resolves a desktop colour, and never plain grey when it describes one")
    func desktopColours() {
        for (name, theme) in Theme.builtIn {
            let fill = BASICRuntime.tuiDesktopFill(for: theme)
            let describesOne = theme.resolved(for: .desktop).background != .standard
                || theme.base.vector?.desktop != nil
            if describesOne {
                #expect(
                    fill != .rgb(red: 128, green: 128, blue: 128),
                    "\(name) describes a desktop but fell back to neutral grey"
                )
            }
        }
    }

    @Test("Modern Turbo paints Turbo's blue, not grey")
    func modernTurboIsBlue() {
        let fill = BASICRuntime.tuiDesktopFill(for: .modernTurbo)
        #expect(fill != .rgb(red: 128, green: 128, blue: 128))
        print("Modern Turbo desktop fill:", fill)
    }
}
