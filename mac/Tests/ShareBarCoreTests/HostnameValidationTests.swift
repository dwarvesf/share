import XCTest
@testable import ShareBarCore

/// Mirrors `bin/share`'s `cmd_setup` guard byte for byte, so a hostname the app enables
/// Set Up for is exactly one the CLI would also accept.
final class HostnameValidationTests: XCTestCase {
    func testAcceptsASimpleSubdomain() {
        XCTAssertTrue(HostnameValidation.isValid("s.example.com"))
    }

    func testAcceptsATwoLetterTLD() {
        XCTAssertTrue(HostnameValidation.isValid("s.co"))
    }

    func testAcceptsHyphensAndDigitsInTheMiddle() {
        XCTAssertTrue(HostnameValidation.isValid("my-host2.example.com"))
    }

    func testAcceptsABareSecondLevelDomain() {
        XCTAssertTrue(HostnameValidation.isValid("example.com"))
    }

    func testRejectsEmptyString() {
        XCTAssertFalse(HostnameValidation.isValid(""))
    }

    func testRejectsNoDot() {
        XCTAssertFalse(HostnameValidation.isValid("localhost"))
    }

    func testRejectsUppercase() {
        XCTAssertFalse(HostnameValidation.isValid("S.example.com"))
    }

    func testRejectsLeadingHyphen() {
        XCTAssertFalse(HostnameValidation.isValid("-s.example.com"))
    }

    func testAcceptsAHyphenBeforeAnInnerDot() {
        // Matches `bin/share`'s own regex exactly, including this counterintuitive case:
        // the optional middle group allows `.` and `-` freely, so a hyphen right before an
        // inner dot is not the "trailing hyphen" the character class would reject if it
        // were followed by the final `.`+TLD instead.
        XCTAssertTrue(HostnameValidation.isValid("s-.example.com"))
    }

    func testRejectsATrailingHyphenRightBeforeTheFinalDot() {
        XCTAssertFalse(HostnameValidation.isValid("example-.com"))
    }

    func testRejectsOneLetterTLD() {
        XCTAssertFalse(HostnameValidation.isValid("s.example.c"))
    }

    func testRejectsTrailingDot() {
        XCTAssertFalse(HostnameValidation.isValid("s.example.com."))
    }

    func testRejectsWhitespace() {
        XCTAssertFalse(HostnameValidation.isValid("s example.com"))
    }

    func testRejectsSchemePrefix() {
        XCTAssertFalse(HostnameValidation.isValid("https://s.example.com"))
    }

    func testRejectsPort() {
        XCTAssertFalse(HostnameValidation.isValid("s.example.com:8080"))
    }
}
