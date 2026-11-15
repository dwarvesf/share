import XCTest
@testable import ShareBarCore

/// SPEC-009 TASK-4b11: drag a row out.
final class DragOutTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_800_000_000)

    private func row(_ linkState: String?, name: String = "plan.pdf") -> RowModel {
        let share = makeShare(id: "c4c2a0", name: name, url: "https://s.test/c4c2a0/\(name)", expires: 4_102_444_800, storage: "machine", linkState: linkState)
        let snapshot = makeSnapshot(host: "s.test", shares: [share], role: "tenant_origin")
        return PopoverViewModel.row(for: share, profile: "console", state: snapshot, role: .tenantOrigin, scope: .mine, now: now)
    }

    func testTheDragItemCarriesTheURLAsUrlAndText() throws {
        let payload = try XCTUnwrap(DragPayload(row: row("live")))
        XCTAssertEqual(payload.url.absoluteString, "https://s.test/c4c2a0/plan.pdf")
        XCTAssertEqual(payload.text, "https://s.test/c4c2a0/plan.pdf")
        let provider = payload.itemProvider()
        XCTAssertTrue(provider.hasItemConformingToTypeIdentifier("public.url"), "carries a URL")
        XCTAssertTrue(provider.hasItemConformingToTypeIdentifier("public.utf8-plain-text"), "carries plain text")
        let text = expectation(description: "text")
        provider.loadObject(ofClass: NSString.self) { object, _ in
            XCTAssertEqual(object as? String, "https://s.test/c4c2a0/plan.pdf")
            text.fulfill()
        }
        let url = expectation(description: "url")
        provider.loadObject(ofClass: NSURL.self) { object, _ in
            XCTAssertEqual((object as? URL)?.absoluteString, "https://s.test/c4c2a0/plan.pdf")
            url.fulfill()
        }
        wait(for: [text, url], timeout: 5)
        for state in ["offline", "paused"] { XCTAssertNotNil(DragPayload(row: row(state)), state) }
        XCTAssertEqual(payload.footerHint, "Drop to paste the link to plan.pdf")
    }

    func testExpiredAndRevokedDoNotDrag() {
        XCTAssertNil(DragPayload(row: row("expired")))
        XCTAssertNil(DragPayload(row: row("revoked")))
    }

    func testAnInternalDragNeverEntersDropTarget() {
        var state = PopoverState()
        state = state.reduce(.dragOutBegan(id: "c4c2a0")).state
        XCTAssertEqual(state.reduce(.dragEnter).state.mode, .list(scope: .mine, query: ""), "the row's own drag over the popover is not a drop")
        XCTAssertEqual(state.reduce(.dragEnter).state, state)
        let ended = state.reduce(.dragOutEnded).state
        XCTAssertNil(ended.draggingOut)
        XCTAssertEqual(ended.reduce(.dragEnter).state.mode.kind, .dropTarget, "an outside drag still enters")
        // A drop target that was open when the drag out began closes.
        let over = PopoverState().reduce(.dragEnter).state
        XCTAssertEqual(over.reduce(.dragOutBegan(id: "c4c2a0")).state.mode, .list(scope: .mine, query: ""))
    }

    func testTheFooterReadsTheHintOnlyWhileARowIsInTheAir() {
        let rows = [row("live")]
        var state = PopoverState()
        XCTAssertNil(state.dragOutHint(rows: rows))
        state = state.reduce(.dragOutBegan(id: "c4c2a0")).state
        XCTAssertEqual(state.dragOutHint(rows: rows), "Drop to paste the link to plan.pdf")
        XCTAssertNil(state.reduce(.dragOutEnded).state.dragOutHint(rows: rows))
        XCTAssertNil(state.dragOutHint(rows: [row("revoked")]), "a row that cannot drag has no hint")
    }
}
