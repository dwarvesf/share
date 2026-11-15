import Foundation

/// The two system appearances the Share Bar draws in.
public enum Appearance: CaseIterable, Sendable {
    case light, dark
}

/// One sRGB color, 0 to 255 per channel. Plain numbers so the contrast rules are
/// unit-testable without AppKit; the views turn it into a `Color` at the edge.
public struct RGB: Sendable, Equatable {
    public let red: Double
    public let green: Double
    public let blue: Double

    public init(red: Double, green: Double, blue: Double) {
        self.red = red
        self.green = green
        self.blue = blue
    }

    /// `"#1d1d1f"` or `"1d1d1f"`.
    public init(hex: String) {
        let digits = hex.hasPrefix("#") ? String(hex.dropFirst()) : hex
        let value = UInt32(digits, radix: 16) ?? 0
        self.init(
            red: Double((value >> 16) & 0xff),
            green: Double((value >> 8) & 0xff),
            blue: Double(value & 0xff)
        )
    }

    /// WCAG 2.x relative luminance.
    public var luminance: Double {
        func linear(_ channel: Double) -> Double {
            let c = channel / 255
            return c <= 0.03928 ? c / 12.92 : pow((c + 0.055) / 1.055, 2.4)
        }
        return 0.2126 * linear(red) + 0.7152 * linear(green) + 0.0722 * linear(blue)
    }

    /// WCAG contrast ratio, 1 to 21, symmetric.
    public func contrast(with other: RGB) -> Double {
        let a = luminance
        let b = other.luminance
        return (max(a, b) + 0.05) / (min(a, b) + 0.05)
    }

    /// This color at `alpha` over an opaque `backdrop`: what a tinted chip really shows.
    public func composited(alpha: Double, over backdrop: RGB) -> RGB {
        RGB(
            red: red * alpha + backdrop.red * (1 - alpha),
            green: green * alpha + backdrop.green * (1 - alpha),
            blue: blue * alpha + backdrop.blue * (1 - alpha)
        )
    }
}

/// A value the system supplies for both appearances itself (system label and surface
/// colors): the same object in both palettes, so dark mode never overrides it.
public struct Adaptive: Sendable, Equatable {
    public let light: RGB
    public let dark: RGB

    public init(light: String, dark: String) {
        self.light = RGB(hex: light)
        self.dark = RGB(hex: dark)
    }

    public func value(_ appearance: Appearance) -> RGB {
        appearance == .light ? light : dark
    }
}

/// The five state hues of the semantic tier. Each shows with a symbol and a word beside
/// it; the fill is a chip background and a dot, the ink is what text and glyphs use.
public enum StateTone: CaseIterable, Sendable {
    case attention, error, quiet, info, ok
}

/// Tier 1: the system's own colors and the fixed metrics. Identical in both palettes.
public struct PrimitiveTokens: Sendable, Equatable {
    public let label = Adaptive(light: "#1d1d1f", dark: "#f5f5f7")
    public let labelSecondary = Adaptive(light: "#5f5f64", dark: "#b0b0b6")
    /// Placeholder and age text. The prototype's `#7a7a80` and `#8a8a8f` measure 3.92 and
    /// 4.39 against the window, short of 4.5, so both are darkened a step; see the
    /// implementation notes.
    public let labelTertiary = Adaptive(light: "#6b6b70", dark: "#919196")
    public let labelDimmed = Adaptive(light: "#66666b", dark: "#9a9aa0")
    public let window = Adaptive(light: "#f5f5f7", dark: "#26262a")
    public let field = Adaptive(light: "#ffffff", dark: "#1e1e21")

    public let titleSize = 15.0
    public let bodySize = 13.0
    public let monoSize = 12.0
    public let metaSize = 11.0
    public let buttonRadius = 6.0
    public let rowRadius = 7.0
    public let chipRadius = 4.0
    public let minRowHeight = 40.0
    public let iconButtonSize = 26.0

    public init() {}
}

/// Tier 2: what a state means. Dark mode overrides this tier and nothing else.
public struct SemanticTokens: Sendable, Equatable {
    public let attention: RGB
    public let attentionInk: RGB
    public let error: RGB
    public let errorInk: RGB
    public let quiet: RGB
    public let quietInk: RGB
    public let info: RGB
    public let infoInk: RGB
    public let ok: RGB
    /// The focus ring is the info hue, brightened in dark.
    public let focus: RGB
    /// The share of the state hue a chip background keeps.
    public let chipOpacity: Double
    public let toastBackground: RGB
    public let toastForeground: RGB
    public let toastAction: RGB
    /// Row hover, pressed and selected tints: the label color at this opacity.
    public let hoverOpacity = 0.06
    public let pressedOpacity = 0.10
    public let selectionOpacity = 0.08

    public func fill(_ tone: StateTone) -> RGB {
        switch tone {
        case .attention: return attention
        case .error: return error
        case .quiet: return quiet
        case .info: return info
        case .ok: return ok
        }
    }

    /// The ink: text and glyphs of a tone. `ok` has no ink of its own: it marks a dot
    /// beside the word "Online" in the label color.
    public func ink(_ tone: StateTone) -> RGB? {
        switch tone {
        case .attention: return attentionInk
        case .error: return errorInk
        case .quiet: return quietInk
        case .info: return infoInk
        case .ok: return nil
        }
    }
}

/// Tier 3: parts built from the two below. No value of its own.
public struct ComponentTokens: Sendable, Equatable {
    public let palette: Palette

