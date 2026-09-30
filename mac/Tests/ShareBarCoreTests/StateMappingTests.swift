import XCTest
@testable import ShareBarCore

/// `ProfilesSnapshot.from(_:)` maps one `profiles --json` `CLIResult` to a decoded
/// `ProfilesSnapshot` or a `Failure`. These are the CLI-result-shaped inputs; header text
/// for each `Failure` case is covered in `MenuModelHeaderTests`.
final class StateMappingTests: XCTestCase {
    func testCLINotFoundSentinelMapsToCliNotFoundFailure() {
        // The exact sentinel CLI.run returns when CLI.locate finds nothing.
        let result = CLIResult(status: 127, stdout: "", stderr: "share: CLI not found", timedOut: false)

        XCTAssertEqual(ProfilesSnapshot.from(result), .failure(.cliNotFound))
    }

    func testExitOneWithHelpBannerMapsToOldCLIFailure() {
        let helpText = "share: publish snapshots of local files or folders at https://<your-host>/<id>/<name>,\n"
        let result = CLIResult(status: 1, stdout: helpText, stderr: "", timedOut: false)

        XCTAssertEqual(ProfilesSnapshot.from(result), .failure(.oldCLI))
    }

    func testTSVOnExitZeroMapsToOldCLIFailure() {
        // A CLI from before this spec ignores --json and prints the TSV listing: exit 0
        // with stdout that does not start with `{`.
        let result = CLIResult(status: 0, stdout: "default\tnot_setup\t-\ndfoundation\tserving\ts.d.foundation\n", stderr: "", timedOut: false)

        XCTAssertEqual(ProfilesSnapshot.from(result), .failure(.oldCLI))
    }

    func testValidJSONOnExitZeroDecodesToSnapshot() {
        let json = """
        {"schema":1,"profiles":[{"name":"default","state":{"schema":1,"state":"stopped",
         "ready":false,"mode":"named","host":null,"hosts":"","serves_here":false,
         "service":false,"access_pending":0,"shares":[]}}]}
        """
        let result = CLIResult(status: 0, stdout: json, stderr: "", timedOut: false)

        guard case .success(let snapshot) = ProfilesSnapshot.from(result) else {
            return XCTFail("expected a decoded snapshot")
        }
        XCTAssertEqual(snapshot.profiles[0].state?.state, "stopped")
    }

    func testJqMissingStderrLineMapsToOtherFailureWithSharePrefix() {
        // A bash "command not found" error has no "share: " prefix of its own; the header
        // composes it: "share: " + the last non-empty stderr line.
        let result = CLIResult(status: 127, stdout: "", stderr: "bin/share: line 42: jq: command not found\n", timedOut: false)

        XCTAssertEqual(ProfilesSnapshot.from(result), .failure(.other("share: bin/share: line 42: jq: command not found")))
    }

    func testDieStderrLineAlreadyPrefixedIsNotDoublePrefixed() {
        // bin/share's own die() already writes "share: <msg>"; the header must not add a
        // second "share: " in front of it.
        let result = CLIResult(status: 1, stdout: "", stderr: "share: no such id foo\n", timedOut: false)

        XCTAssertEqual(ProfilesSnapshot.from(result), .failure(.other("share: no such id foo")))
    }

    func testLastNonEmptyStderrLineIsPickedOverTrailingBlankLines() {
        let result = CLIResult(status: 1, stdout: "", stderr: "first\nsecond\n\n", timedOut: false)

        XCTAssertEqual(ProfilesSnapshot.from(result), .failure(.other("share: second")))
    }

    func testEmptyStderrFallsBackToShareExitedN() {
        let result = CLIResult(status: 2, stdout: "", stderr: "", timedOut: false)

        XCTAssertEqual(ProfilesSnapshot.from(result), .failure(.other("share exited 2")))
    }

    func testBraceThatDoesNotDecodeOnExitZeroIsAnOtherFailure() {
        let result = CLIResult(status: 0, stdout: "{not json", stderr: "", timedOut: false)

        XCTAssertEqual(ProfilesSnapshot.from(result), .failure(.other("share exited 0")))
    }
}
