import ShareBarCore
import SwiftUI

/// The Settings window's colors: the popover's `Theme`, `primitive.window` as the surface
/// (`Tokens.swift:89`, the design's `.mac --win`: `#f5f5f7` light, `#26262a` dark, sampled equal
/// in the headless render), and the 9% separator of the design.
struct SettingsTheme {
    let theme: Theme
    let scheme: ColorScheme

    init(_ scheme: ColorScheme) {
        self.scheme = scheme
        theme = Theme(scheme)
    }

    private var palette: Palette { Tokens.palette(scheme == .dark ? .dark : .light) }

    static let surfaceLight = Tokens.primitive.window.light
    static let surfaceDark = Tokens.primitive.window.dark

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
    /// The design's `--sep`: black at 9% in light, white at 9% in dark.
    var separator: Color { (scheme == .dark ? Color.white : Color.black).opacity(0.09) }
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
