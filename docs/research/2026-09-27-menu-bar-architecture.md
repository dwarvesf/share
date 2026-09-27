# Menu bar app: architecture map

## Directory layout (share repo)
- `bin/share` (one file, ~56K) is the whole CLI; `bin/release`, `bin/changelog` are release tooling.
- `docs/decisions/ADR-000N-*.md` — one ADR per irreversible call.
- `docs/briefs/DECISION-BRIEF-<slug>.md` — pre-spec brief (problem, approaches table, chosen + why, diagram).
- `docs/specs/SPEC-00N-<slug>.md` — behavior contract, gates the ship-gate.
- `docs/verification/<slug>.md` — proof-of-done record, one per spec/feature.
- `tests/share.sh`, `tests/e2e.sh` — bash suites, no framework.
- No `mac/` or Swift dir exists yet. ADR-0003 places the app at `mac/` (`ShareBarCore` lib + `ShareBar` exe) plus `mac/build.sh`.

## Error handling
Every bash entrypoint defines a local `die()`: `bin/share:41` `die() { echo "share: $*" >&2; exit 1; }`; `bin/release:14`, `bin/changelog:16` same shape, tool name in the prefix. `spacedown/scripts/release.sh` adds `has() { printf '%s' "$1" | grep -qF -- "$2"; }` to dodge `pipefail`+`grep -q` SIGPIPE false negatives — reuse `has()` verbatim if `mac/build.sh` greps command output.
Contract: `"<tool>: <reason>"` on stderr, `exit 1`, no stack trace. `serve` usage errors are the one deviation (`exit 64`, sysexits-style).

## Naming conventions
- Scripts: `bin/<verb-noun>`, no extension, executable; shebang varies by repo (`#!/bin/bash` in share, `#!/usr/bin/env bash` in spacedown) — follow the repo you're in.
- Functions: `cmd_<verb>` for CLI subcommands (`cmd_serve`, `cmd_prune`), snake_case helpers (`share_url`, `wait_running`, `host_ok`).
- Docs: `SPEC-00N-<slug>.md`, `ADR-000N-<slug>.md`, `DECISION-BRIEF-<slug>.md`, `docs/verification/<slug>.md` (unnumbered).
- Bundle ids: `foundation.d.<tool>[.<component>]` (spacedown: `foundation.d.spacedown.quicklook`; menu bar app's planned id: `foundation.d.share.bar`, ADR-0003:8).
- launchd label `foundation.d.share` is share's own login service — the menu bar app must not reuse it (ADR-0003 boundary: app never becomes a second owner of the daemon).

## How recent features were built
### Quick tunnel mode (SPEC-002)
Files: brief → `ADR-0002-quick-tunnel-mode.md` → `SPEC-002-quick-tunnel.md` (Status/Lane/ADR-link header, `## Behavior contract` numbered clauses) → `bin/share` edits → `tests/share.sh` → `docs/verification/quick-tunnel.md` (green run + negative control + spec-row-to-check-name table).

### Menu bar app (in flight, this branch)
Files so far: `docs/briefs/DECISION-BRIEF-menu-bar.md`, `docs/decisions/ADR-0003-menu-bar-reads-through-cli.md` (commit `48b6e6a`). No SPEC-003, no `mac/` code yet — brief/ADR is the design gate; a `SPEC-003-menu-bar.md` with a behavior contract for `share status --json` is the missing step before Swift. Locked decisions (reopen the ADR to change): AppKit `NSStatusItem`/`NSMenu` not SwiftUI `MenuBarExtra`; app reads state only via `share status --json` + runs CLI verbs, never touches share's files; JSON carries a `schema` int, additive-only; ships from `mac/` on the same repo/tag as the CLI.

### Release + quick tunnel + healthz (git log)
`de206da`, `03b70cd`, `ee6d588` each touch `bin/share` + `tests/share.sh` + a `docs/verification/*.md`, followed by a `docs: changelog for vX.Y.Z` commit from `bin/changelog`. Bug fixes (`efff820`, `5630f11`) get their own verification records too — verification isn't spec-exclusive.

## Shared utilities to reuse
- `bin/changelog` + `bin/release`: semver from conventional-commit subjects, tag+push, tap bump via a throwaway clone + `gh pr create`/`gh pr merge`. Menu bar app ships same repo/tag (ADR-0003) — likely rides this same `bin/release`, extended to build/sign/notarize `mac/build.sh`'s artifact before tagging, rather than a separate script. Spacedown has no `bin/release` at all (fully manual `scripts/release.sh`); share's auto-versioning is the better fit here.
- `spacedown/scripts/release.sh` `die()`/`has()` pair — copy into `mac/build.sh` if it greps command output under `set -euo pipefail`.
- `spacedown/integrations/build-safari.sh` header block is the template for `mac/build.sh`'s own header: documented env vars up top, `NO_INSTALL=1` = stop after build and print the path (ADR-0003 already names the same shape for `mac/build.sh`: assemble, sign, notarize, zip).

## Config pattern
`bin/share` uses env-override-then-config-file: `${SHARE_ROOT:-$HOME/share}`, `cfg()` (`bin/share:29`) greps `key=value` from `~/.config/share/config`. No YAML/env-files. The menu bar app never reads that config file itself (ADR-0003/brief §Failure modes): it shells out to `share status --json` and probes `/opt/homebrew/bin`, `/usr/local/bin`, `~/.local/bin` for the binary since GUI apps get no login-shell `PATH`.

## Release / signing (spacedown template)
`scripts/release.sh [--mas] [x.y.z]`: `build-safari.sh` (adhoc or `SIGN_ID=`Developer ID`) → `codesign --options runtime` → `notarytool submit --wait` → `stapler staple` → `spctl` Gatekeeper check → `ditto` zip + `hdiutil` dmg (dmg itself signed/notarized/stapled) → `gh release create` → older releases deleted unless `KEEP_OLD_RELEASES=1`.
Cask template: `homebrew-tools/Casks/spacedown.rb` (`cask` block, `url`+`sha256` from the release asset, `app "X.app"`, `zap trash: [~/Library/Containers/<bundle-id>]`, `livecheck { strategy :github_latest }`). ADR-0003's target `depends_on formula: "dwarvesf/tools/share"` cask shape has no existing example in this repo set — write it fresh.
Preconditions `release.sh` checks (not creates): Developer ID identity in login keychain, `notarytool store-credentials $NOTARY_PROFILE`, clean git tree — same three `mac/build.sh` should assert.
