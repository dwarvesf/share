# Implementation notes: menu bar app

Delta from `docs/specs/SPEC-003-menu-bar.md`. Decisions already in the spec are referenced, never restated.

## Decisions made without the operator

- The operator delegated the whole cycle and was away, so design and spec approval were self-approved and recorded in the gate ledger as such. The design lane's one-question loop could not run (bypass mode).
- Research changed the contract before it was written: no `version` field (the script carries no version string), a `serves_here` field added (the `hosts=` guard), `SHARE_CLIPBOARD=0` set for every child process.

## Deviations

- The first spec draft used `share status --json`. The design review showed an older CLI ignores the flag and prunes, so the contract became the verb `share state` (DEC-008). The ADR carries an amendment line rather than a rewrite.
- The review turned up two bugs in share that exist today and that the app would trigger more often: concurrent index writers lose rows, and `quick.url` survives `stop`. Both are fixed in the spec's TASK-001 instead of a separate PR, since the app's correctness depends on them.

## Landmines found while building

- bash 3.2's `printf '%d' "'c"` sign-extends bytes above 127 (`%FFFFFFFFFFFFFFC3` for the first byte of `é`). The pure-bash `urlenc` masks with `$((c & 255))`; probed against `jq @uri` on accented, CJK and emoji names under both `/bin/bash` 3.2 and bash 5.

## Open questions for the operator

- The final product name. The spec ships "Share Bar" as a working name (DEC-007); the rename touches one constant, the Info.plist, and the cask file.
