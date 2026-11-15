import XCTest
@testable import ShareBarCore

/// SPEC-009 TASK-4b15: both keys write argv from ids, never names, and Test never shows a token.
final class KeySourceTests: XCTestCase {
    private let vault = "abcdefghij0123456789abcdef"
    private let item = "zyxwvutsrq9876543210zyxwvu"

    private var picked: OnePasswordItem {
        OnePasswordItem(itemID: item, itemName: "cf-console-labs-admin", vaultID: vault, vaultName: "Toolkit")
    }

    func testEachSourceWritesItsArgv() {
        XCTAssertEqual(
            KeyArgv.write(.admin, source: .onePassword(picked), profile: "console"),
            ["--profile", "console", "admin-token", "--cmd", "op read op://\(vault)/\(item)/credential"]
        )
        XCTAssertEqual(
            KeyArgv.write(.admin, source: .command("security find-generic-password -w -s cf-admin"), profile: "console"),
            ["--profile", "console", "admin-token", "--cmd", "security find-generic-password -w -s cf-admin"]
        )
        XCTAssertEqual(KeyArgv.write(.admin, source: .askEachTime, profile: "console"), ["--profile", "console", "admin-token", "--clear"])
    }

    func testEachMinterSourceWritesItsArgv() {
        XCTAssertEqual(
            KeyArgv.write(.minter, source: .onePassword(picked), profile: "console"),
            ["--profile", "console", "minter-token", "--cmd", "op read op://\(vault)/\(item)/credential"]
        )
        XCTAssertEqual(KeyArgv.write(.minter, source: .command("pass show cf-minter"), profile: "console")?.suffix(3), ["minter-token", "--cmd", "pass show cf-minter"])
        XCTAssertEqual(KeyArgv.write(.minter, source: .askEachTime, profile: "console"), ["--profile", "console", "minter-token", "--clear"])
        XCTAssertEqual(KeyKind.minter.environmentName, "SHARE_MINTER_TOKEN", "Ask me each time reaches the member command as this variable")
    }

    func testOnlyTwentySixCharacterIDsReachACommand() {
        let injected = OnePasswordItem(itemID: "x; touch /tmp/pwn", itemName: "$(whoami)", vaultID: vault, vaultName: "Toolkit")
        XCTAssertNil(KeyArgv.write(.admin, source: .onePassword(injected), profile: "console"))
        let upper = OnePasswordItem(itemID: item.uppercased(), itemName: "x", vaultID: vault, vaultName: "v")
        XCTAssertNil(KeyArgv.write(.admin, source: .onePassword(upper), profile: "console"))
        XCTAssertNil(KeyArgv.write(.admin, source: .onePassword(nil), profile: "console"))
        XCTAssertNil(KeyArgv.write(.admin, source: .command("   "), profile: "console"))
        XCTAssertNil(KeyArgv.write(.admin, source: .command("a\nb"), profile: "console"))
        XCTAssertTrue(KeyArgv.isValidID(item))
        XCTAssertFalse(KeyArgv.isValidID(item + "a"))
    }

    func testTheItemListKeepsOnlyValidIDsAndTheirNames() {
        let json = """
        [{"id":"\(item)","title":"cf-console-labs-admin","vault":{"id":"\(vault)","name":"Toolkit"},"category":"API_CREDENTIAL"},
         {"id":"not-an-id","title":"bad","vault":{"id":"\(vault)","name":"Toolkit"}},
         {"id":"\(item)","title":"no vault"}]
        """
        let items = OnePasswordItem.decode(json)
        XCTAssertEqual(items, [picked])
        XCTAssertEqual(items.first?.subtitle, "Toolkit vault · credential")
        XCTAssertEqual(OnePasswordItem.decode("not json"), [])
    }

    func testTestRunsTheJSONProbe() {
        XCTAssertEqual(KeyArgv.test(.admin, profile: "console"), ["--profile", "console", "admin-token", "--test", "--json"])
        XCTAssertEqual(KeyArgv.test(.minter, profile: "console").suffix(3), ["minter-token", "--test", "--json"])
    }

    func testTestShowsCapabilitiesAndNeverATokenShapedString() throws {
        let token = "cfut_" + String(repeating: "A1b2C3d4", count: 6)
        let stdout = """
        {"source":"cmd","token":"\(token)","can":{"workers":true,"tunnels":true,"dns":true,"r2":false,"connectivity":true,"extra":"\(token)"}}
        """
        let result = try XCTUnwrap(KeyTestResult.decode(stdout, kind: .admin))
        XCTAssertEqual(result.capabilities.map(\.label), ["tunnels", "DNS", "Workers", "R2", "Connectivity Directory"])
        XCTAssertEqual(result.summary, "Works for tunnels, DNS, Workers and Connectivity Directory. Cannot use R2")
        XCTAssertFalse(result.allOK)
        let shown = ([result.summary, result.source] + result.capabilities.map(\.label)).joined(separator: " | ")
        XCTAssertFalse(shown.contains(token))
        XCTAssertNil(shown.range(of: #"[A-Za-z0-9_\-]{32,}"#, options: .regularExpression))

        let allGood = try XCTUnwrap(KeyTestResult.decode(#"{"source":"env","can":{"workers":true,"tunnels":true,"dns":true}}"#, kind: .admin))
        XCTAssertEqual(allGood.summary, "Works for tunnels, DNS and Workers")
        XCTAssertTrue(allGood.allOK)
        let minter = try XCTUnwrap(KeyTestResult.decode(#"{"source":"cmd","can":{"list_tokens":true}}"#, kind: .minter))
        XCTAssertEqual(minter.summary, "Works for listing API tokens")
        XCTAssertNil(KeyTestResult.decode("garbage", kind: .admin))
    }

    func testAFailedTestShowsTheCLISentenceWithNoCredentialShapedRun() {
        let token = String(repeating: "Zz9", count: 14)
        let stderr = "share: x\n{\"error\":{\"code\":\"admin_token_cmd_failed\",\"message\":\"admin_token_cmd printed no token \(token)\",\"next\":\"share admin-token --test\"}}\n"
        let sentence = KeyTestResult.failureSentence(CLIResult(status: 1, stdout: "", stderr: stderr, timedOut: false))
        XCTAssertEqual(sentence, "admin_token_cmd printed no token …")
        XCTAssertEqual(KeyTestResult.failureSentence(CLIResult(status: 1, stdout: "", stderr: "share: the token cannot read Worker w's settings\n", timedOut: false)),
                       "the token cannot read Worker w's settings")
    }

    func testTheRememberedSourceHoldsNamesAndIDsNeverAToken() throws {
        let suite = "sharebar.test.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let store = KeySourceStore(defaults: defaults)
        XCTAssertEqual(store.load(.admin, profile: "c"), .askEachTime)
        store.save(.onePassword(picked), kind: .admin, profile: "c")
        XCTAssertEqual(store.load(.admin, profile: "c"), .onePassword(picked))
        XCTAssertEqual(store.adminKeyLabel(profile: "c"), "1Password, cf-console-labs-admin")
        XCTAssertEqual(store.load(.minter, profile: "c"), .askEachTime, "the two keys are remembered apart")
        store.save(.command("pass show x"), kind: .minter, profile: "c")
        XCTAssertEqual(store.load(.minter, profile: "c"), .command("pass show x"))
        store.save(.askEachTime, kind: .admin, profile: "c")
        XCTAssertEqual(store.adminKeyLabel(profile: "c"), "Asks each time")
    }
}
