# Implementation notes: menu bar profiles

Delta from `docs/specs/SPEC-006-menu-bar-profiles.md`. Decisions already in the spec are referenced, never restated.

## Structure the spec left open

- `MenuModel` lost its flat `rows`/`more`/`showStart` surface and now builds `sections: [Section]`, one per profile entry. `Row` gained `profile` and `access`; the (profile, id) pair keys rows, hits, and every argv, because two profiles can mint the same 6-hex id.
- `Health` (MenuModel.swift) is the spec's classification table as one enum, first-match-wins. `notSetUp` is checked before `elsewhere`: an unset profile reports `serves_here false` and must stay neutral, which is exactly the Mini's `default`.
- `Publish.swift` holds the dialog's rules (`PublishForm`, `AccessRule`, `PublishChoice`, `Audience`, `PublishMessage`) so every testable rule lives outside AppKit. The dialog itself is one `NSAlert` whose accessory view is an `NSStackView` (profile popup, audience popup, rule field, quick-mode note); a small `AlertForm` NSObject holds the `PublishForm` because ObjC targets need a class.
- `ProfilesCoalescer` replaces `StateCoalescer`. `fresh` callers never join a run that predates them: they wait for the in-flight run to end, then spawn their own, which later plain callers may join. The whole-app re-read after a mutation is `CLI.profiles(fresh: true)`.
- `MutationQueue` runs verbs through `spawnCancellable` and keeps a `JobToken` (UUID) beside the running `CLIJob`; `cancel(job:)` matches the token, so a Stop Waiting confirm answered after a job ended can never reach the next job.
- `MutationAlert` gained `detail`: the whole stderr verbatim when it holds two or more non-empty lines. `present(_:)` renders it in a scrollable read-only `NSTextView` rather than `informativeText`, because the O1/O3 guided blocks must be selectable monospaced text. Failure `message` prefers the last `share: `-prefixed stderr line (the die line) over a trailing detail line.

## Deviations and choices made inside the spec's room

- The Swift strip list is the CLI's six `profiles_child_env` unsets plus `SHARE_PROFILE`: no child should ever inherit a profile selection either. The parity test in `tests/share.sh` compares only the six spec-named overrides.
- `PublishChoice.eligible` keeps `elsewhere` profiles eligible: their state is `stopped` and `add` auto-starts them; the existing `notServingHere` post-add notice still applies.
- `Stop Sharing`/`Start Sharing` are mutually exclusive per section (`stop` when serving, `start` when not serving but served here). `Set Up...` follows the spec's rule exactly (`state != "serving"` and not an error), so a stopped profile shows both `Start Sharing` and `Set Up...`.
- The dialog default button is the publish button (first `addButton`, gets Return); Cancel is the second button. This is DEC-004's "Return accepts the remembered choice", inverted from the remove confirm where Cancel is default.
- Batch `Not published: <names>` appends to the alert's `detail` (after the verbatim stderr when there is one); a batch stops on a non-zero add, a killed add, or a failed fresh re-read, and only that alert carries the line.
- `SetupWindowModel` no longer probes for a hostname at init; the section passes the host it already displays, which is also the correct prefill for a half-finished setup recovery.

## Landmines hit during the build

- `tests/share.sh`'s own `state` comparison needed `-u XDG_CONFIG_HOME`: on the Mini `XDG_CONFIG_HOME` is exported globally, so an un-stripped comparison call reads real profiles instead of the private `HOME`, and `default` still passes while every named profile silently mismatches.
- `let verbForLog = verbForLog(args)` shadows the static helper inside its own initializer; the local is named `verb`.
- `sed -n '/name/,/]/p'` restarts its range at every later match of `name`; a doc comment that mentions the array in backticks (and `SHARE_CLIPBOARD`) got swept into the extracted list. The parity test anchors on `static let strippedEnvironmentKeys` and a `^\s*\]$` end.

## Not done here

- UAT (SPEC-006 rows 8 and 25) is the operator's checklist: real menu rendering, real drop/dialog, Access-group add, stale-snapshot icon. Tests cover every row the matrix assigns to `swift test` or `tests/share.sh`.
