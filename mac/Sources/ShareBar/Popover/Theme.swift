import ShareBarCore
import SwiftUI

/// The token palette as SwiftUI colors, for the current appearance. Every color of the
/// popover comes from here, so a contrast change is one edit in `Tokens`.
struct Theme {
    let palette: Palette
    private let scheme: ColorScheme

    init(_ scheme: ColorScheme) {
        self.scheme = scheme
        palette = Tokens.palette(scheme == .dark ? .dark : .light)
    }

    private func color(_ rgb: RGB, opacity: Double = 1) -> Color {
        Color(.sRGB, red: rgb.red / 255, green: rgb.green / 255, blue: rgb.blue / 255, opacity: opacity)
    }

    private var primitive: PrimitiveTokens { palette.primitive }
    private var semantic: SemanticTokens { palette.semantic }

    var label: Color { color(primitive.label.value(palette.appearance)) }
    var secondary: Color { color(primitive.labelSecondary.value(palette.appearance)) }
    var tertiary: Color { color(primitive.labelTertiary.value(palette.appearance)) }
    var dimmed: Color { color(primitive.labelDimmed.value(palette.appearance)) }
    var hover: Color { color(primitive.label.value(palette.appearance), opacity: semantic.hoverOpacity) }
    var pressed: Color { color(primitive.label.value(palette.appearance), opacity: semantic.pressedOpacity) }
    var separator: Color { color(primitive.label.value(palette.appearance), opacity: 0.09) }
    /// The window color of revision 8 as the design renders it over its desk (`#eff0f3`, dark `#2b2c31`),
    /// painted opaque on the popover root. `primitive.window` (`#f5f5f7`) is the contrast reference only.
    var surface: Color {
        scheme == .dark ? color(RGB(hex: "#2b2c31")) : color(RGB(hex: "#eff0f3"))
    }
    /// The border of the shortcut keycap (`rgba(ink, .14)`).
    var keycapBorder: Color { color(primitive.label.value(palette.appearance), opacity: 0.14) }
    var attentionInk: Color { color(semantic.attentionInk) }
    var errorInk: Color { color(semantic.errorInk) }
    var ok: Color { color(semantic.ok) }
    var info: Color { color(semantic.info) }
    var infoInk: Color { color(semantic.infoInk) }
    var focus: Color { color(semantic.focus) }
    var toastBackground: Color { color(semantic.toastBackground) }
    var toastForeground: Color { color(semantic.toastForeground) }
    var toastAction: Color { color(semantic.toastAction) }
    var field: Color { color(primitive.field.value(palette.appearance)) }
    var chipFill: Color { color(semantic.attention, opacity: semantic.chipOpacity) }

    var titleFont: Font { .system(size: primitive.titleSize, weight: .semibold) }
    var bodyFont: Font { .system(size: primitive.bodySize) }
    var metaFont: Font { .system(size: primitive.metaSize) }
    var monoFont: Font { .system(size: primitive.monoSize, design: .monospaced) }
    var rowRadius: CGFloat { primitive.rowRadius }
    var chipRadius: CGFloat { primitive.chipRadius }
    var buttonRadius: CGFloat { primitive.buttonRadius }
    var minRowHeight: CGFloat { primitive.minRowHeight }
    var iconButton: CGFloat { primitive.iconButtonSize }
}
