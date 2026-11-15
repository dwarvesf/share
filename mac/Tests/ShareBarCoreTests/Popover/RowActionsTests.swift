import XCTest
@testable import ShareBarCore

/// SPEC-009 TASK-4b9: the link_state table, the row menu, the undo window.
final class RowActionsTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_800_000_000)
    private let far = 4_102_444_800

    private func row(
        _ linkState: String?, own: Bool = true, role: String = "tenant_origin", servesHere: Bool = true,
        storage: String = "machine", origin: String? = nil, id: String = "c4c2a0", by: String = "Mac-mini"
    ) -> RowModel {
        let share = makeShare(id: id, name: "notes.txt", url: "https://s.test/\(id)/notes.txt", expires: far, storage: storage, by: by,
                              origin: origin, linkState: linkState)
        let snapshot = makeSnapshot(host: "s.test", servesHere: servesHere, shares: [share], role: role)
        return PopoverViewModel.row(for: share, profile: "console", state: snapshot, role: Role(raw: role), scope: .mine, now: now)
            .with(own: own)
    }

    func testRowMenuItemsPerLinkStateAndRole() {
        struct Case {
            let name: String
            let row: RowModel
            let items: [RowAction]
        }
        let cases = [
            Case(name: "own live link on this Mac", row: row("live"),
                 items: [.copyLink, .openInBrowser, .showInFinder, .refresh, .remove]),
            Case(name: "own offline link", row: row("offline"),
                 items: [.copyLink, .openInBrowser, .showInFinder, .refresh, .remove]),
            Case(name: "own paused link", row: row("paused"),
                 items: [.copyLink, .openInBrowser, .showInFinder, .refresh, .remove]),
            Case(name: "own cloud link", row: row("live", storage: "cloud"),
                 items: [.copyLink, .openInBrowser, .remove]),
            Case(name: "own link on a Mac that does not serve", row: row("live", servesHere: false),
                 items: [.copyLink, .openInBrowser, .remove]),
            Case(name: "own expired link", row: row("expired"), items: [.showInFinder, .refresh, .remove]),
            Case(name: "own revoked link", row: row("revoked"), items: [.remove]),
            Case(name: "another member's link as admin", row: row("live", own: false, origin: "m-an-1a2b3c4d"),
                 items: [.copyLink, .openInBrowser, .revoke]),
            Case(name: "another member's link as a member", row: row("live", own: false, role: "member", origin: "m-an-1a2b3c4d"),
                 items: [.copyLink, .openInBrowser]),
            Case(name: "another member's revoked link as admin", row: row("revoked", own: false, origin: "m-an-1a2b3c4d"), items: [.revoke]),
        ]
        for c in cases {
            XCTAssertEqual(RowMenu.items(for: c.row), c.items, c.name)
        }
    }

    func testDestructiveItemIsLastAndRowsWithoutOneHaveNone() {
        for linkState in ["live", "offline", "paused", "expired", "revoked"] {
            let items = RowMenu.items(for: row(linkState))
            XCTAssertEqual(items.last, .remove, linkState)
            XCTAssertEqual(items.filter(\.isDestructive).count, 1)
        }
        XCTAssertEqual(RowAction.remove.title, "Remove link…")
        XCTAssertEqual(RowAction.revoke.title, "Revoke link…")
    }

    func testClickCopiesOrWarnsPerLinkState() {
        let live = LinkClick.outcome(for: row("live"))
        XCTAssertTrue(live.copies)
        XCTAssertEqual(live.message, "Link copied: notes.txt")
        let offline = LinkClick.outcome(for: row("offline", by: "An's MacBook"))
        XCTAssertTrue(offline.copies)
        XCTAssertEqual(offline.message, "Copied. An's MacBook is offline: visitors get a 503 until it is back.")
        let paused = LinkClick.outcome(for: row("paused"))
        XCTAssertTrue(paused.copies)
        XCTAssertEqual(paused.message, "Copied. This member is paused: visitors get a 503.")
        let expired = LinkClick.outcome(for: row("expired"))
        XCTAssertFalse(expired.copies)
        XCTAssertEqual(expired.message, "This link expired, so it no longer answers. Share the file again for a new link.")
        XCTAssertFalse(LinkClick.outcome(for: row("revoked")).copies)
    }

    func testAClickOnAnExpiredRowNeverEmitsACopy() {
        let state = PopoverState()
        let expired = state.clicked(row("expired"), now: now)
        XCTAssertTrue(expired.effects.isEmpty)
        XCTAssertFalse(expired.flash)
        XCTAssertEqual(expired.state.footer?.text, "This link expired, so it no longer answers. Share the file again for a new link.")
        let live = state.clicked(row("live"), now: now)
        XCTAssertEqual(live.effects, [.copy("https://s.test/c4c2a0/notes.txt")])
        XCTAssertTrue(live.flash)
        XCTAssertEqual(live.state.footer?.expires, now.addingTimeInterval(PopoverState.toastSeconds))
    }

    func testRemoveWaitsForTheUndoWindow() throws {
        let r = row("live")
        let removed = try XCTUnwrap(PopoverState().removing(r, now: now))
        XCTAssertEqual(removed.pending.count, 1)
        XCTAssertEqual(removed.footer?.text, "Removed notes.txt. The link stops answering.")
        XCTAssertEqual(removed.footer?.expires, now.addingTimeInterval(6))
        let early = removed.reduce(.tick(now: now.addingTimeInterval(5.9)))
        XCTAssertTrue(early.effects.isEmpty, "nothing runs before the window ends")
        XCTAssertEqual(early.state.pending.count, 1)
        let late = removed.reduce(.tick(now: now.addingTimeInterval(6)))
        XCTAssertEqual(late.effects, [.run(["--profile", "console", "rm", "c4c2a0"])], "exactly one rm")
        XCTAssertTrue(late.state.pending.isEmpty)
        XCTAssertEqual(late.state.reduce(.tick(now: now.addingTimeInterval(20))).effects, [], "never twice")
    }

    func testUndoCancelsTheCLICall() throws {
        let removed = try XCTUnwrap(PopoverState().removing(row("live"), now: now))
        let undone = removed.undone()
        XCTAssertTrue(undone.pending.isEmpty)
        XCTAssertNil(undone.footer)
        XCTAssertEqual(undone.reduce(.tick(now: now.addingTimeInterval(60))).effects, [])
    }

    func testHoldWhileUndoIsFocused() throws {
        let removed = try XCTUnwrap(PopoverState().removing(row("live"), now: now))
        let held = removed.reduce(.holdUndo(held: true, now: now.addingTimeInterval(3))).state
        let during = held.reduce(.tick(now: now.addingTimeInterval(30)))
        XCTAssertTrue(during.effects.isEmpty, "a held undo never runs")
        XCTAssertEqual(during.state.pending.count, 1)
        XCTAssertNotNil(during.state.footer, "and its footer stays")
        let released = during.state.reduce(.holdUndo(held: false, now: now.addingTimeInterval(31))).state
        XCTAssertEqual(released.reduce(.tick(now: now.addingTimeInterval(36))).effects, [], "the window restarts on release")
        XCTAssertEqual(released.reduce(.tick(now: now.addingTimeInterval(37))).effects, [.run(["--profile", "console", "rm", "c4c2a0"])])
    }

    func testClosingDuringTheWindowCommitsOnce() throws {
        let removed = try XCTUnwrap(PopoverState().removing(row("live"), now: now))
        let held = removed.reduce(.holdUndo(held: true, now: now)).state
        let closed = held.reduce(.close)
        XCTAssertEqual(closed.effects, [.run(["--profile", "console", "rm", "c4c2a0"])], "close commits even a held undo")
    }

    func testRevokeArgvForAnotherMembersLink() throws {
        let other = row("live", own: false, origin: "m-an-1a2b3c4d", id: "7f3a21", by: "An's MacBook")
        XCTAssertEqual(LinkRemoval.action(for: other), .revoke)
        XCTAssertEqual(LinkRemoval.argv(for: other), ["--profile", "console", "rm", "7f3a21"])
        XCTAssertEqual(LinkRemoval.footer(for: other), "Revoked notes.txt. It stops answering now; the file stays on An's MacBook.")
        let state = try XCTUnwrap(PopoverState().removing(other, now: now))
        XCTAssertEqual(state.pending.first?.action, .revoke)
        XCTAssertEqual(state.reduce(.tick(now: now.addingTimeInterval(6))).effects, [.run(["--profile", "console", "rm", "7f3a21"])])
    }

    func testTheDeleteKeyOnARowTheMenuDoesNotOfferDoesNothing() {
        let others = row("live", own: false, role: "member", origin: "m-an-1a2b3c4d")
        XCTAssertNil(PopoverState().removing(others, now: now))
    }

    func testASecondDeleteKeepsBothUndos() throws {
        let first = try XCTUnwrap(PopoverState().removing(row("live", id: "aaaaaa"), now: now))
        let second = try XCTUnwrap(first.removing(row("live", id: "bbbbbb"), now: now.addingTimeInterval(1)))
        XCTAssertEqual(second.pending.map(\.ids), [["aaaaaa"], ["bbbbbb"]])
        XCTAssertEqual(second.undone().pending.map(\.ids), [["aaaaaa"]], "undo cancels the newest")
    }
}

extension RowModel {
    /// A copy with `own` replaced, for tests that pin the ownership rule separately.
    func with(own: Bool) -> RowModel {
        RowModel(id: id, profile: profile, title: title, meta: meta, glyph: glyph, state: state, url: url, own: own, machine: machine,
                 storage: storage, isMemberLink: isMemberLink, servesHere: servesHere, isAdmin: isAdmin)
    }
}
