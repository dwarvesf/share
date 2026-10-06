import Foundation

/// One row marker: the SF Symbol name the app resolves, plus the word accessibility reads
/// for it.
public struct RowGlyph: Sendable, Equatable {
    public let symbol: String
    public let word: String

    public init(symbol: String, word: String) {
        self.symbol = symbol
        self.word = word
    }
}

/// The mapping from a share's `type`, `storage`, and `kind` to row markers, held as plain
/// strings so every rule is unit-testable without AppKit. The app resolves the names with
/// `NSImage(systemSymbolName:)` and falls back to no image when one fails.
public enum RowGlyphs {
    /// The file-type marker. `other`, an unknown value, and a missing `type` (a row from
    /// an older CLI) all take the plain `doc` file marker.
    public static func type(_ value: String?) -> RowGlyph {
        switch value {
        case "pdf": return RowGlyph(symbol: "doc.richtext", word: "PDF")
        case "image": return RowGlyph(symbol: "photo", word: "image")
        case "video": return RowGlyph(symbol: "film", word: "video")
        case "audio": return RowGlyph(symbol: "waveform", word: "audio")
        case "folder": return RowGlyph(symbol: "folder", word: "folder")
        case "site": return RowGlyph(symbol: "globe", word: "site")
        case "markdown": return RowGlyph(symbol: "doc.plaintext", word: "Markdown")
        case "archive": return RowGlyph(symbol: "archivebox", word: "archive")
        case "text": return RowGlyph(symbol: "doc.text", word: "text")
        default: return RowGlyph(symbol: "doc", word: "file")
        }
    }

    /// The storage badge; nil when the row carries no `storage` or an unknown one, so the
    /// row simply shows no badge.
    public static func storage(_ value: String?) -> RowGlyph? {
        switch value {
        case "machine": return RowGlyph(symbol: "desktopcomputer", word: "on this tenant's machine")
        case "cloud": return RowGlyph(symbol: "cloud", word: "in the cloud")
        default: return nil
        }
    }

    /// The link-type marker. Anything that is not `live` reads as a snapshot.
    public static func link(_ kind: String) -> RowGlyph {
        switch kind {
        case "live": return RowGlyph(symbol: "dot.radiowaves.right", word: "live server")
        default: return RowGlyph(symbol: "doc.on.doc", word: "snapshot")
        }
    }

    /// The gate marker on a gated row (`access` set); it sits in the same trailing group
    /// as the badges.
    public static let lock = RowGlyph(symbol: "lock.fill", word: "login required")
}
