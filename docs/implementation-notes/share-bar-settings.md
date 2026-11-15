# Implementation notes: Share Bar settings A

Delta from SPEC-009 TASK-4b14 to TASK-4b18. The spec rows are not restated. Popover notes: `share-bar-popover.md`.

## Decisions the spec left open

- D1. Logic lives in `ShareBarCore/Settings/` (tabs, tenant detail, impact sheets, key sources, flows, argv builders) so `swift test` covers it. Views, the store and the window live in `ShareBar/Settings/`.
- D2. Sheets are SwiftUI overlays inside the Settings window (a scrim and a card), not `NSWindow` sheets, as the prototype draws them. One window then holds every state, `screencapture -l` captures it whole, and the same overlay is reused by the Members tab.
- D3. Screens are reached through a DEBUG-only launch hook (`-ShareBarShotsScreen <script>`, `Settings/ShotsHooks.swift`) that calls the store's own methods (open a tab, select a tenant, open a sheet, type into a field, press its button). No pointer or key input reaches the desktop (owner, 2026-11-15). `Tests/fixtures/settings/run-shots.sh` launches the built app against a fake CLI and captures the window.
- D4. The fake CLI base is frozen, so `Tests/fixtures/settings/bin/share` wraps it: it answers `config`, `admin-token`, `minter-token`, `join`, `setup`, `start`, `stop`, `leave`, `teardown` with the journal step names of `bin/share`, holds at a chosen step (`SHARE_FAKE_HOLD_AT`), and writes the stopped journal into the scenario on SIGTERM. Every other verb goes to the base script.
- D5. The window surface is `primitive.window` (`Tokens.swift:89`) painted on the root of the window (`Settings/SettingsTheme.swift`). The goal quotes `#eff0f3` and `#2b2c31` as revision 8; the headless render of the design's `.win` samples `#f5f5f7` and `#26262a`, the same as the token. The quoted pair is the page and popover surface in the evidence render, not the window's own. The parity samples in `docs/verification/share-bar/settings-a/README.md` decide.
- D6. The Settings window is its own `SettingsStore`: it reads `profiles` itself and runs its verbs through its own `MutationQueue`. `StatusItemController` is not in this sub-goal's touches, so a mutation started here and one started from the popover do not queue behind each other. SG-16 owns the join.
- D7. A new tenant's profile name is the host with every non-alphanumeric run turned into `-` (`s.example.com` becomes `s-example-com`), kept to the CLI's profile-name pattern. Reversible: one function, `ProfileName.slug`.
- D8. `share join <host> <code>` needs a host, so the Join form has two fields (Hostname, Invite code); a pasted `share join <host> <code>` line fills both. The Set up form has no key pop-up: a new hostname has no stored admin command, so the key is always asked (once, for the commands of that action).
- D9. The cloud-storage button runs `setup <host> --r2 --bucket share-<host with - for .>`; the members button adds `--members --yes` after a confirm sheet that carries the CLI's own warning (a non-terminal run refuses without `--yes`). `state` carries no bucket name, so the app uses the convention; a tenant set up with another bucket gets the CLI's refusal sentence.
- D10. The CLI cannot read back `admin_token_cmd`, so Advanced remembers the picked source (kind, item name and vault name, or the command text) in the app's defaults. The 1Password item ids are the only identifiers that reach argv.
- D11. The owner and admin Key row of a tenant reads the source Advanced remembers ("Asks each time" when none), because `state` has no token block for them.
- D12. General's "Menu shows" sets the remembered Mine or Team scope of every tenant (the key `PopoverPrefs` already reads), so the popover follows it with no popover edit.
- D13. Roles in words, as the prototype: `origin` Owner; `tenant_origin` and `r2_profile` Admin; `member` Member.

- D14. Review round. Asked keys now cover every admin path: roll back, pause, remove member and invite ask for the admin key (and the minter key for add and remove) when their source is "Ask me each time", and all of them reach the child through its environment only. A remembered key source changes only after the CLI stored it. Resume shows only for the four journals this window starts; a teardown, migrate or member journal never gets a one-click Resume here. The Roll back sheet names the checked argv, not the journal's display string. Copy request shows for a member whose key is expiring, expired or invalid.
- D15. The fake CLI now refuses what the real one refuses: `setup --members` without `--yes`, an admin or minter path with no key in the environment and no stored command. That is how the shots now fail on the first two review findings.

## Open questions

- General's five toggles (copy after sharing, notification after sharing, and the three Notify me when) write their defaults but nothing reads them yet: the status item and notifications live in `StatusItemController`, outside this sub-goal's touches. SG-16 wires the readers (keys in `GeneralPrefs`).
- The Settings store flow logic (key gathering, chaining, the late-snapshot guard) lives in the executable target and is covered by the shots and the `FlowRunner` and `AskedKeyCommand` tests, not by a unit test of its own.

- Where the 1Password item list comes from: `op item list --format json` through the located `op`, ids and names only. A locked vault shows the `op` sentence in the picker.
- `member rm` takes `--cloud-links keep|delete`; the Remove member sheet carries the choice and `presentRemoveMember` builds the argv; the Members tab (TASK-4b19) calls it.
