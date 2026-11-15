import ShareBarCore
import SwiftUI

/// The Settings window's colors: the popover's `Theme` plus the revision 8 window surface
/// and the 9% separator of the design. `primitive.window` is `#f5f5f7` and `#26262a`
/// (`Tokens.swift:89`) and Tokens is frozen after SG-06, so the surface lives here.
struct SettingsTheme {
    let theme: Theme
    let scheme: ColorScheme

    init(_ scheme: ColorScheme) {
        self.scheme = scheme
        theme = Theme(scheme)
    }

    private var palette: Palette { Tokens.palette(scheme == .dark ? .dark : .light) }

    /// Revision 8 of `docs/design/share-bar-redesign.html`: `#eff0f3` light, `#2b2c31` dark.
    static let surfaceLight = RGB(hex: "#eff0f3")
    static let surfaceDark = RGB(hex: "#2b2c31")

    func color(_ rgb: RGB, opacity: Double = 1) -> Color {
        Color(.sRGB, red: rgb.red / 255, green: rgb.green / 255, blue: rgb.blue / 255, opacity: opacity)
    }

    var surface: Color { color(scheme == .dark ? Self.surfaceDark : Self.surfaceLight) }
    var field: Color { theme.field }
    var label: Color { theme.label }
    var secondary: Color { theme.secondary }
    var tertiary: Color { theme.tertiary }
    var info: Color { theme.info }
    var infoInk: Color { theme.infoInk }
    var focus: Color { theme.focus }
    var ok: Color { theme.ok }
    var attention: Color { color(palette.semantic.attention) }
    var attentionInk: Color { theme.attentionInk }
    var errorInk: Color { theme.errorInk }
    var quiet: Color { color(palette.semantic.quiet) }
    var separator: Color { color(palette.primitive.label.value(palette.appearance), opacity: 0.09) }
    var hover: Color { theme.hover }
    var selection: Color { color(palette.primitive.label.value(palette.appearance), opacity: palette.semantic.selectionOpacity) }
    var border: Color { color(palette.primitive.label.value(palette.appearance), opacity: 0.18) }
    var softBorder: Color { color(palette.primitive.label.value(palette.appearance), opacity: 0.14) }
    var destructiveFill: Color { color(RGB(hex: "#d70015")) }

    var titleFont: Font { theme.titleFont }
    var bodyFont: Font { theme.bodyFont }
    var metaFont: Font { theme.metaFont }
    var monoFont: Font { theme.monoFont }
}

/// Paints the surface on the root of a window (the owner's rule for every window).
struct WindowSurface: ViewModifier {
    @Environment(\.colorScheme) private var scheme

    func body(content: Content) -> some View {
        content.background(SettingsTheme(scheme).surface.ignoresSafeArea())
    }
}

extension View {
    func windowSurface() -> some View { modifier(WindowSurface()) }
}
