import XCTest
@testable import ShareBarCore

/// SPEC-009 TASK-4b21, TASK-4b22 and TASK-4b23: app states, keyboard and VoiceOver, running ops.
final class AppStateTests: XCTestCase {
    private func tenant(_ role: String?, compat: CompatInfo? = nil) -> ProfileEntry {
        makeEntry(name: "p", state: makeSnapshot(host: "s.t", role: role, tier: "t1", compat: compat))
    }

    func testLoadingBeforeAnyProfilesResult() {
        XCTAssertEqual(AppState.of(profiles: nil, failure: nil), .loading)
        XCTAssertEqual(AppState.loading.panel?.title, "Loading")
        XCTAssertNil(AppState.loading.panel?.button)
    }

    func testCLIMissingOffersTheInstallCommand() {
        let state = AppState.of(profiles: nil, failure: .cliNotFound)
        XCTAssertEqual(state, .cliMissing)
        XCTAssertEqual(state.panel?.title, "Install the handout command")
        XCTAssertEqual(state.panel?.button, "Copy install command")
        XCTAssertEqual(state.panel?.copy, "brew install dwarvesf/tools/handout")
    }

    func testCLITooOldFromAnOldHelpBannerOrCompat() {
        let banner = AppState.of(profiles: nil, failure: .oldCLI)
        XCTAssertEqual(banner, .cliTooOld(minimum: "0.10"))
        XCTAssertEqual(banner.panel?.title, "Update handout to 0.10")
        XCTAssertEqual(banner.panel?.button, "Copy upgrade command")
        let compat = CompatInfo(cli: "0.9.0", worker: "5 abc", status: "cli_below_min", minCLI: "0.11.0")
        let below = AppState.of(profiles: makeProfiles([tenant("member", compat: compat)]), failure: nil)
        XCTAssertEqual(below, .cliTooOld(minimum: "0.11"))
    }

    func testOneTenantBelowMinDoesNotHideTheOthers() {
        let compat = CompatInfo(cli: "0.9.0", worker: "5 abc", status: "cli_below_min", minCLI: "0.10.0")
        let mixed = makeProfiles([makeEntry(name: "a", state: makeSnapshot(role: "member", compat: compat)), tenant("tenant_origin")])
        XCTAssertEqual(AppState.of(profiles: mixed, failure: nil), .ready)
    }

    func testNoTenantWhenEveryProfileHasNoRole() {
        let state = AppState.of(profiles: makeProfiles([tenant("none"), tenant("none")]), failure: nil)
        XCTAssertEqual(state, .noTenant)
        XCTAssertNil(state.panel, "the first-run panel is its own view")
        XCTAssertEqual(AppState.of(profiles: makeProfiles([tenant("tenant_origin")]), failure: nil), .ready)
    }

    // MARK: TASK-4b22

    func testRowLabelsCarryTheNameAndTheMetaLineForEveryLinkState() {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let state = makeSnapshot(host: "s.t", role: "tenant_origin", tier: "t2")
        for raw in ["live", "offline", "paused", "expired", "revoked", "shadowed", "gate_missing"] {
            let share = makeShare(id: "x1", name: "deck.pdf", url: "u", expires: 4_102_444_800, storage: "machine", by: "Mac", linkState: raw)
            let row = PopoverViewModel.row(for: share, profile: "p", state: state, role: .tenantOrigin, scope: .mine, now: now)
            XCTAssertTrue(row.accessibilityLabel.hasPrefix("deck.pdf, "), "\(raw): \(row.accessibilityLabel)")
            if raw != "live" {
                let word = LinkState(raw: raw).stateWord.word
                XCTAssertTrue(row.accessibilityLabel.contains(word), "\(raw) says its state word: \(row.accessibilityLabel)")
            }
        }
    }

    func testRowsExposeTheMenuItemsAsAccessibilityActions() {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let state = makeSnapshot(host: "s.t", servesHere: true, role: "origin", tier: "t0")
        let share = makeShare(id: "x1", name: "a", url: "u", expires: 4_102_444_800, storage: "machine", linkState: "live")
        let row = PopoverViewModel.row(for: share, profile: "p", state: state, role: .origin, scope: .mine, now: now)
        XCTAssertEqual(RowAccessibility.actions(for: row), RowMenu.items(for: row))
        XCTAssertTrue(RowAccessibility.actions(for: row).contains(.copyLink))
    }

