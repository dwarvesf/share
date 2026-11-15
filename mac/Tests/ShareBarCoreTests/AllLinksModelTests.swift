import XCTest
@testable import ShareBarCore

/// SPEC-009 TASK-4b20: the All links window's model.
final class AllLinksModelTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_800_000_000)
    private let far = 4_102_444_800
    private var past: Int { Int(now.timeIntervalSince1970) - 86_400 }

    private func entry(role: String = "tenant_origin") -> ProfileEntry {
        let shares = [
            makeShare(id: "own001", name: "notes.txt", url: "https://s.t/own001/notes.txt", expires: far, storage: "machine", by: "Mac-mini", linkState: "live"),
            makeShare(id: "cld001", name: "hero.png", url: "https://s.t/cld001/hero.png", expires: far, storage: "cloud", by: "Linh", origin: "m-linh-5e6f7a8b", linkState: "live", views: 3),
            makeShare(id: "mac001", name: "deck.pdf", url: "https://s.t/mac001/deck.pdf", expires: far, storage: "machine", by: "An's MacBook", origin: "m-an-1a2b3c4d", linkState: "offline", views: 9),
            makeShare(id: "old001", name: "invoice.pdf", url: "https://s.t/old001/invoice.pdf", expires: past, storage: "cloud", linkState: "expired", views: 12),
            makeShare(id: "pau001", name: "page.html", url: "https://s.t/pau001/page.html", expires: far, storage: "machine", by: "Dung's iMac", origin: "m-dung-9a8b7c6d", linkState: "paused"),
        ]
        return makeEntry(name: "console", state: makeSnapshot(host: "s.console.so", shares: shares, role: role, tier: "t2"))
    }

    private func model(_ state: AllLinksState = AllLinksState(), role: String = "tenant_origin") -> AllLinksModel {
        AllLinksModel(entry: entry(role: role), state: state, now: now)
    }

    func testTabCounts() {
        let m = model()
        XCTAssertEqual(m.counts[.all], 5)
        XCTAssertEqual(m.counts[.live], 2)
        XCTAssertEqual(m.counts[.needsLook], 2)
        XCTAssertEqual(m.counts[.expired], 1)
        XCTAssertEqual(model(AllLinksState(tab: .expired)).rows.map(\.id), ["old001"])
        XCTAssertEqual(model(AllLinksState(tab: .needsLook)).rows.map(\.id), ["mac001", "pau001"])
        XCTAssertEqual(AllLinksTab.allCases.map(\.title), ["All", "Live", "Needs a look", "Expired"])
    }

    func testViewsOnlyOnCloudRows() {
        let rows = Dictionary(uniqueKeysWithValues: model().all.map { ($0.id, $0.views) })
        XCTAssertEqual(rows["cld001"], 3)
        XCTAssertEqual(rows["old001"], 12)
        XCTAssertNil(rows["mac001"] ?? nil, "a machine row never shows views, even when the CLI sent a number")
        XCTAssertNil(rows["own001"] ?? nil)
    }

    func testExpiredRowsAreDimmedAndCannotCopy() {
        let expired = model().all.first { $0.id == "old001" }!
        XCTAssertTrue(expired.dimmed)
        XCTAssertFalse(expired.canCopy)
        XCTAssertEqual(expired.expires, "Expired")
        XCTAssertEqual(expired.stateWord, "Expired")
        XCTAssertTrue(model().all.first { $0.id == "own001" }!.canCopy)
    }

    func testColumnsNameOwnerLivesOnExpires() {
        let rows = Dictionary(uniqueKeysWithValues: model().all.map { ($0.id, $0) })
        XCTAssertEqual(rows["own001"]?.owner, "You")
        XCTAssertEqual(rows["own001"]?.expires.hasSuffix("d"), true, "time left without the word left")
        XCTAssertEqual(AllLinksModel.expiresText(makeShare(expires: 0), expired: false, now: now), "Never")
        XCTAssertEqual(AllLinksModel.expiresText(makeShare(kind: "live", expires: 0), expired: false, now: now), "Live")
        XCTAssertEqual(rows["mac001"]?.owner, "An")
        XCTAssertEqual(rows["mac001"]?.livesOn, "An's MacBook")
        XCTAssertEqual(rows["mac001"]?.stateWord, "Owner offline")
        XCTAssertEqual(rows["cld001"]?.livesOn, "cloud")
        XCTAssertEqual(rows["pau001"]?.stateWord, "Paused")
    }

    func testSearchMatchesNameOwnerAndMachine() {
        XCTAssertEqual(model(AllLinksState(query: "hero")).rows.map(\.id), ["cld001"])
        XCTAssertEqual(model(AllLinksState(query: "linh")).rows.map(\.id), ["cld001"])
        XCTAssertEqual(model(AllLinksState(query: "macbook")).rows.map(\.id), ["mac001"])
        let none = model(AllLinksState(query: "zzz"))
        XCTAssertEqual(none.rows, [])
        XCTAssertEqual(none.emptyText, "No links match.")
        XCTAssertEqual(model(AllLinksState(tab: .expired, query: "")).emptyText, nil)
    }

    func testBulkCopyJoinsURLsOneperLineAndSkipsExpired() {
        var state = AllLinksState()
        state.selection = ["own001", "cld001", "old001"]
        let m = model(state)
        XCTAssertEqual(m.bulkCopyText, "https://s.t/own001/notes.txt\nhttps://s.t/cld001/hero.png")
        XCTAssertEqual(m.selectedText, "3 selected")
        XCTAssertEqual(AllLinksModel.copiedSentence(2), "Copied 2 links, one per line.")
    }

    func testBulkRemoveArgvRevokesOthersLinks() {
        var state = AllLinksState()
        state.selection = ["own001", "mac001", "cld001"]
        let m = model(state)
        XCTAssertEqual(m.bulkRemoveArgv, ["--profile", "console", "rm", "own001", "cld001", "mac001"], "one rm with every removable id, table order")
        XCTAssertEqual(m.bulkRemoveSentence, "Removed 1 and revoked 2. They stop answering.")
    }

    func testAMemberCannotRemoveAnotherMembersLink() {
        var state = AllLinksState()
        state.selection = ["mac001"]
        XCTAssertNil(model(state, role: "member").bulkRemoveArgv, "a member's selection of someone else's link has nothing to remove")
    }

    func testSelectionMoves() {
        var state = AllLinksState()
        let m = model(state)
        state.toggle("own001")
        XCTAssertEqual(state.selection, ["own001"])
        state.selectAll(m.rows)
        XCTAssertEqual(state.selection.count, 5)
        state.selectAll(m.rows)
        XCTAssertEqual(state.selection, [], "select all again clears")
        state.toggle("own001")
        state.show(.live)
        XCTAssertEqual(state.selection, [], "a tab change clears the selection")
        XCTAssertEqual(state.tab, .live)
    }

    func testFooterCountsLinksAndYours() {
        XCTAssertEqual(model().footer, "5 links · 2 yours · Views are counted for cloud links only")
    }
}
