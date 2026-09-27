import XCTest
@testable import ShareBarCore

/// Decode tests read the on-disk fixture (`Fixtures/state.json`, hand-written from the spec's
/// JSON example) and assert on its *shape*: one snapshot share, one live share, one own-host
/// share, one `.md` share rendered to `.html`, plus an unknown top-level field. TASK-005 will
/// overwrite that file with real `share state` output; every assertion here still holds as
/// long as the real output keeps at least one row of each category, so none of it hardcodes
/// the fixture's specific ids.
final class SnapshotDecodeTests: XCTestCase {
    func testDecodesTopLevelFieldsAndIgnoresTheUnknownExtraField() throws {
        // The fixture carries an extra top-level "cloudflared_version" field with no matching
        // property; a successful decode here is the proof it was ignored rather than failing.
        let snapshot = try loadFixtureSnapshot()

        XCTAssertEqual(snapshot.schema, 1)
        XCTAssertEqual(snapshot.state, "serving")
        XCTAssertTrue(snapshot.ready)
        XCTAssertEqual(snapshot.mode, "named")
        XCTAssertEqual(snapshot.host, "s.han.ws")
        XCTAssertFalse(snapshot.hosts.isEmpty)
        XCTAssertTrue(snapshot.servesHere)
        XCTAssertTrue(snapshot.service)
        XCTAssertNil(snapshot.skipped)
    }

    func testFixtureCoversOneShareOfEachRequiredCategory() throws {
        let snapshot = try loadFixtureSnapshot()

        XCTAssertGreaterThanOrEqual(snapshot.shares.count, 3)
        for share in snapshot.shares {
            XCTAssertFalse(share.id.isEmpty)
            XCTAssertFalse(share.url.isEmpty)
        }

        XCTAssertTrue(snapshot.shares.contains { $0.kind == "snapshot" }, "expected a snapshot share")
        XCTAssertTrue(snapshot.shares.contains { $0.kind == "live" }, "expected a live share")
        XCTAssertTrue(snapshot.shares.contains { $0.ownHost != nil }, "expected an own-host share")
        XCTAssertTrue(
            snapshot.shares.contains { $0.name.hasSuffix(".md") && $0.url.hasSuffix(".html") },
            "expected a .md share rendered to .html"
        )
    }

    func testDecodesANonZeroSkippedCountAlongsideOneShare() throws {
        // The spec's "skipped" field is present only when non-zero (malformed index rows the
        // state loop dropped); this is a minimal inline snapshot rather than the shared
        // fixture, since that fixture always decodes with no skipped rows.
        let json = """
        {
          "schema": 1,
          "state": "serving",
          "ready": true,
          "mode": "named",
          "host": "s.han.ws",
          "hosts": "hans-air-m4",
          "serves_here": true,
          "service": true,
          "skipped": 2,
          "shares": [
            {
              "id": "abc123",
              "name": "notes.txt",
              "url": "https://s.han.ws/abc123/notes.txt",
              "kind": "snapshot",
              "own_host": null,
              "expires": 0
            }
          ]
        }
        """
        let snapshot = try JSONDecoder().decode(Snapshot.self, from: Data(json.utf8))

        XCTAssertEqual(snapshot.skipped, 2)
        XCTAssertEqual(snapshot.shares.count, 1)
    }

    func testFixtureBuildsAWorkingMenuModel() throws {
        // Not a MenuModel-rules test (see MenuModelHeaderTests / RowAndModelRulesTests for
        // those); just confirms the decoded fixture flows end to end into a model.
        let snapshot = try loadFixtureSnapshot()
        let model = MenuModel(snapshot: snapshot, failure: nil, now: Date())

        XCTAssertEqual(model.rows.count, snapshot.shares.count)
        XCTAssertEqual(model.more, 0)
    }
}
