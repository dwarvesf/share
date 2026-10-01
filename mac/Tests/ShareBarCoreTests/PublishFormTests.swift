import XCTest
@testable import ShareBarCore

/// The publish dialog's rules: eligible profiles, remembered choices, the audience carry
/// that never silently loosens a login, the local rule-shape check, and the add argv.
final class PublishFormTests: XCTestCase {
    private func serving(_ name: String, host: String? = nil, mode: String = "named") -> ProfileEntry {
        makeEntry(name: name, state: makeSnapshot(state: "serving", ready: true, mode: mode, host: host ?? "s.example.com"))
    }

    // MARK: - AccessRule.isWellFormed

    func testWellFormedRules() {
        XCTAssertTrue(AccessRule.isWellFormed("group:dwarves-ops"))
        XCTAssertTrue(AccessRule.isWellFormed("email:a@x.io,b@y.io"))
        XCTAssertTrue(AccessRule.isWellFormed("domain:d.foundation"))
        XCTAssertTrue(AccessRule.isWellFormed("  group:ops  "), "surrounding whitespace trims first")
    }

    func testMalformedRules() {
        // Shape only: prefix plus at least one character, no whitespace. "email:a@x" is
        // in-shape; its emptiness is the CLI's grammar to refuse.
        for rule in ["", "ops", "group:", "email:", "domain:", "group: ops", "url:x", "GROUP:ops"] {
            XCTAssertFalse(AccessRule.isWellFormed(rule), "expected malformed: \(rule.debugDescription)")
        }
    }

    // MARK: - PublishChoice.eligible

    func testEligibleIsStoppedOrServingWithNoError() {
        let snapshot = makeProfiles([
            serving("serving"),
            makeEntry(name: "stopped", state: makeSnapshot(state: "stopped", servesHere: true)),
            makeEntry(name: "away", state: makeSnapshot(state: "stopped", servesHere: false)),
            makeEntry(name: "new", state: makeSnapshot(state: "not_setup", host: nil, servesHere: false)),
            makeEntry(name: "Bad", error: "share: bad profile name 'Bad'"),
        ])

        XCTAssertEqual(PublishChoice.eligible(snapshot), ["serving", "stopped", "away"])
    }

    // MARK: - initial selection

    func testStoredProfilePreselectsWhenStillEligible() {
        let snapshot = makeProfiles([serving("a"), serving("b")])
        let form = PublishForm(profiles: snapshot, lastProfile: "b", lastRules: [:])
        XCTAssertEqual(form.profile, "b")
    }

    func testTornDownStoredProfileFallsBackToFirstEligible() {
        let snapshot = makeProfiles([serving("a"), serving("b")])
        let form = PublishForm(profiles: snapshot, lastProfile: "gone", lastRules: [:])
        XCTAssertEqual(form.profile, "a")
    }

    func testUnsetStoredProfileFallsBackToFirstEligible() {
        let snapshot = makeProfiles([serving("a"), serving("b")])
        let form = PublishForm(profiles: snapshot, lastProfile: nil, lastRules: [:])
        XCTAssertEqual(form.profile, "a")
    }

    // MARK: - audience and rule carry

    func testInitialAudienceComesFromTheStoredRule() {
        let snapshot = makeProfiles([serving("a")])
        var form = PublishForm(profiles: snapshot, lastProfile: nil, lastRules: ["a": "group:ops"])
        XCTAssertEqual(form.audience, .login)
        XCTAssertEqual(form.rule, "group:ops")

        form = PublishForm(profiles: snapshot, lastProfile: nil, lastRules: [:])
        XCTAssertEqual(form.audience, .anyone)
        XCTAssertEqual(form.rule, "")
    }

    func testLoginSurvivesAProfileSwitchEvenWhenTheNewProfilesChoiceIsAnyone() {
        let snapshot = makeProfiles([serving("a", host: "a.example.com"), serving("b", host: "b.example.com")])
        var form = PublishForm(profiles: snapshot, lastProfile: nil, lastRules: ["a": "group:ops"])
        form.select(profile: "b")

        XCTAssertEqual(form.audience, .login, "selecting another profile never loosens a login")
        XCTAssertEqual(form.rule, "group:ops")
        XCTAssertEqual(form.buttonTitle, "Publish behind login on b.example.com")
    }

