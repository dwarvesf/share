# Context for implementation: menu bar app

## Stack

- CLI: one bash script, `bin/share` (about 1,230 lines). Must parse under macOS `/bin/bash` 3.2: no empty arrays under `set -u`, no heredoc inside `$( )`. Runtime deps: caddy, cloudflared, jq, curl, optional pandoc.
- App (new): Swift package at `mac/`, swift-tools-version 5.9, macOS 13 minimum, AppKit + SwiftUI + ServiceManagement. Local toolchain: Xcode 27, Swift 6.4. No third-party Swift dependencies.
- Tests: `tests/share.sh` (bash, isolated via `SHARE_ROOT`, `SHARE_CONFIG_DIR`, `SHARE_TUNNEL=0`, a `check "<name>" <expected> <actual>` helper); `swift test --package-path mac` for `ShareBarCore`.
- CI: `.github/workflows/ci.yml`, public repo, GitHub-hosted `ubuntu-latest` and `macos-latest` are allowed and free.

## Conventions

- Errors: `die() { echo "share: $*" >&2; exit 1; }`. The last stderr line of a failed verb starts with `share: `.
- Subcommands are `cmd_<verb>`; helpers are snake_case.
- A behavioral change gets a `docs/verification/<slug>.md` record: green run, negative control, and a table from spec criteria to test names.
- Commits: Conventional Commits, no co-author or "Generated with" trailers.
- Shell scripts under `set -euo pipefail` that grep command output use a `has()` helper (`printf '%s' "$1" | grep -qF -- "$2"`) to avoid SIGPIPE false negatives (from Spacedown `scripts/release.sh`).
- Bundle ids use the `foundation.d.` prefix. Never reuse `foundation.d.share` (the CLI's launchd label).

## Key files

| File | Why it matters |
|---|---|
| `bin/share:25-40` | config and state paths, env overrides |
| `bin/share:43-45` | `host_ok`, `running`, `row` |
| `bin/share:75-99` | `serving_host`, `share_url`: the link logic JSON must reuse |
| `bin/share:271-334` | `cmd_add`: link on stdout line 1, `SHARE_CLIPBOARD` gate at 326 |
| `bin/share:336-350` | `cmd_ls`: the row loop to mirror |
| `bin/share:387-401` | `cmd_hits`: one text line |
| `bin/share:714-726` | `cmd_status`: prunes first; `--json` must not |
| `bin/share:991-1010` | `cmd_setup`: prompts only when no hostname and stdin is a TTY |
| `bin/share` bottom `case` | subcommand dispatch |
| `tests/share.sh:1-40` | isolation and `check` helper |
| `bin/release` | semver, changelog, tag, formula bump via throwaway tap clone |
| `docs/research/2026-09-27-menu-bar-*.md` | full research notes |

## External dependencies

- Signing: `Developer ID Application: Dwarves Foundation Company Limited (W777S7V8TN)` in the login keychain; notarytool profile `DWARVES_NOTARY`. Both present on the release Mac. Recipe to imitate: `/Users/tieubao/workspace/dwarvesf/spacedown/scripts/release.sh` (build, `codesign --options runtime`, `ditto -c -k --keepParent`, `notarytool submit --wait`, `stapler staple`, `spctl -a -vv`).
- Tap: `dwarvesf/homebrew-tools` (`Formula/share.rb`, `Casks/spacedown.rb` as the cask shape).
