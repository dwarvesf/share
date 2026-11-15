# Implementation notes: Share Bar settings A

Delta from SPEC-009 TASK-4b14 to TASK-4b18. The spec rows are not restated. Popover notes: `share-bar-popover.md`.

## Decisions the spec left open

- D1. Logic lives in `ShareBarCore/Settings/` (tabs, tenant detail, impact sheets, key sources, flows, argv builders) so `swift test` covers it. Views, the store and the window live in `ShareBar/Settings/`.
- D2. Sheets are SwiftUI overlays inside the Settings window (a scrim and a card), not `NSWindow` sheets, as the prototype draws them. One window then holds every state, `screencapture -l` captures it whole, and the same overlay is reused by the Members tab.
- D3. Screens are reached through a DEBUG-only launch hook (`-ShareBarShotsScreen <script>`, `Settings/ShotsHooks.swift`) that calls the store's own methods (open a tab, select a tenant, open a sheet, type into a field, press its button). No pointer or key input reaches the desktop (owner, 2026-11-15). `Tests/fixtures/settings/run-shots.sh` launches the built app against a fake CLI and captures the window.
- D4. The fake CLI base is frozen, so `Tests/fixtures/settings/bin/share` wraps it: it answers `config`, `admin-token`, `minter-token`, `join`, `setup`, `start`, `stop`, `leave`, `teardown` with the journal step names of `bin/share`, holds at a chosen step (`SHARE_FAKE_HOLD_AT`), and writes the stopped journal into the scenario on SIGTERM. Every other verb goes to the base script.
- D5. The window background is painted with the revision 8 surface (`#eff0f3` light, `#2b2c31` dark) from `Settings/WindowSurface.swift`. `primitive.window` (`Tokens.swift:89`) is `#f5f5f7` and `#26262a` and Tokens is frozen, so the constant lives with the settings views and carries the parity sample in its comment. SG-16 or a tokens pass can move it.
- D6. The Settings window is its own `SettingsStore`: it reads `profiles` itself and runs its verbs through its own `MutationQueue`. `StatusItemController` is not in this sub-goal's touches, so a mutation started here and one started from the popover do not queue behind each other. SG-16 owns the join.
- D7. A new tenant's profile name is the host with every non-alphanumeric run turned into `-` (`s.example.com` becomes `s-example-com`), kept to the CLI's profile-name pattern. Reversible: one function, `ProfileName.slug`.
- D8. `share join <host> <code>` needs a host, so the Join form has two fields (Hostname, Invite code); a pasted `share join <host> <code>` line fills both.
- D9. The cloud-storage and members buttons run `setup <host> --r2 --bucket share-<host with - for .>` (`--members` added for T2). `state` carries no bucket name, so the app uses the convention; a tenant set up with another bucket gets the CLI's refusal sentence.
- D10. The CLI cannot read back `admin_token_cmd`, so Advanced remembers the picked source (kind, item name and vault name, or the command text) in the app's defaults. The 1Password item ids are the only identifiers that reach argv.
- D11. The owner and admin Key row of a tenant reads the source Advanced remembers ("Asks each time" when none), because `state` has no token block for them.
- D12. General's "Menu shows" sets the remembered Mine or Team scope of every tenant (the key `PopoverPrefs` already reads), so the popover follows it with no popover edit.
- D13. Roles in words: `origin` Owner; `tenant_origin` Owner at T1 and Admin at T2; `r2_profile` Admin; `member` Member.

## Open questions

- Where the 1Password item list comes from: `op item list --format json` through the located `op`, ids and names only. A locked vault shows the `op` sentence in the picker.
- `member rm` takes `--cloud-links keep|delete`; the Remove member sheet carries the choice, the argv mapping belongs to SG-16 (TASK-4b19).
