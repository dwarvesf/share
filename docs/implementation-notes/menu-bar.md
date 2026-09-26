# Implementation notes: menu bar app

Delta from `docs/specs/SPEC-003-menu-bar.md`. Decisions already in the spec are referenced, never restated.

## Decisions made without the operator

- The operator delegated the whole cycle and was away, so design and spec approval were self-approved and recorded in the gate ledger as such. The design lane's one-question loop could not run (bypass mode).
- Research changed the contract before it was written: no `version` field (the script carries no version string), a `serves_here` field added (the `hosts=` guard), `SHARE_CLIPBOARD=0` set for every child process.

## Deviations

(none yet)

## Open questions for the operator

- The final product name. The spec ships "Share Bar" as a working name (DEC-007); the rename touches one constant, the Info.plist, and the cask file.
