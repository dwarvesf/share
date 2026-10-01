import XCTest
@testable import ShareBarCore

/// Decode tests read the on-disk fixtures: `Fixtures/profiles.json`, saved from a real
/// `share profiles --json` run on the Mini (default `not_setup`, `dfoundation` serving a
/// gated share), and `Fixtures/state.json` for the single-state decode. Assertions are on
/// shape, not hardcoded ids.
final class SnapshotDecodeTests: XCTestCase {
    func testDecodesTheProfilesListing() throws {
        let snapshot = try loadFixtureProfiles()

        XCTAssertEqual(snapshot.schema, 1)
        XCTAssertEqual(snapshot.profiles.map(\.name), ["default", "dfoundation"])
        XCTAssertEqual(snapshot.profiles[0].state?.state, "not_setup")
        XCTAssertEqual(snapshot.profiles[1].state?.state, "serving")
        XCTAssertEqual(snapshot.profiles[1].state?.host, "s.d.foundation")
    }

    func testDecodesAccessAndAccessPending() throws {
        let snapshot = try loadFixtureProfiles()

        XCTAssertEqual(snapshot.profiles[1].state?.accessPending, 0)
        let gated = snapshot.profiles[1].state?.shares.first { $0.access != nil }
        XCTAssertEqual(gated?.access, "group:dwarves-ops", "the fixture's gated share decodes its rule")
        let publicShare = try JSONDecoder().decode(
            Share.self,
            from: Data(#"{"id":"a1","name":"n","url":"u","kind":"snapshot","own_host":null,"expires":0}"#.utf8)
        )
        XCTAssertNil(publicShare.access, "a share with no access key decodes as public")
    }

    func testUnknownExtraFieldsAreIgnoredAtEveryLevel() throws {
        let json = """
        {"schema":1,"profiles":[
          {"name":"a","extra":1,"state":{"schema":1,"state":"stopped","ready":false,
            "mode":"named","host":null,"hosts":"","serves_here":false,"service":false,
            "access_pending":0,"extra":2,"shares":[
              {"id":"a1","name":"n","url":"u","kind":"snapshot","own_host":null,"expires":0,"extra":3}
            ]}},
          {"name":"b","error":"bad name","extra":4}
        ],"extra":5}
        """
        let snapshot = try JSONDecoder().decode(ProfilesSnapshot.self, from: Data(json.utf8))

        XCTAssertEqual(snapshot.profiles.count, 2)
        XCTAssertEqual(snapshot.profiles[0].state?.shares.count, 1)
        XCTAssertEqual(snapshot.profiles[1].error, "bad name")
    }

    func testNewerStateSchemaConfinesUpdateShareBarToItsOwnEntry() throws {
        let json = """
        {"schema":1,"profiles":[
          {"name":"a","state":{"schema":2,"state":"serving","shares":[]}},
          {"name":"b","state":{"schema":1,"state":"serving","ready":true,"mode":"named",
            "host":"h.example.com","hosts":"h","serves_here":true,"service":false,
            "access_pending":0,"shares":[]}}
        ]}
        """
        let snapshot = try JSONDecoder().decode(ProfilesSnapshot.self, from: Data(json.utf8))

        XCTAssertEqual(snapshot.profiles[0].error, "Update Share Bar")
        XCTAssertNil(snapshot.profiles[0].state)
        XCTAssertEqual(snapshot.profiles[1].state?.state, "serving", "the good entry is intact")
    }

    func testUnreadableStateIsConfinedToItsOwnEntry() throws {
        let json = """
        {"schema":1,"profiles":[
          {"name":"a","state":{"schema":1,"state":"serving"}},
          {"name":"b","state":{"state":"serving","shares":[]}},
          {"name":"c","state":{"schema":1,"state":"serving","ready":true,"mode":"named",
            "host":"h.example.com","hosts":"h","serves_here":true,"service":false,
            "access_pending":0,"shares":[]}}
        ]}
        """
        let snapshot = try JSONDecoder().decode(ProfilesSnapshot.self, from: Data(json.utf8))

        XCTAssertEqual(snapshot.profiles[0].error, "state not readable", "missing shares")
        XCTAssertEqual(snapshot.profiles[1].error, "state not readable", "missing schema")
        XCTAssertEqual(snapshot.profiles[2].state?.state, "serving", "the good entry is intact")
    }

    func testDecodesANonZeroSkippedCountAlongsideOneShare() throws {
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

    func testDecodesTheTenantFields() throws {
        let snapshot = try loadFixtureTenantProfiles()

        let origin = try XCTUnwrap(snapshot.profiles.first { $0.name == "dfoundation" }?.state)
        XCTAssertEqual(origin.r2, true)
        XCTAssertEqual(origin.storageDefault, "local")
        XCTAssertEqual(origin.cloudMore, 3)
        XCTAssertNil(origin.cloudError)

        let cloudRow = origin.shares[0]
        XCTAssertEqual(cloudRow.storage, "cloud")
        XCTAssertEqual(cloudRow.type, "site")
        XCTAssertEqual(cloudRow.by, "han-air")
        XCTAssertNil(cloudRow.access)

        let gatedMachineRow = origin.shares[1]
        XCTAssertEqual(gatedMachineRow.storage, "machine")
        XCTAssertEqual(gatedMachineRow.type, "pdf")
        XCTAssertEqual(gatedMachineRow.by, "mac-mini")
        XCTAssertEqual(gatedMachineRow.access, "group:dwarves-ops")

        let liveRow = origin.shares[2]
        XCTAssertEqual(liveRow.storage, "machine")
        XCTAssertEqual(liveRow.kind, "live")

        let member = try XCTUnwrap(snapshot.profiles.first { $0.name == "files" }?.state)
        XCTAssertEqual(member.backend, "r2")
        XCTAssertEqual(member.r2, true)
        XCTAssertEqual(member.cloudError, "the menu reads cloud links only with a stored token: share --profile files api-token")
    }

    func testAbsentTenantFieldsDecodeAsNil() throws {
        let snapshot = try loadFixtureProfiles()
        let state = try XCTUnwrap(snapshot.profiles[1].state)
        XCTAssertNil(state.r2)
        XCTAssertNil(state.storageDefault)
        XCTAssertNil(state.cloudError)
        XCTAssertNil(state.cloudMore)
        XCTAssertNil(state.shares[0].storage)
        XCTAssertNil(state.shares[0].type)
        XCTAssertNil(state.shares[0].by)

        // The tenant fixture's third profile carries no new keys either, so one decode
        // run proves both fixture shapes keep working.
        let legacy = try XCTUnwrap(try loadFixtureTenantProfiles().profiles.first { $0.name == "personal" }?.state)
        XCTAssertNil(legacy.r2)
        XCTAssertNil(legacy.shares[0].storage)
        XCTAssertNil(legacy.shares[0].type)
        XCTAssertNil(legacy.shares[0].by)
    }

    func testAShareWithAnUnknownTypeStillDecodes() throws {
        let share = try JSONDecoder().decode(
            Share.self,
            from: Data(#"{"id":"a1","name":"n","url":"u","kind":"snapshot","own_host":null,"expires":0,"type":"spreadsheet","storage":"cloud","by":"mini"}"#.utf8)
        )
        XCTAssertEqual(share.type, "spreadsheet", "the raw value survives decode")
        XCTAssertEqual(RowGlyphs.type(share.type), RowGlyph(symbol: "doc", word: "file"), "the row maps it to doc")
    }

    func testFixtureBuildsAWorkingMenuModel() throws {
        // Not a MenuModel-rules test (see MenuModelHeaderTests / SectionTests for those);
        // just confirms the decoded fixture flows end to end into a model.
        let snapshot = try loadFixtureProfiles()
        let model = MenuModel(profiles: snapshot, failure: nil, now: Date())

        XCTAssertEqual(model.sections.count, 2)
        XCTAssertEqual(model.sections[1].rows.count, snapshot.profiles[1].state?.shares.count)
    }
}
