import XCTest
@testable import ShareBarCore

/// SPEC-009 TASK-4b12: Quick Look.
final class QuickLookModelTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_800_000_000)

    private func row(
        id: String = "c4c2a0", name: String = "plan.pdf", kind: String = "snapshot", type: String? = "pdf",
        storage: String = "machine", own: Bool = true, servesHere: Bool = true, origin: String? = nil, linkState: String? = "live"
    ) -> RowModel {
        let share = makeShare(id: id, name: name, url: "https://s.test/\(id)/\(name)", kind: kind, expires: 4_102_444_800, storage: storage,
                              type: type, by: "Mac-mini", origin: origin, linkState: linkState)
        let snapshot = makeSnapshot(host: "s.test", servesHere: servesHere, shares: [share], role: "tenant_origin")
        var model = PopoverViewModel.row(for: share, profile: "console", state: snapshot, role: .tenantOrigin, scope: .mine, now: now)
        if !own {
            model = RowModel(id: model.id, profile: model.profile, title: model.title, meta: model.meta, glyph: model.glyph, state: model.state,
                             url: model.url, own: false, machine: model.machine, storage: model.storage, isMemberLink: true,
                             servesHere: model.servesHere, isAdmin: model.isAdmin)
        }
        return model
    }

    private func source(_ row: RowModel, files: Set<String> = [], dirs: Set<String> = []) -> PreviewSource {
        QuickLookModel(row: row, home: "/Users/h", exists: { files.contains($0) || dirs.contains($0) }, isDirectory: { dirs.contains($0) }).source
    }

    func testPreviewSourcePerRowKind() {
        let pub = "/Users/h/share/profiles/console/pub/c4c2a0/plan.pdf"
        XCTAssertEqual(source(row(), files: [pub]), .file(path: pub), "bytes on this Mac preview pub/<id>/<name>")
        let site = "/Users/h/share/profiles/console/pub/c4c2a0/site"
        XCTAssertEqual(source(row(name: "site", type: "folder"), dirs: [site]), .folder(path: site))
        XCTAssertEqual(source(row(name: "localhost:3000", kind: "live", type: nil)), .liveServer(port: "3000"), "a port share")
        XCTAssertEqual(source(row(name: "demo", kind: "live", type: nil)), .liveServer(port: nil))
        XCTAssertEqual(source(row(storage: "cloud"), files: [pub]), .glyph("doc.text"), "a cloud link never reads a file")
        XCTAssertEqual(source(row(own: false, origin: "m-an-1a2b3c4d"), files: [pub]), .glyph("doc.text"), "another member's machine, no fetch")
        XCTAssertEqual(source(row(servesHere: false), files: [pub]), .glyph("doc.text"), "a Mac that does not serve the tenant")
        XCTAssertEqual(source(row()), .glyph("doc.text"), "the file is gone: the glyph, not an error")
        let model = QuickLookModel(row: row(name: "localhost:3000", kind: "live", type: nil))
        XCTAssertEqual(model.liveDetail, "Visitors see whatever answers on localhost:3000 right now.")
        XCTAssertEqual(model.copyTitle, "Copy link")
        XCTAssertEqual(model.openTitle, "Open in browser")
        XCTAssertEqual(model.url, "https://s.test/c4c2a0/localhost:3000")
        XCTAssertTrue(QuickLookModel(row: row()).meta.hasPrefix("You · "), "an own link's footer names the owner, as the design does")
        XCTAssertFalse(QuickLookModel(row: row(own: false, origin: "m-an-1a2b3c4d")).meta.hasPrefix("You"))
    }

    func testCloseReturnsFocusToTheRowID() {
        let start = PopoverState()
        let look = start.reduceRestoringFocus(.toggleQuickLook(id: "c4c2a0")).state
        XCTAssertEqual(look.mode.kind, .quickLook)
        let url = "https://s.test/c4c2a0/plan.pdf"
        let leaves: [(String, PopoverEvent, [PopoverEffect])] = [
            ("Space", .toggleQuickLook(id: "c4c2a0"), [.focus("c4c2a0")]),
            ("Esc", .escape, [.focus("c4c2a0")]),
            ("Close", .closeQuickLook, [.focus("c4c2a0")]),
            ("Copy link", .quickLookCopy(url: url), [.copy(url), .focus("c4c2a0")]),
            ("Open in browser", .quickLookOpen(url: url), [.open(url), .focus("c4c2a0")]),
            ("the hotkey names its own focus", .hotkey, [.focus("search")]),
        ]
        for (name, event, effects) in leaves {
            let result = look.reduceRestoringFocus(event)
            XCTAssertEqual(result.state.mode.kind, .list, name)
            XCTAssertEqual(result.effects, effects, name)
        }
        XCTAssertEqual(start.reduceRestoringFocus(.copyLink(url: url)).effects, [.copy(url)], "outside Quick Look nothing is added")
        XCTAssertEqual(look.reduceRestoringFocus(.tick(now: now)).effects, [], "an event that stays in Quick Look adds nothing")
    }
}
