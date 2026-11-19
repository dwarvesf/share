import XCTest
@testable import ShareBarCore

/// SPEC-009 TASK-4b10: publish and drop in.
final class PublishFlowTests: XCTestCase {
    private let t0 = Date(timeIntervalSince1970: 1_800_000_000)
    private let file = "/tmp/plan.pdf"

    func testProgressLinesMoveThePublishingEntrysStep() throws {
        var state = PopoverState()
        state = state.reduce(.dragEnter).state
        state = state.reduce(.drop(file: file, of: 0)).state
        XCTAssertEqual(state.publishing, [Publish(file: file, step: 0, of: 0)])
        var buffer = ProgressScanner()
        let stream = "{\"progress\":{\"verb\":\"add\",\"step\":1,\"of\":3,\"name\":\"stage\"}}\n{\"progress\":{\"verb\":\"add\",\"step\":2,\"of\":3,\"name\":\"upload\"}}\n"
        // The stream arrives in arbitrary chunks: a line split across two chunks still parses once.
        let chunks = [String(stream.prefix(40)), String(stream.dropFirst(40))]
        for chunk in chunks {
            for line in buffer.feed(chunk) {
                if let event = PublishProgress.event(file: file, line: line) { state = state.reduce(event).state }
            }
        }
        XCTAssertEqual(state.publishing, [Publish(file: file, step: 2, of: 3)])
        let row = UploadRow(publish: state.publishing[0], stepName: "upload")
        XCTAssertEqual(row.title, "plan.pdf")
        XCTAssertEqual(row.meta, "Step 2 of 3 · Uploading")
        XCTAssertEqual(try XCTUnwrap(row.fraction), 2.0 / 3.0, accuracy: 0.001)
        XCTAssertEqual(UploadRow(publish: Publish(file: file, step: 0, of: 0), stepName: nil).meta, "Starting…")
        XCTAssertNil(PublishProgress.event(file: file, line: "{\"progress\":{\"verb\":\"setup\",\"step\":1,\"of\":9,\"name\":\"check\"}}"),
                     "another verb's line moves nothing")
        XCTAssertNil(PublishProgress.event(file: file, line: "share: something"), "a plain line is not progress")
        // Output of the other stream landing between two chunks does not break a progress object.
        var scanner = ProgressScanner()
        let object = "{\"progress\":{\"verb\":\"add\",\"step\":3,\"of\":3,\"name\":\"row\"}}"
        XCTAssertEqual(scanner.feed("noise {\"progress\":{\"verb\":\"a"), [])
        XCTAssertEqual(scanner.feed("dd\",\"step\":3,\"of\":3,\"name\":\"row\"}}\nhttps://s.test/x\n"), [object])
        XCTAssertEqual(scanner.feed("https://s.test/y\n"), [], "a link on stdout is never a progress object")
    }

    func testADropWithNoTenantIsRefusedWithTheFirstRunPanel() {
        let first = PopoverState(mode: .firstRun)
        let entered = first.reduce(.dragEnter).state
        XCTAssertEqual(entered.mode, .firstRun, "no tenant, no drop target")
        let dropped = entered.reduce(.drop(file: file, of: 0))
        XCTAssertEqual(dropped.state.mode, .firstRun)
        XCTAssertEqual(dropped.state.publishing, [], "nothing is published")
        XCTAssertEqual(dropped.effects, [.reveal], "the popover opens on the first-run panel")
        XCTAssertEqual(first.reduce(.publishStarted(file: file)).effects, [.reveal], "a picked file with no tenant is refused the same way")
        XCTAssertEqual(first.reduce(.publishStarted(file: file)).state.publishing, [])
    }

    func testAPickedFileStartsAPublishInAnyMode() {
        for mode in [PopoverState.Mode.list(scope: .mine, query: ""), .issues] {
            let started = PopoverState(mode: mode).reduce(.publishStarted(file: file)).state
            XCTAssertEqual(started.mode, mode)
            XCTAssertEqual(started.publishing, [Publish(file: file, step: 0, of: 0)])
            XCTAssertEqual(started.reduce(.publishStarted(file: file)).state.publishing.count, 1, "the same file is not listed twice")
        }
    }

    func testSuccessCopiesTheLinkAndFailureShowsTheSentenceAndNext() {
        let ok = PublishOutcome.result(status: 0, stdout: "added\nhttps://s.test/a1b2c3/plan.pdf\n", stderr: "", fallbackURL: nil)
        XCTAssertEqual(ok, .copied(url: "https://s.test/a1b2c3/plan.pdf"))
        XCTAssertEqual(PublishOutcome.result(status: 0, stdout: "", stderr: "", fallbackURL: "https://s.test/zz/x"), .copied(url: "https://s.test/zz/x"))
        let json = "share: the bucket refused the upload\n{\"error\":{\"code\":\"upload_failed\",\"message\":\"the bucket refused the upload\",\"next\":\"share status\"}}\n"
        XCTAssertEqual(PublishOutcome.result(status: 1, stdout: "", stderr: json, fallbackURL: nil),
                       .failed(sentence: "Couldn't publish: the bucket refused the upload Next: share status"))
        XCTAssertEqual(PublishOutcome.result(status: 1, stdout: "", stderr: "share: disk full\n", fallbackURL: nil),
                       .failed(sentence: "Couldn't publish: disk full"))
        XCTAssertEqual(PublishOutcome.result(status: 7, stdout: "", stderr: "", fallbackURL: nil), .failed(sentence: "Couldn't publish: handout exited 7"))
        // The finish copies the link and clears the placeholder; an empty link copies nothing.
        var state = PopoverState(publishing: [Publish(file: file, step: 3, of: 3)])
        let done = state.reduce(.publishFinished(file: file, result: ok, now: t0))
        XCTAssertEqual(done.effects, [.copy("https://s.test/a1b2c3/plan.pdf")])
        XCTAssertEqual(done.state.publishing, [])
        state = PopoverState(publishing: [Publish(file: file, step: 3, of: 3)])
        XCTAssertEqual(state.reduce(.publishFinished(file: file, result: .copied(url: ""), now: t0)).effects, [])
    }

    func testTheDropOverlayNamesTheHostAndTheStorage() {
        let machine = DropOverlayModel(host: "s.han.ws", storedOn: DropOverlayModel.storedOn(makeSnapshot()))
        XCTAssertEqual(machine.headline, "Release to share on s.han.ws")
        XCTAssertEqual(machine.detail, "Stored on this Mac. Copies the link when done.")
        let cloud = makeSnapshot(r2: true, storageDefault: "cloud")
        XCTAssertEqual(DropOverlayModel.storedOn(cloud), "the cloud")
        XCTAssertEqual(DropOverlayModel.storedOn(makeSnapshot(r2: true, storageDefault: "local")), "this Mac")
        XCTAssertEqual(DropOverlayModel.storedOn(nil), "this Mac")
    }
}
