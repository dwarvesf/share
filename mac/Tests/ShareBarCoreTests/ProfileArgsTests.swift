import XCTest
@testable import ShareBarCore

/// Every per-profile verb the app runs leads with `--profile <name>`, `default` included,
/// so no call depends on an inherited SHARE_PROFILE.
final class ProfileArgsTests: XCTestCase {
    func testEveryActionArgvLeadsWithTheProfile() {
        for profile in ["default", "b"] {
            let prefix = ["--profile", profile]
            XCTAssertEqual(ProfileArgs.refresh(profile, id: "abc123"), prefix + ["refresh", "abc123"])
            XCTAssertEqual(ProfileArgs.remove(profile, id: "abc123"), prefix + ["rm", "abc123"])
            XCTAssertEqual(ProfileArgs.start(profile), prefix + ["start"])
            XCTAssertEqual(ProfileArgs.stop(profile), prefix + ["stop"])
            XCTAssertEqual(ProfileArgs.hits(profile, id: "abc123"), prefix + ["hits", "abc123"])
            XCTAssertEqual(ProfileArgs.setup(profile, host: "s.example.com", quick: false), prefix + ["setup", "s.example.com"])
            XCTAssertEqual(ProfileArgs.setup(profile, host: "", quick: true), prefix + ["setup", "--quick"])
            XCTAssertEqual(PublishChoice.args(profile: profile, rule: nil, path: "/tmp/a"), prefix + ["add", "/tmp/a"])
        }
    }
}
