# Verification: the Share mark as menu bar glyph and app icon

Work: the status item draws the open-ring mark (open ring plus dot while serving, closed ring while not) from `ShareBarCore/Mark.swift` instead of an SF Symbol; `mac/icons.sh` draws `AppIcon.icns` from the same shapes and `mac/build.sh` ships it in the bundle (ADR-0010).

Done = both states render as the right shapes at every menu bar size, `swift test` passes, `build.sh` produces a signed bundle that carries `AppIcon.icns` named by `CFBundleIconFile`, and a deliberately merged dot turns the new tests red.

## Green run

```
Command: swift test --package-path mac --filter MarkTests
Exit:    0
Output:  Executed 6 tests, with 0 failures (0 unexpected) in 0.011 (0.011) seconds
Verdict: PASS

Command: swift test --package-path mac
Exit:    0
Output:  Executed 182 tests, with 0 failures (0 unexpected) in 5.988 (6.000) seconds
Verdict: PASS

Command: bash mac/build.sh 0.0.0
Exit:    0
Output:  == assemble Share Bar.app / == sign (ad-hoc) / mac/build/Share-Bar-0.0.0.zip
Verdict: PASS

Command: /usr/libexec/PlistBuddy -c "Print :CFBundleIconFile" "mac/build/Share Bar.app/Contents/Info.plist"
Exit:    0
Output:  AppIcon
Verdict: PASS

Command: file "mac/build/Share Bar.app/Contents/Resources/AppIcon.icns" && codesign -v --strict "mac/build/Share Bar.app"
Exit:    0
Output:  Resources/AppIcon.icns: Mac OS X icon, 122893 bytes, "ic12" type
Verdict: PASS (bundle verifies after the icon was added)

Command: shellcheck mac/build.sh mac/icons.sh mac/release.sh
Exit:    0
Output:  shellcheck-ok
Verdict: PASS
```

The rendered glyphs and icon were read as images at true size and magnified (`docs/brand/share-mark-contact-sheet.png`): at 16 pt and 18 pt, 1x and 2x, serving shows a ring with an opening and a separate dot, not serving shows a closed hollow ring, on light and dark.

## Negative control

Moved the small cut's `dotDistance` from 126 to 100 so the dot sits in the ring, then re-ran the tests.

```
Command: swift test --package-path mac --filter MarkTests   (dotDistance: 100)
Exit:    1
Output:  Executed 6 tests, with 7 failures (0 unexpected) in 0.077 (0.077) seconds
         XCTAssertGreaterThan failed: ("25.65...") is not greater than ("30.66...") - small cut gap
         XCTAssertEqual failed: ("223") is not equal to ("0") - ring open at the top right at 16 px
Verdict: RED as expected
```

Restored `dotDistance: 126`; the green run above is that state.

## Not proven

- The app was not launched, so the glyph was not seen in a real menu bar or the icon in Finder; both were verified from rendered pixels and the bundle contents only.
- Signed and notarized builds (`--sign`, `--notarize`) were not run; the icon step is the same either way.

## Rollback

Revert the three commits of the branch; the status item returns to the SF Symbol and the bundle to no icon.
