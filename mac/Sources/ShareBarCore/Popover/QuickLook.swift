import Foundation

/// Where a Quick Look preview comes from (SPEC-009 TASK-4b12, DEC-55). Only a row whose bytes
/// sit on this Mac reads a file; nothing else fetches anything.
public enum PreviewSource: Sendable, Equatable {
    /// The served file `pub/<id>/<name>`: `QLPreviewView` draws it.
    case file(path: String)
    /// The served folder `pub/<id>/<name>/`: its entries are listed.
    case folder(path: String)
    /// A port share: `Live server` and what answers on the port.
    case liveServer(port: String?)
    /// Cloud, or another member's machine: the row's glyph and meta line, no fetch.
    case glyph(String)
}

public struct QuickLookModel: Sendable, Equatable {
    public let rowID: String
    public let title: String
    public let url: String
    public let meta: String
    public let source: PreviewSource
    public let closeLabel = "Close"
    public let openTitle = "Open in browser"
    public let copyTitle = "Copy link"
    /// A Quick Look panel is up to 560 pt wide.
    public static let width: CGFloat = 560

    public init(row: RowModel, home: String = NSHomeDirectory(),
                exists: (String) -> Bool = { FileManager.default.fileExists(atPath: $0) },
                isDirectory: (String) -> Bool = {
                    var isDir: ObjCBool = false
                    return FileManager.default.fileExists(atPath: $0, isDirectory: &isDir) && isDir.boolValue
                }) {
        rowID = row.id
        title = row.title
        url = row.url
        // The design's footer always names the owner; the Mine list leaves it off the row.
        var text = row.own && !row.meta.hasPrefix("You") ? (row.meta.isEmpty ? "You" : "You · \(row.meta)") : row.meta
        // A live link with no expiry word never expires: the design's footer says so.
        if row.state == .live, row.glyph != "bolt.horizontal", !text.contains(" left"), !text.contains("views") {
            text += " · never expires"
        }
        meta = text
        source = QuickLookModel.previewSource(for: row, home: home, exists: exists, isDirectory: isDirectory)
    }

    static func previewSource(for row: RowModel, home: String, exists: (String) -> Bool, isDirectory: (String) -> Bool) -> PreviewSource {
        if row.glyph == "bolt.horizontal" { return .liveServer(port: port(in: row.title)) }
        // Cloud bytes and another member's machine are not on this Mac: no read, no fetch.
        let here = row.own && row.servesHere && row.storage != "cloud" && row.state != .revoked
        guard here else { return .glyph(row.glyph) }
        // `pub/<id>` is the served tree: a file share holds `<name>`, a folder share holds `<name>/`.
        // The row title is display text: it names a file only when it is one plain path component.
        guard !row.title.isEmpty, !row.title.contains("/"), row.title != ".", row.title != "..",
              row.id.allSatisfy({ $0.isLetter || $0.isNumber }) else { return .glyph(row.glyph) }
        let path = FinderPath.pub(profile: row.profile, id: row.id, home: home) + "/" + row.title
        guard exists(path) else { return .glyph(row.glyph) }
        return isDirectory(path) ? .folder(path: path) : .file(path: path)
    }

    /// `localhost:3000`, `:3000` or `3000` in a port share's name.
    static func port(in name: String) -> String? {
        let tail = name.split(separator: ":").last.map(String.init) ?? name
        let digits = tail.trimmingCharacters(in: .whitespaces)
        return !digits.isEmpty && digits.allSatisfy(\.isNumber) ? digits : nil
    }

    public var liveDetail: String {
        if case .liveServer(let port) = source {
            return port.map { "Visitors see whatever answers on localhost:\($0) right now." }
                ?? "Visitors see whatever answers on this Mac's port right now."
        }
        return ""
    }
}