    func testAnyoneSelectionLoadsTheNewProfilesStoredChoice() {
        let snapshot = makeProfiles([serving("a"), serving("b")])
        var form = PublishForm(profiles: snapshot, lastProfile: nil, lastRules: ["b": "email:a@x.io"])
        form.select(profile: "b")

        XCTAssertEqual(form.audience, .login)
        XCTAssertEqual(form.rule, "email:a@x.io")
    }

    // MARK: - quick mode

    func testQuickProfileCannotPublishBehindLogin() {
        let snapshot = makeProfiles([serving("q", host: "q.trycloudflare.com", mode: "quick")])
        var form = PublishForm(profiles: snapshot, lastProfile: nil, lastRules: ["q": "group:ops"])

        XCTAssertEqual(form.audience, .login)
        XCTAssertFalse(form.loginAvailable)
        XCTAssertFalse(form.canPublish, "publish stays disabled until the user picks anyone")

        form.choose(.anyone)
        XCTAssertTrue(form.canPublish)
        XCTAssertEqual(form.buttonTitle, "Publish publicly on q.trycloudflare.com")
    }

    // MARK: - canPublish and button titles

    func testMalformedRuleKeepsPublishDisabled() {
        let snapshot = makeProfiles([serving("a", host: "a.example.com")])
        var form = PublishForm(profiles: snapshot, lastProfile: nil, lastRules: [:])
        form.choose(.login)
        form.rule = "ops"

        XCTAssertFalse(form.canPublish)
        XCTAssertEqual(form.buttonTitle, "Publish behind login on a.example.com")

        form.rule = "group:ops"
        XCTAssertTrue(form.canPublish)
    }

    func testStaleSnapshotNamesTheProfileNotTheHost() {
        let snapshot = makeProfiles([serving("a", host: "a.example.com")])
        let form = PublishForm(profiles: snapshot, lastProfile: nil, lastRules: [:], staleHosts: true)
        XCTAssertEqual(form.buttonTitle, "Publish publicly on a")
    }

    func testNoEligibleProfileLeavesNilProfileAndDisabledPublish() {
        let snapshot = makeProfiles([
            makeEntry(name: "default", state: makeSnapshot(state: "not_setup", host: nil, servesHere: false)),
        ])
        let form = PublishForm(profiles: snapshot, lastProfile: nil, lastRules: [:])
        XCTAssertNil(form.profile)
        XCTAssertFalse(form.canPublish)
    }

    // MARK: - args

    func testArgsBuildsTheArgv() {
        XCTAssertEqual(
            PublishChoice.args(profile: "dfoundation", rule: nil, path: "/tmp/notes.txt"),
            ["--profile", "dfoundation", "add", "/tmp/notes.txt"]
        )
        XCTAssertEqual(
            PublishChoice.args(profile: "dfoundation", rule: "group:ops", path: "/tmp/notes.txt"),
            ["--profile", "dfoundation", "add", "--access", "group:ops", "/tmp/notes.txt"]
        )
        XCTAssertNil(PublishChoice.args(profile: "p", rule: nil, path: "8080"), "a relative path never becomes an argv")
        XCTAssertNil(PublishChoice.args(profile: "p", rule: nil, path: "report.pdf"), "no bare filename reaches add")
    }

    // MARK: - storage field

    private func origin(r2: Bool, storageDefault: String? = nil, servesHere: Bool = true, name: String = "dfoundation") -> ProfileEntry {
        makeEntry(name: name, state: makeSnapshot(
            state: "serving", hosts: "Mac-mini", servesHere: servesHere, r2: r2, storageDefault: storageDefault
        ))
    }

