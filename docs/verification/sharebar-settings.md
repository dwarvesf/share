# Verification: Share Bar settings A (SPEC-009 TASK-4b14 to TASK-4b18)

Nothing was deployed. The change is `mac/` only plus docs. Screens, parity samples and the Mobbin comparison: `docs/verification/share-bar/settings-a/README.md`.

## AC to test

| AC row | Test |
|---|---|
| Members tab hidden for a non-admin | `SettingsTabsAndGeneralTests.testMembersTabHiddenForANonAdmin` |
| General's expiry writes argv `share config ttl 7d` | `testGeneralsExpiryWritesArgvShareConfigTtl7d`; fake CLI: `argv/` of `general-tab` and the hook `choose:ttl` |
| each source writes its argv | `KeySourceTests.testEachSourceWritesItsArgv`; fake CLI: `adv-1p`, `adv-cmd`, `adv-ask` expect-argv |
| each minter source writes its argv | `testEachMinterSourceWritesItsArgv`; fake CLI: `adv-minter-1p` |
| Test shows capabilities and never a token-shaped string | `testTestShowsCapabilitiesAndNeverATokenShapedString`, `testAFailedTestShowsTheCLISentenceWithNoCredentialShapedRun` |
| stop serving counts from rows | `SheetsAndFlowTests.testStopServingCountsFromRows`; screen `stop-serving-confirm` (4 and 9) |
| pause counts the member's machine links | `testPauseCountsTheMembersMachineLinks` |
| the asked key reaches the child environment only | `testTheAskedKeyReachesTheChildEnvironmentOnly`, `testTheAskedKeyReachesTheSpawnedChildThroughItsEnvironment`; fake CLI: `cloud-progress` expect-env `CLOUDFLARE_API_TOKEN=present`, argv holds no key |
| Esc never closes progress | `testEscNeverClosesProgress` |
| buttons per role, tier and phase | `TenantDetailTests.testButtonsPerRoleTierAndPhase`, `testTheTierButtonsAreAdminOnly` |
| members_present maps to the refusal sheet | `testMembersPresentMapsToTheRefusalSheet`; screen `tenant-refused-removal` |
| removed member shows Clean up | `testRemovedMemberShowsCleanUp` |
| expired or invalid key never shows Clean up | `testExpiredOrInvalidKeyNeverShowsCleanUp` |
| progress sheet follows progress lines | `testProgressSheetFollowsProgressLines`, `testAFinishedRunMarksEveryStepDone` |
| Stop sends SIGTERM and leaves the callout | `testStopSendsSIGTERMAndLeavesTheCallout`; screen `interrupted-callout` |
| Resume runs rerun, Roll back runs rollback | `testResumeRunsRerunAndRollBackRunsRollback`; fake CLI: `resume-join` logs `join <host> <code>` then `join` |
| the tier buttons are admin only | `testTheTierButtonsAreAdminOnly` |

## Recorded run

Command: `swift build --package-path mac`
Exit: 0
Verdict: pass
Output: `Build complete!`

Command: `swift test --package-path mac`
Exit: 0
Verdict: pass, 355 tests (the 45 new ones are under `Tests/ShareBarCoreTests/Settings/`)
Output: `Executed 355 tests, with 0 failures (0 unexpected)`

Command: `bash mac/build.sh 0.0.0`
Exit: 0
Verdict: pass; the release build compiles the hook file out (`#if DEBUG`)
Output: `mac/build/Share-Bar-0.0.0.zip`

Command: `bash mac/compat-check.sh v0.9.0`
Exit: 0
Verdict: pass; the shipped Share Bar keeps working against the new CLI
Output: `ok .../scenarios/member/profiles.json (1 profile)`, `ok .../live/state.json (1 profile)`

Command: `bash mac/Tests/fixtures/settings/run-shots.sh` (30 step files, light and dark)
Exit: 0
Verdict: pass; every `expect-argv`, `expect-no-argv` and `expect-env` held, 60 captures written
Output: `wrote docs/verification/share-bar/settings-a/4b-<label>-<light|dark>.png`; argv logs in `settings-a/argv/`

Command: `bash mac/Tests/fixtures/settings/parity/render-reference.sh` then `compare.sh`
Exit: 0
Verdict: pass; surface, title ink and separator within 2 steps, deviations listed in `settings-a/README.md`
Output: `settings-a/parity/samples.tsv` (200 rows)

Command: `shellcheck -x` over the new scripts, and `/bin/bash -n` on each
Exit: 0
Verdict: pass (bash 3.2 parses)
Output: none

## UAT

The Settings window ran against the fake CLI and the fake `op` only; no live tenant, no Cloudflare call, no real profile under `~/.config/share` was touched. The in-app hook path is DEBUG-only.

## Rollback

No deploy, no Worker, no persistent CLI state. The app writes only its own defaults (General prefs, the remembered key source names and ids) and, on a button press, the CLI config through `share config`, `share admin-token` and `share minter-token`. Revert the PR to remove the window; the popover's gear then logs again and opens nothing.
