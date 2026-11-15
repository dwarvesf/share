import XCTest
@testable import ShareBarCore

/// TASK-4b3: the popover reducer. One row per row of the spec's transition table, and the
/// rows the AC names. Effects are values: a test asserts what was asked for, never what ran.
final class PopoverStateTests: XCTestCase {
    private let t0 = Date(timeIntervalSince1970: 1_800_000_000)
    private let rm = ["--profile", "p", "rm", "a1"]

    private func list(scope: LinkScope = .mine, query: String = "") -> PopoverState {
        PopoverState(mode: .list(scope: scope, query: query))
    }

    // MARK: the transition table

    func testEveryRowOfTheTransitionTableRuns() {
        XCTAssertFalse(PopoverState.transitions.isEmpty)
        for row in PopoverState.transitions {
            let (after, _) = row.from.reduce(row.event)
            XCTAssertEqual(after.mode.kind, row.to, "\(row.mode) \(row.column): \(row.clause) -> \(row.to)")
        }
    }

    func testTheReducersTableEqualsTheSpecTable() throws {
        let spec = try specModeTable()
        XCTAssertEqual(Set(spec.keys), Set(PopoverState.Kind.allCases.map(\.rawValue)), "the spec's modes are the reducer's modes")
        for kind in PopoverState.Kind.allCases {
            let cells = try XCTUnwrap(spec[kind.rawValue], kind.rawValue)
            let ours = try XCTUnwrap(PopoverState.specTable[kind], kind.rawValue)
            XCTAssertEqual(cells.entered, ours.entered, "\(kind) Entered by")
            XCTAssertEqual(cells.left, ours.left, "\(kind) Left by")
            let rows = PopoverState.transitions.filter { $0.mode == kind }
            XCTAssertTrue(rows.contains { $0.column == .entered }, "\(kind) has an entry transition")
            XCTAssertTrue(rows.contains { $0.column == .left }, "\(kind) has an exit transition")
            for row in rows {
                let cell = row.column == .entered ? cells.entered : cells.left
                XCTAssertTrue(cell.contains(row.clause), "\(kind): '\(row.clause)' is words of the spec's cell '\(cell)'")
            }
        }
    }

