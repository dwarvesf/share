# SG-12 Live acceptance on s.console.so (SPEC-009 TASK-4e)
Model: opus
Effort: high
**Branch:** docs/members-live-acceptance
Design: obvious
Wall budget: 300 min
Port base: n/a

## Owner authorization
The owner pre-approved this sub-goal ("auto approve till the end", 2026-11-14). It changes the real tenant s.console.so, served by this Mac mini from profile `console`: T0 to T1 (`setup s.console.so --r2 --bucket <name>`), then T1 to T2 (`--members`), then one machine member. Use the branch build of `bin/share` (no release tag, D10). Never touch s.han.ws or s.d.foundation.

## Member machine (owner said: not the MacBook Air)
Use the `server` macOS account on this Mini as the member: its own HOME, Keychain and cloudflared, driven with `mini-run --as server` or `sudo -n -u server`. First prove its login Keychain accepts a `security add-generic-password` and read-back under that path; if it cannot, stop and write the blocker to HANDOFF.md: the owner must name a member machine. Log the choice in DECISIONS.md as a deviation from "a second machine" (same hardware, separate account and Keychain).

## Done =
Every `## After state` item of SPEC-009 checked live on s.console.so (except the Share Bar items, which SG-09 and SG-10 proved through the fake CLI; also run the member's Share Bar once against the live CLI and capture one screenshot). Each negative control of SPEC-009 `## Grounding` has its red and green run recorded in `docs/verification/multi-member.md`. At the end, s.console.so stays T2 with the member active, or, if any check fails, it is rolled back to its starting state (T0, serving) with `member rm`, `--no-members`, `--no-r2`, and the rollback is recorded.

## Proof
`docs/verification/multi-member.md`: `## Recorded run`, `## Rollback`, and the UAT line with the date and the outcome.

## Touches
docs/verification/multi-member.md
docs/implementation-notes/multi-member.md
