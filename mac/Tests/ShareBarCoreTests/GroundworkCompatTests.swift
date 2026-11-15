import XCTest
@testable import ShareBarCore

/// CP-01 (state groundwork): today's types decode a `share state` carrying the additive keys
/// `codes_v`, `cloud_error_code`, `role`, `tier`, and `ops`; every other field decodes as it
/// does without them, and `role`, `tier` and `ops` decode as optional keys (SPEC-010 G11a).
/// A profile that moved away reads `not_setup`, which renders neutral with Set Up, never
/// "Update Share Bar" or "Error: state not readable".
final class GroundworkCompatTests: XCTestCase {
    /// `Fixtures/state.json` plus every new key, with `change` applied last.
    private func groundworkState(_ change: (inout [String: Any]) -> Void = { _ in }) throws -> Data {
        guard let url = Bundle.module.url(forResource: "state", withExtension: "json") else {
            throw NSError(domain: "GroundworkCompatTests", code: 1, userInfo: [NSLocalizedDescriptionKey: "fixture not found"])
        }
        var object = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any])
        object["codes_v"] = 1
        object["cloud_error_code"] = "cloud_token_missing"
        object["role"] = "tenant_origin"
        object["tier"] = "t1"
        object["ops"] = [
            [
                "verb": "setup-r2", "step": 13, "of": 16, "name": "route", "alive": false,
                "rerun": "share setup s.example.test --r2 --bucket b",
                "rerun_argv": ["setup", "s.example.test", "--r2", "--bucket", "b"],
                "rollback": "share setup s.example.test --no-r2",
                "rollback_argv": ["setup", "s.example.test", "--no-r2"],
            ],
            ["verb": "?", "alive": false],
        ]
        change(&object)
        return try JSONSerialization.data(withJSONObject: object)
    }

    func testTodaysSnapshotDecodesTheNewKeysUnchanged() throws {
        let extended = try JSONDecoder().decode(Snapshot.self, from: groundworkState())
        let base = try loadFixtureSnapshot()
        XCTAssertEqual(extended.shares, base.shares, "every existing field decodes as before")
        XCTAssertEqual(extended.state, base.state)
        XCTAssertEqual(extended.ready, base.ready)
        XCTAssertEqual(extended.hosts, base.hosts)
        XCTAssertEqual(extended.role, "tenant_origin")
        XCTAssertEqual(extended.tier, "t1")
        XCTAssertEqual(extended.ops?.count, 2, "the unreadable-journal placeholder decodes too")
        XCTAssertEqual(extended.ops?.first?.rerunArgv, ["setup", "s.example.test", "--r2", "--bucket", "b"])
        XCTAssertEqual(
            Health.of(makeEntry(name: "p", state: extended)), Health.of(makeEntry(name: "p", state: base)),
            "health derives the same from a state with the new keys"
        )
    }

    func testAMigratedProfileIsNotSetUpAndNeutral() throws {
        let data = try groundworkState { object in
            object["state"] = "not_setup"
            object["ready"] = false
            object["role"] = "migrated"
            object.removeValue(forKey: "tier")
        }
        let entry = ProfileEntry(name: "old", state: try JSONDecoder().decode(Snapshot.self, from: data), error: nil)
        XCTAssertEqual(Health.of(entry), .notSetUp)
        XCTAssertTrue(Health.of(entry).isNeutral)
    }

    func testAProfilesListingWithTheNewKeysHasNoUpdateOrError() throws {
        let state = try XCTUnwrap(String(data: groundworkState(), encoding: .utf8))
        let listing = Data(#"{"schema":1,"profiles":[{"name":"default","state":\#(state)}]}"#.utf8)
        let snapshot = try JSONDecoder().decode(ProfilesSnapshot.self, from: listing)
        let entry = try XCTUnwrap(snapshot.profiles.first)
        XCTAssertNil(entry.error, "no Update Share Bar, no decode error")
        XCTAssertNotEqual(Health.of(entry), .error)
    }
}