    /// `chip-bg`: the state hue at the chip opacity over the window.
    public func chipBackground(_ tone: StateTone) -> RGB {
        palette.semantic.fill(tone).composited(
            alpha: palette.semantic.chipOpacity,
            over: palette.primitive.window.value(palette.appearance)
        )
    }

    /// `chip-fg`: the tone's ink; `ok` falls back to the label color.
    public func chipForeground(_ tone: StateTone) -> RGB {
        palette.semantic.ink(tone) ?? palette.primitive.label.value(palette.appearance)
    }

    public var toastBackground: RGB { palette.semantic.toastBackground }
    public var toastForeground: RGB { palette.semantic.toastForeground }
    public var toastAction: RGB { palette.semantic.toastAction }
}

/// One pair of colors the contrast rule checks, with the minimum its role needs.
public struct ContrastPair: Sendable {
    public enum Role: Sendable {
        case text // 4.5:1
        case glyph // 3:1: symbols and the ink of a chip's mark
        case chip // 4.5:1 for the chip's text on its tinted background
        case focus // 3:1

        public var minimum: Double {
            switch self {
            case .text, .chip: return 4.5
            case .glyph, .focus: return 3.0
            }
        }
    }

    public let name: String
    public let foreground: RGB
    public let background: RGB
    public let role: Role

    public var ratio: Double { foreground.contrast(with: background) }
}

/// A palette for one appearance: the shared primitive tier, that appearance's semantic
/// tier, and the component tier built from them.
public struct Palette: Sendable, Equatable {
    public let appearance: Appearance
    public let primitive: PrimitiveTokens
    public let semantic: SemanticTokens

    public var component: ComponentTokens { ComponentTokens(palette: self) }

    /// Every pair the accessibility targets name: body text on the window and the field,
    /// each tone's ink on the window and on its own chip, the focus ring on both
    /// surfaces. The raw state fills are chip backgrounds and dots that always sit
    /// beside a word, so they are not glyph pairs.
    public var contrastPairs: [ContrastPair] {
        let window = primitive.window.value(appearance)
        let field = primitive.field.value(appearance)
        var pairs: [ContrastPair] = []
        let texts: [(String, Adaptive)] = [
            ("label", primitive.label), ("label-secondary", primitive.labelSecondary),
            ("label-tertiary", primitive.labelTertiary), ("label-dimmed", primitive.labelDimmed),
        ]
        for (name, color) in texts {
            pairs.append(ContrastPair(name: "\(name) on window", foreground: color.value(appearance), background: window, role: .text))
            pairs.append(ContrastPair(name: "\(name) on field", foreground: color.value(appearance), background: field, role: .text))
        }
        for tone in StateTone.allCases {
            guard let ink = semantic.ink(tone) else { continue }
            pairs.append(ContrastPair(name: "\(tone) ink on window", foreground: ink, background: window, role: .glyph))
            pairs.append(ContrastPair(name: "\(tone) ink on chip", foreground: ink, background: component.chipBackground(tone), role: .chip))
        }
        pairs.append(ContrastPair(name: "info on window", foreground: semantic.info, background: window, role: .glyph))
        pairs.append(ContrastPair(name: "focus on window", foreground: semantic.focus, background: window, role: .focus))
        pairs.append(ContrastPair(name: "focus on field", foreground: semantic.focus, background: field, role: .focus))
        pairs.append(ContrastPair(name: "toast text", foreground: semantic.toastForeground, background: semantic.toastBackground, role: .text))
        pairs.append(ContrastPair(name: "toast action", foreground: semantic.toastAction, background: semantic.toastBackground, role: .text))
        return pairs
    }
}

public enum Tokens {
    public static let primitive = PrimitiveTokens()

    public static let lightSemantic = SemanticTokens(
        attention: RGB(hex: "#ff9500"), attentionInk: RGB(hex: "#8a4b00"),
        error: RGB(hex: "#ff3b30"), errorInk: RGB(hex: "#a3190f"),
        quiet: RGB(hex: "#8e8e93"), quietInk: RGB(hex: "#4a4a4f"),
        info: RGB(hex: "#0060df"), infoInk: RGB(hex: "#0050b8"),
        ok: RGB(hex: "#28a745"), focus: RGB(hex: "#0060df"),
        chipOpacity: 0.14,
        toastBackground: RGB(hex: "#1e1e20"), toastForeground: RGB(hex: "#f5f5f7"), toastAction: RGB(hex: "#8cc4ff")
    )

    public static let darkSemantic = SemanticTokens(
        attention: RGB(hex: "#ff9f0a"), attentionInk: RGB(hex: "#ffc266"),
        error: RGB(hex: "#ff453a"), errorInk: RGB(hex: "#ff9a93"),
        quiet: RGB(hex: "#98989d"), quietInk: RGB(hex: "#d1d1d6"),
        info: RGB(hex: "#0a6fe0"), infoInk: RGB(hex: "#8cc4ff"),
        ok: RGB(hex: "#30d158"), focus: RGB(hex: "#4c9bff"),
        chipOpacity: 0.24,
        toastBackground: RGB(hex: "#f0f0f2"), toastForeground: RGB(hex: "#1d1d1f"), toastAction: RGB(hex: "#0050b8")
    )

    /// Dark is the light palette with the semantic tier swapped; the primitive tier is
    /// the very same value.
    public static func palette(_ appearance: Appearance) -> Palette {
        Palette(
            appearance: appearance,
            primitive: primitive,
            semantic: appearance == .light ? lightSemantic : darkSemantic
        )
    }
}