    func testFocusRestoresByIDAfterARefreshThatReordersRows() {
        let before = ["a", "b", "c", "d"]
        XCTAssertEqual(RowFocus.moved(from: "a", step: 1, ids: before), "b")
        XCTAssertEqual(RowFocus.moved(from: "b", step: 1, ids: before), "c", "Arrow Down twice lands on the third row")
        let after = ["d", "c", "a", "b"]
        XCTAssertEqual(RowFocus.restored(previous: "c", previousIndex: 2, ids: after), "c")
        XCTAssertEqual(RowFocus.restored(previous: "z", previousIndex: 2, ids: after), "a", "a vanished row falls to its slot")
        XCTAssertEqual(RowFocus.restored(previous: "z", previousIndex: 9, ids: after), "b", "clamped")
        XCTAssertNil(RowFocus.restored(previous: nil, previousIndex: nil, ids: after))
        XCTAssertNil(RowFocus.restored(previous: "a", previousIndex: 0, ids: []))
        XCTAssertEqual(RowFocus.moved(from: nil, step: -1, ids: before), "d")
        XCTAssertEqual(RowFocus.moved(from: "d", step: 1, ids: before), "d", "clamped at the end")
    }

    func testTheStatusItemLabelCarriesTheCount() {
        XCTAssertEqual(PopoverViewModel.statusItemLabel(count: 0), "Handout Bar")
        XCTAssertEqual(PopoverViewModel.statusItemLabel(count: 1), "Handout Bar, 1 need a look")
        XCTAssertEqual(PopoverViewModel.statusItemLabel(count: 4), "Handout Bar, 4 need a look")
    }

    // MARK: TASK-4b23

    func testWorkingLineForAnAddFromTheTerminal() {
        let alive = OpInfo(verb: "add", step: 3, of: 6, name: "upload", alive: true)
        let stopped = OpInfo(verb: "setup", step: 2, of: 5, name: "dns", alive: false)
        XCTAssertEqual(WorkingLine.text(for: makeEntry(name: "p", state: makeSnapshot(ops: [stopped, alive]))), "Working: add (3/6)")
        XCTAssertNil(WorkingLine.text(for: makeEntry(name: "p", state: makeSnapshot(ops: [stopped]))))
        XCTAssertNil(WorkingLine.text(for: makeEntry(name: "p", state: makeSnapshot(ops: [OpInfo(verb: "?", alive: true)]))))
        XCTAssertEqual(WorkingLine.text(for: makeEntry(name: "p", state: makeSnapshot(ops: [OpInfo(verb: "add", alive: true)]))), "Working: add")
        XCTAssertNil(WorkingLine.text(for: nil))
    }

    func testTheStopWaitingCopyForAnAdd() {
        XCTAssertEqual(StopWaiting.addConfirmText, "The add stops where it is; handout prune cleans up what it left.")
    }

    func testEveryCodeTheAppMapsToASheet() {
        let members = RefusalSheet.from(code: "members_present", message: "m", next: nil, host: "s.t")
        XCTAssertEqual(members.action, .openMembers)
        let busy = RefusalSheet.from(code: "member_busy", message: "pausing an is still running", next: "share member ls", host: "s.t")
        XCTAssertEqual(busy.action, .openMembers)
        XCTAssertEqual(busy.sentence, "pausing an is still running")
        let old = RefusalSheet.from(code: "cli_below_min", message: "", next: nil, host: "s.t")
        XCTAssertEqual(old.title, "Update handout to 0.10")
        XCTAssertEqual(old.action, .copyCommand("brew upgrade dwarvesf/tools/handout"))
        for code in ["invite_unknown_or_used", "invite_expired", "invite_tampered", "member_changed", "invite_unavailable"] {
            let sheet = RefusalSheet.from(code: code, message: "cli text", next: "share x", host: "s.t")
            XCTAssertEqual(sheet.title, "Can't join", code)
            XCTAssertTrue(sheet.sentence.hasSuffix("Ask your admin for a new code."), "\(code): \(sheet.sentence)")
        }
        XCTAssertEqual(RefusalSheet.from(code: "port_busy", message: "Port 8787 is in use", next: nil, host: "h").title, "Can't do that")
    }

    func testAPublishFailureShowsItsSentenceWithTheNextStepAsACopyableLine() {
        let result = CLIResult(status: 1, stdout: "", stderr: "share: the bucket refused the upload\n{\"error\":{\"code\":\"upload_refused\",\"message\":\"the bucket refused the upload\",\"next\":\"share status\"}}\n", timedOut: false)
        let alert = MutationOutcome.alert(for: result, warningShareID: nil, notServingHere: false)
        XCTAssertEqual(alert?.message, "the bucket refused the upload")
        XCTAssertEqual(alert?.next, "share status")
    }
}