    func testAnOriginWithR2ShowsThePickerPreselectedFromStorageDefault() {
        var snapshot = makeProfiles([origin(r2: true, storageDefault: "cloud")])
        var form = PublishForm(profiles: snapshot, lastProfile: nil, lastRules: [:])
        XCTAssertEqual(form.storageField, .picker(machine: "Mac-mini"))
        XCTAssertEqual(form.storage, .cloud)
        XCTAssertEqual(form.storageFlag, .cloud)

        snapshot = makeProfiles([origin(r2: true, storageDefault: "local")])
        form = PublishForm(profiles: snapshot, lastProfile: nil, lastRules: [:])
        XCTAssertEqual(form.storage, .local)
        XCTAssertEqual(form.storageFlag, .local)

        // A chosen value reaches the argv as --cloud / --local.
        form.choose(storage: .cloud)
        XCTAssertEqual(
            PublishChoice.args(profile: "dfoundation", rule: nil, path: "/tmp/a", storage: form.storageFlag),
            ["--profile", "dfoundation", "add", "--cloud", "/tmp/a"]
        )
        form.choose(storage: .local)
        XCTAssertEqual(
            PublishChoice.args(profile: "dfoundation", rule: nil, path: "/tmp/a", storage: form.storageFlag),
            ["--profile", "dfoundation", "add", "--local", "/tmp/a"]
        )
    }

    func testAMemberProfileShowsADisabledCloudLabelAndNoFlag() {
        let member = makeEntry(name: "files", state: makeSnapshot(
            state: "serving", host: "s.d.foundation", hosts: "", servesHere: false, backend: "r2", r2: true
        ))
        let form = PublishForm(profiles: makeProfiles([member]), lastProfile: nil, lastRules: [:])

        XCTAssertEqual(form.storageField, .member)
        XCTAssertNil(form.storageFlag, "a member adds cloud links with no flag")
    }

    func testATunnelProfileWithR2OffShowsNoStorageControl() {
        let form = PublishForm(profiles: makeProfiles([serving("a")]), lastProfile: nil, lastRules: [:])
        XCTAssertEqual(form.storageField, .none)
        XCTAssertNil(form.storageFlag)

        // An older CLI emits no r2 key at all: same shape, no control.
        let legacy = makeEntry(name: "old", state: makeSnapshot(state: "serving"))
        XCTAssertEqual(PublishForm(profiles: makeProfiles([legacy]), lastProfile: nil, lastRules: [:]).storageField, .none)
    }

    func testAnOriginNotServingHereShowsNoStorageControl() {
        let form = PublishForm(profiles: makeProfiles([origin(r2: true, storageDefault: "cloud", servesHere: false)]),
                               lastProfile: nil, lastRules: [:])
        XCTAssertEqual(form.storageField, .none, "the popup belongs to the origin only")
        XCTAssertNil(form.storageFlag)
    }

    func testAProfileSwitchReloadsStorageFromTheNewProfilesDefault() {
        let snapshot = makeProfiles([
            origin(r2: true, storageDefault: "cloud"),
            serving("plain"),
        ])
        var form = PublishForm(profiles: snapshot, lastProfile: nil, lastRules: [:])
        XCTAssertEqual(form.storage, .cloud)

        form.select(profile: "plain")
        XCTAssertEqual(form.storageField, .none)
        XCTAssertNil(form.storageFlag)

        form.select(profile: "dfoundation")
        XCTAssertEqual(form.storage, .cloud, "the picker re-preselects from storage_default")
    }

    // MARK: - MenuModel.canPublish

    func testCanPublishIsFalseOnlyWhenNoProfileIsEligible() {
        let onlyUnset = makeProfiles([
            makeEntry(name: "default", state: makeSnapshot(state: "not_setup", host: nil, servesHere: false)),
        ])
        XCTAssertFalse(MenuModel(profiles: onlyUnset, failure: nil, now: Date()).canPublish)

        let oneStopped = makeProfiles([
            makeEntry(name: "default", state: makeSnapshot(state: "not_setup", host: nil, servesHere: false)),
            makeEntry(name: "dfoundation", state: makeSnapshot(state: "stopped", servesHere: true)),
        ])
        XCTAssertTrue(MenuModel(profiles: oneStopped, failure: nil, now: Date()).canPublish)
    }
}