    /// Reads SPEC-009's `### Components & states` mode table from the repo.
    private func specModeTable() throws -> [String: (entered: String, left: String)] {
        var url = URL(fileURLWithPath: #filePath)
        for _ in 0..<4 { url.deleteLastPathComponent() }
        let text = try String(contentsOf: url.appendingPathComponent("docs/specs/SPEC-009-multi-member.md"), encoding: .utf8)
        var table: [String: (entered: String, left: String)] = [:]
        var inTable = false
        for line in text.split(separator: "\n", omittingEmptySubsequences: false) {
            if line.hasPrefix("| Mode | Entered by | Left by |") { inTable = true; continue }
            guard inTable else { continue }
            guard line.hasPrefix("|") else { break }
            if line.hasPrefix("|---") { continue }
            let cells = line.split(separator: "|", omittingEmptySubsequences: false).dropFirst().dropLast()
                .map { $0.trimmingCharacters(in: .whitespaces) }
            guard cells.count == 3 else { continue }
            let name = cells[0].replacingOccurrences(of: "`", with: "")
            let kind = name.split(separator: "(").first.map(String.init) ?? name
            table[kind] = (cells[1], cells[2])
        }
        return table
    }

    // MARK: undo

    func testUndoDeadlineEmitsRunOnce() {
        var state = list()
        state = state.reduce(.remove(action: .remove, ids: ["a1"], argv: rm, now: t0)).state
        XCTAssertEqual(state.pending.count, 1)
        XCTAssertEqual(state.pending[0].deadline, t0.addingTimeInterval(Undo.window))
        let early = state.reduce(.tick(now: t0.addingTimeInterval(Undo.window - 0.1)))
        XCTAssertEqual(early.effects, [], "before the deadline nothing runs")
        let due = early.state.reduce(.tick(now: t0.addingTimeInterval(Undo.window)))
        XCTAssertEqual(due.effects, [.run(rm)])
        XCTAssertTrue(due.state.pending.isEmpty)
        let again = due.state.reduce(.tick(now: t0.addingTimeInterval(60)))
        XCTAssertEqual(again.effects, [], "the verb never runs twice")
    }

    func testUndoOrCommandZEmitsNoRun() {
        var state = list().reduce(.remove(action: .remove, ids: ["a1"], argv: rm, now: t0)).state
        let undone = state.reduce(.undo)
        XCTAssertEqual(undone.effects, [])
        XCTAssertTrue(undone.state.pending.isEmpty)
        state = undone.state
        XCTAssertEqual(state.reduce(.tick(now: t0.addingTimeInterval(600))).effects, [], "an undone Remove never emits run")
        XCTAssertEqual(state.reduce(.close).effects, [])
        XCTAssertEqual(list().reduce(.undo).effects, [], "undo with nothing pending is a no-op")
    }

    func testCloseDuringUndoEmitsRunOnce() {
        let state = list().reduce(.remove(action: .remove, ids: ["a1"], argv: rm, now: t0)).state
        let closed = state.reduce(.close)
        XCTAssertEqual(closed.effects, [.run(rm)])
        XCTAssertTrue(closed.state.pending.isEmpty)
        XCTAssertEqual(closed.state.reduce(.close).effects, [], "quit after close runs nothing more")
        XCTAssertEqual(closed.state.reduce(.tick(now: t0.addingTimeInterval(600))).effects, [])
    }

    func testASecondDeleteKeepsBothUndos() {
        let rmB = ["--profile", "p", "rm", "b2"]
        var state = list()
        state = state.reduce(.remove(action: .remove, ids: ["a1"], argv: rm, now: t0)).state
        state = state.reduce(.remove(action: .revoke, ids: ["b2"], argv: rmB, now: t0.addingTimeInterval(2))).state
        XCTAssertEqual(state.pending.map(\.ids), [["a1"], ["b2"]])
        XCTAssertEqual(state.pending.map(\.action), [.remove, .revoke])
        let undone = state.reduce(.undo).state
        XCTAssertEqual(undone.pending.map(\.ids), [["a1"]], "undo cancels the newest only")
        let both = state.reduce(.close)
        XCTAssertEqual(both.effects, [.run(rm), .run(rmB)], "close commits every pending undo, oldest first")
    }

    func testABulkRemoveIsOneUndo() {
        let bulk = ["--profile", "p", "rm", "a1", "b2", "c3"]
        let state = list().reduce(.remove(action: .bulkRemove, ids: ["a1", "b2", "c3"], argv: bulk, now: t0)).state
        XCTAssertEqual(state.pending.count, 1)
        XCTAssertEqual(state.reduce(.tick(now: t0.addingTimeInterval(7))).effects, [.run(bulk)])
    }

    func testUndoIsHandledInEveryMode() {
        let modes: [PopoverState.Mode] = [
            .firstRun, .list(scope: .team, query: "x"), .issues,
            .dropTarget(prev: .list(scope: .mine, query: "")),
            .menu(id: "a1", prev: .list(scope: .mine, query: "")),
            .quickLook(id: "a1", prev: .list(scope: .mine, query: "")),
        ]
        for mode in modes {
            var state = PopoverState(mode: mode)
            state = state.reduce(.remove(action: .remove, ids: ["a1"], argv: rm, now: t0)).state
            XCTAssertEqual(state.pending.count, 1, "\(mode.kind)")
            XCTAssertEqual(state.mode, mode, "an undo is not a mode: \(mode.kind) is unchanged")
            XCTAssertEqual(state.reduce(.tick(now: t0.addingTimeInterval(7))).effects, [.run(rm)], "\(mode.kind)")
        }
    }

    // MARK: drag, hotkey, list

    func testDropLeaveReturnsToThePreviousState() {
        let start = list(scope: .team, query: "plan")
        let over = start.reduce(.dragEnter).state
        XCTAssertEqual(over.mode, .dropTarget(prev: start.mode))
        XCTAssertEqual(over.reduce(.dragLeave).state, start)
        let dropped = over.reduce(.drop(file: "/tmp/a.pdf", of: 1)).state
        XCTAssertEqual(dropped.mode, start.mode, "release returns to the previous mode")
        XCTAssertEqual(dropped.publishing, [Publish(file: "/tmp/a.pdf", step: 0, of: 1)])
        let fromIssues = PopoverState(mode: .issues).reduce(.dragEnter).state
        XCTAssertEqual(fromIssues.reduce(.dragLeave).state.mode, .issues)
        XCTAssertEqual(PopoverState(mode: .firstRun).reduce(.dragEnter).state.mode, .firstRun, "no tenant, no drop target")
        XCTAssertEqual(over.reduce(.dragEnter).state, over, "a second enter changes nothing")
    }

    func testHotkeyFromIssuesLandsInListWithSearchFocused() {
        let result = PopoverState(mode: .issues).reduce(.hotkey)
        XCTAssertEqual(result.state.mode, .list(scope: .mine, query: ""))
        XCTAssertEqual(result.effects, [.focus("search")])
        let fromList = list(scope: .team, query: "plan").reduce(.hotkey)
        XCTAssertEqual(fromList.state.mode, .list(scope: .team, query: "plan"), "the list keeps its scope and query")
        XCTAssertEqual(fromList.effects, [.focus("search")])
        let fromMenu = PopoverState(mode: .menu(id: "a1", prev: .list(scope: .team, query: "plan"))).reduce(.hotkey)
        XCTAssertEqual(fromMenu.state.mode, .list(scope: .team, query: "plan"))
        XCTAssertEqual(PopoverState(mode: .firstRun).reduce(.hotkey).effects, [])
    }

    func testListSearchScopeAndModeEdges() {
        var state = list()
        state = state.reduce(.setQuery("plan")).state
        state = state.reduce(.setScope(.team)).state
        XCTAssertEqual(state.mode, .list(scope: .team, query: "plan"))
        XCTAssertEqual(PopoverState(mode: .issues).reduce(.setQuery("x")).state.mode, .issues, "typing outside the list does nothing")
        XCTAssertEqual(state.reduce(.showIssues).state.mode, .issues)
        XCTAssertEqual(PopoverState(mode: .issues).reduce(.showIssues).state.mode, .issues)
        XCTAssertEqual(PopoverState(mode: .firstRun).reduce(.showIssues).state.mode, .firstRun)
        XCTAssertEqual(list().reduce(.profilesChanged(hasRole: true)).state.mode, list().mode, "a list stays a list")
        XCTAssertEqual(list(scope: .team).reduce(.close).state.mode, .list(scope: .team, query: ""), "close keeps the scope and clears the query")
        XCTAssertEqual(PopoverState(mode: .firstRun).reduce(.close).state.mode, .firstRun)
    }

    func testMenuAndQuickLookReturnToTheList() {
        let start = list(scope: .team, query: "plan")
        let menu = start.reduce(.openMenu(id: "a1")).state
        XCTAssertEqual(menu.reduce(.menuClosed).state, start)
        XCTAssertEqual(menu.reduce(.escape).state, start)
        let look = start.reduce(.toggleQuickLook(id: "a1")).state
        XCTAssertEqual(look.reduce(.toggleQuickLook(id: "a1")).state, start)
        let copy = look.reduce(.quickLookCopy(url: "https://x/a1"))
        XCTAssertEqual(copy.state, start)
        XCTAssertEqual(copy.effects, [.copy("https://x/a1")])
        let open = look.reduce(.quickLookOpen(url: "https://x/a1"))
        XCTAssertEqual(open.effects, [.open("https://x/a1")])
        XCTAssertEqual(PopoverState(mode: .issues).reduce(.openMenu(id: "a1")).state.mode, .issues, "rows exist only in the list")
        XCTAssertEqual(start.reduce(.copyLink(url: "https://x/a1")).effects, [.copy("https://x/a1")])
    }

    // MARK: publishing

    func testPublishFailurePutsTheSentenceInTheFooterAndKeepsTheMode() {
        var state = list(scope: .team, query: "q")
        state = state.reduce(.dragEnter).state
        state = state.reduce(.drop(file: "/tmp/a.pdf", of: 3)).state
        state = state.reduce(.publishStep(file: "/tmp/a.pdf", step: 2, of: 3)).state
        XCTAssertEqual(state.publishing, [Publish(file: "/tmp/a.pdf", step: 2, of: 3)])
        let sentence = "Couldn't publish: the bucket refused the upload. Try again, or run `share status`."
        let failed = state.reduce(.publishFinished(file: "/tmp/a.pdf", result: .failed(sentence: sentence), now: t0))
        XCTAssertEqual(failed.state.footer, Footer(text: sentence, kind: .failure))
        XCTAssertEqual(failed.state.mode, .list(scope: .team, query: "q"))
        XCTAssertTrue(failed.state.publishing.isEmpty)
        XCTAssertEqual(failed.effects, [])
        XCTAssertEqual(failed.state.reduce(.tick(now: t0.addingTimeInterval(600))).state.footer?.text, sentence, "a failure stays until replaced")
    }

    func testPublishSuccessCopiesTheLinkAndShowsAToastThatLapses() {
        var state = list()
        state.publishing = [Publish(file: "/tmp/a.pdf", step: 3, of: 3)]
        let done = state.reduce(.publishFinished(file: "/tmp/a.pdf", result: .copied(url: "https://x/a1"), now: t0))
        XCTAssertEqual(done.effects, [.copy("https://x/a1")])
        XCTAssertEqual(done.state.footer?.kind, .toast)
        XCTAssertEqual(done.state.footer?.expires, t0.addingTimeInterval(PopoverState.toastSeconds))
        XCTAssertNotNil(done.state.reduce(.tick(now: t0.addingTimeInterval(3))).state.footer)
        XCTAssertNil(done.state.reduce(.tick(now: t0.addingTimeInterval(4))).state.footer)
    }

    func testMenuAndQuickLookDuringPublishingKeepTheUpload() {
        var state = list()
        state = state.reduce(.dragEnter).state
        state = state.reduce(.drop(file: "/tmp/a.pdf", of: 2)).state
        let upload = state.publishing
        let menu = state.reduce(.openMenu(id: "a1")).state
        XCTAssertEqual(menu.publishing, upload)
        let stepped = menu.reduce(.publishStep(file: "/tmp/a.pdf", step: 1, of: 2)).state
        XCTAssertEqual(stepped.mode.kind, .menu, "a step event never leaves the open menu")
        XCTAssertEqual(stepped.publishing, [Publish(file: "/tmp/a.pdf", step: 1, of: 2)])
        let closed = stepped.reduce(.menuClosed).state
        XCTAssertEqual(closed.publishing, stepped.publishing)
        let look = closed.reduce(.toggleQuickLook(id: "a1")).state
        XCTAssertEqual(look.publishing, stepped.publishing)
        let finished = look.reduce(.publishFinished(file: "/tmp/a.pdf", result: .copied(url: "https://x/a1"), now: t0))
        XCTAssertEqual(finished.state.mode.kind, .quickLook, "the finish lands in whatever mode is open")
        XCTAssertEqual(finished.effects, [.copy("https://x/a1")])
        XCTAssertEqual(menu.reduce(.close).state.publishing, upload, "close keeps a running upload")
    }

    func testFirstRunEntersAndLeaves() {
        let first = list().reduce(.profilesChanged(hasRole: false)).state
        XCTAssertEqual(first.mode, .firstRun)
        XCTAssertEqual(first.reduce(.profilesChanged(hasRole: true)).state.mode, .list(scope: .mine, query: ""))
    }
}

final class BulkRemoveCloseTests: XCTestCase {
    func testPopoverCloseKeepsABulkRemoveAndTheWindowCloseCommitsOnlyIt() {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        var state = PopoverState()
        state = state.reduce(.remove(action: .remove, ids: ["a"], argv: ["rm", "a"], now: now)).state
        state = state.reduce(.remove(action: .bulkRemove, ids: ["b", "c"], argv: ["rm", "b", "c"], now: now)).state
        let closed = state.reduce(.popoverClosed)
        XCTAssertEqual(closed.effects, [.run(["rm", "a"])])
        XCTAssertEqual(closed.state.pending.map(\.ids), [["b", "c"]])
        let window = closed.state.reduce(.commitBulk)
        XCTAssertEqual(window.effects, [.run(["rm", "b", "c"])])
        XCTAssertEqual(window.state.pending, [])
        XCTAssertEqual(window.state.mode, closed.state.mode, "the window never resets the popover")
    }
}
