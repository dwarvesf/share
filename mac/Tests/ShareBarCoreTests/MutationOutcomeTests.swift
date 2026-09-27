import XCTest
@testable import ShareBarCore

/// TASK-017's decision logic: which alert a finished mutating verb calls for, the id diff
/// an add uses to find its new share, the folder-publish confirm text, and the header
/// override / Stop Waiting constants. AppKit only presents these; every rule here is
/// exercised without a menu or an `NSAlert`.
final class MutationOutcomeTests: XCTestCase {
    // MARK: - alert(for:warningShareID:notServingHere:)

    func testNonZeroExitAlwaysWinsAsAFailureAlertRegardlessOfWarningOrNotServingHere() {
        let result = CLIResult(status: 1, stdout: "", stderr: "share: no share with id abc123", timedOut: false)
        let alert = MutationOutcome.alert(for: result, warningShareID: "abc123", notServingHere: true)
        XCTAssertEqual(alert, MutationAlert(kind: .failure, message: "share: no share with id abc123"))
    }

    func testFailureWithNoStderrFallsBackToShareExitedN() {
        let result = CLIResult(status: 2, stdout: "", stderr: "", timedOut: false)
        let alert = MutationOutcome.alert(for: result, warningShareID: nil, notServingHere: false)
        XCTAssertEqual(alert, MutationAlert(kind: .failure, message: "share exited 2"))
    }

    func testFailureStderrKeepsASingleSharePrefix() {
        let result = CLIResult(status: 1, stdout: "", stderr: "jq: command not found", timedOut: false)
        let alert = MutationOutcome.alert(for: result, warningShareID: nil, notServingHere: false)
        XCTAssertEqual(alert?.message, "share: jq: command not found")
    }

    func testPrivateWarningOnExitZeroNamesTheShareToRemove() {
        let result = CLIResult(
            status: 0,
            stdout: "https://s.han.ws/abc123/notes.txt",
            stderr: "share: WARNING: this comes from the PRIVATE repo han/notes and is now public to anyone with the link (share rm abc123 to undo)",
            timedOut: false
        )
        let alert = MutationOutcome.alert(for: result, warningShareID: "abc123", notServingHere: false)
        XCTAssertEqual(alert?.kind, .privateWarning)
        XCTAssertEqual(alert?.removeShareID, "abc123")
        XCTAssertTrue(alert?.message.hasPrefix("share: WARNING") == true)
    }

    func testPrivateWarningNeedsAWarningShareIDEvenWithAMatchingStderrLine() {
        let result = CLIResult(status: 0, stdout: "", stderr: "share: WARNING: private repo", timedOut: false)
        let alert = MutationOutcome.alert(for: result, warningShareID: nil, notServingHere: false)
        XCTAssertNil(alert, "no share to point the Remove button at, so no alert to show")
    }

    func testPrivateWarningWinsOverNotServingHereWhenBothApply() {
        let result = CLIResult(status: 0, stdout: "", stderr: "share: WARNING: private repo", timedOut: false)
        let alert = MutationOutcome.alert(for: result, warningShareID: "abc123", notServingHere: true)
        XCTAssertEqual(alert?.kind, .privateWarning)
    }

    func testNotServingHereWhenExitZeroWithNoWarningAndFlagSet() {
        let result = CLIResult(status: 0, stdout: "https://<no-hostname>/abc123/notes.txt", stderr: "", timedOut: false)
        let alert = MutationOutcome.alert(for: result, warningShareID: nil, notServingHere: true)
        XCTAssertEqual(alert?.kind, .notServingHere)
        XCTAssertNil(alert?.removeShareID)
    }

    func testNoAlertOnAPlainSuccessfulVerb() {
        let result = CLIResult(status: 0, stdout: "ok", stderr: "", timedOut: false)
        XCTAssertNil(MutationOutcome.alert(for: result, warningShareID: "abc123", notServingHere: false))
    }

    func testAStderrLineThatMerelyContainsWarningButDoesNotStartWithItIsNotThePrivateWarning() {
        let result = CLIResult(status: 0, stdout: "", stderr: "share: skipped 1 symlink(s), no WARNING here", timedOut: false)
        XCTAssertNil(MutationOutcome.alert(for: result, warningShareID: "abc123", notServingHere: false))
    }

    // MARK: - newShare(before:after:)

    func testNewShareFindsTheOneIDNotInTheBeforeSet() {
        let before: Set<String> = ["a", "b"]
        let after = [makeShare(id: "c"), makeShare(id: "a"), makeShare(id: "b")]
        XCTAssertEqual(MutationOutcome.newShare(before: before, after: after)?.id, "c")
    }

    func testNewSharePicksTheNewestWhenMoreThanOneIDIsNew() {
        // Shares are newest-first; a batch's most recent add is what a caller wants.
        let before: Set<String> = ["a"]
        let after = [makeShare(id: "c"), makeShare(id: "b"), makeShare(id: "a")]
        XCTAssertEqual(MutationOutcome.newShare(before: before, after: after)?.id, "c")
    }

    func testNewShareIsNilWhenNothingIsNew() {
        let before: Set<String> = ["a", "b"]
        let after = [makeShare(id: "a"), makeShare(id: "b")]
        XCTAssertNil(MutationOutcome.newShare(before: before, after: after))
    }

    func testNewShareIsNilOnAnEmptyBeforeSetPickingTheirWholeListsFirstEntry() {
        // An empty before-set (e.g. a first-ever add) still resolves to the newest share.
        let after = [makeShare(id: "only")]
        XCTAssertEqual(MutationOutcome.newShare(before: [], after: after)?.id, "only")
    }

    // MARK: - FolderConfirm

    func testFolderConfirmTextNamesTheFolderAndThePeriod() {
        XCTAssertEqual(
            FolderConfirm.text(name: "team-guide"),
            "Publish the folder team-guide at a public link for 30 days?"
        )
    }

    // MARK: - StopWaiting

    func testStopWaitingDelayIsSixtySeconds() {
        XCTAssertEqual(StopWaiting.delay, 60)
    }

    func testStopWaitingConfirmTextNamesHalfPublishedAndTheStartingCase() {
        XCTAssertTrue(StopWaiting.confirmText.contains("half-published"))
        XCTAssertTrue(StopWaiting.confirmText.contains("If sharing was starting"))
    }

    // MARK: - CLIResult.lastErrorLine

    func testLastErrorLineIsSharedByStateFailureMapping() {
        // Exercises the extracted helper directly (Snapshot.from's own test already covers
        // it end to end via StateMappingTests); this guards the extraction didn't change
        // the rule the mutation alerts rely on.
        let result = CLIResult(status: 1, stdout: "", stderr: "line one\n\nline three\n", timedOut: false)
        XCTAssertEqual(result.lastErrorLine, "share: line three")
    }
}
