# Verification: Share Bar settings B

## Recorded run

Command: swift build --package-path mac
Exit: 0
Verdict: pass
Output: Build complete

Command: swift test --package-path mac
Exit: 0
Verdict: pass
Output: Executed 420 tests, with 0 failures

Command: SHOTS_OUT=docs/verification/share-bar/settings-b mac/Tests/fixtures/settings/run-shots.sh (members-* and links-* steps)
Exit: 0
Verdict: pass, every expect-argv held (pause then resume; one rm with every id)
Output: 4b-*-light.png and 4b-*-dark.png in docs/verification/share-bar/settings-b/

Command: mac/Tests/fixtures/states/states-shots.sh docs/verification/share-bar/settings-b
Exit: 0
Verdict: pass, 8 scenes light and dark
Output: loading, cli-missing, cli-old, first-run, focus-third, menu-shift-f10, publish-failure, working-line

Command: parity/compare.sh (samples.tsv)
Exit: 0
Verdict: pass, largest delta 3 steps
Output: docs/verification/share-bar/settings-b/parity/samples.tsv

UAT: exercised against the fake CLI on this Mac only; no tenant touched; accepted for the proof (live VoiceOver pass open for the owner).

## Not attempted
- A live VoiceOver pass and real Finder, hotkey and drag interactions (owner rule).
- A real notification permission prompt (the Notifier posts only from an app bundle).

## Rollback
Revert the PR. No persistent state changes: the only new defaults are the existing General keys, now read.
