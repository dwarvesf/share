import AppKit
import XCTest
@testable import ShareBarCore

/// The type/storage/link symbol table: every value maps to the spec's symbol name and
/// accessibility word, and every named symbol resolves on the test host.
final class RowGlyphsTests: XCTestCase {
    func testTypeGlyphsMatchTheTable() {
        let cases: [(String, RowGlyph)] = [
            ("pdf", RowGlyph(symbol: "doc.richtext", word: "PDF")),
            ("image", RowGlyph(symbol: "photo", word: "image")),
            ("video", RowGlyph(symbol: "film", word: "video")),
            ("audio", RowGlyph(symbol: "waveform", word: "audio")),
            ("folder", RowGlyph(symbol: "folder", word: "folder")),
            ("site", RowGlyph(symbol: "globe", word: "site")),
            ("markdown", RowGlyph(symbol: "doc.plaintext", word: "Markdown")),
            ("archive", RowGlyph(symbol: "archivebox", word: "archive")),
            ("text", RowGlyph(symbol: "doc.text", word: "text")),
            ("other", RowGlyph(symbol: "doc", word: "file")),
        ]
        for (value, glyph) in cases {
            XCTAssertEqual(RowGlyphs.type(value), glyph, value)
        }
    }

    func testUnknownAndMissingTypesFallBackToDoc() {
        for value in [nil, "other", "spreadsheet", "PDF", ""] {
            XCTAssertEqual(RowGlyphs.type(value), RowGlyph(symbol: "doc", word: "file"), value ?? "nil")
        }
    }

    func testStorageGlyphsMatchTheTable() {
        XCTAssertEqual(RowGlyphs.storage("machine"), RowGlyph(symbol: "desktopcomputer", word: "on this tenant's machine"))
        XCTAssertEqual(RowGlyphs.storage("cloud"), RowGlyph(symbol: "cloud", word: "in the cloud"))
    }

    func testMissingAndUnknownStorageShowNoBadge() {
        for value in [nil, "local", "bucket", ""] {
            XCTAssertNil(RowGlyphs.storage(value), value ?? "nil")
        }
    }

    func testLinkGlyphsMatchTheTable() {
        XCTAssertEqual(RowGlyphs.link("live"), RowGlyph(symbol: "dot.radiowaves.right", word: "live server"))
        XCTAssertEqual(RowGlyphs.link("snapshot"), RowGlyph(symbol: "doc.on.doc", word: "snapshot"))
        XCTAssertEqual(RowGlyphs.link("whatever"), RowGlyph(symbol: "doc.on.doc", word: "snapshot"))
    }

    func testLockGlyph() {
        XCTAssertEqual(RowGlyphs.lock, RowGlyph(symbol: "lock.fill", word: "login required"))
    }

    func testEverySymbolResolvesAsAnSFSymbol() {
        let names = [
            "doc.richtext", "photo", "film", "waveform", "folder", "globe",
            "doc.plaintext", "archivebox", "doc.text", "doc",
            "desktopcomputer", "cloud", "doc.on.doc", "dot.radiowaves.right",
            "lock.fill",
        ]
        for name in names {
            XCTAssertNotNil(
                NSImage(systemSymbolName: name, accessibilityDescription: "test"),
                "\(name) must resolve on the package minimum (macOS 13)"
            )
        }
    }
}
