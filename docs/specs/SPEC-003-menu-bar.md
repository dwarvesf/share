# Spec: menu bar app (Share Bar)
Generated: 2026-09-27
Status: APPROVED
Lane: full
References: `/Users/tieubao/workspace/dwarvesf/spacedown/scripts/release.sh` (Developer ID sign, `notarytool submit --wait`, `stapler staple`, `ditto -c -k --keepParent` zip: imitate its precondition checks and the notarize-then-staple order); `/Users/tieubao/workspace/dwarvesf/homebrew-tools/Casks/spacedown.rb` (cask shape: `livecheck`, `depends_on macos`, `zap`); `bin/share` `cmd_ls` (the row loop and `share_url` call the JSON output reuses).

## Problem

share is a CLI. To see whether links are live, what is shared, when a share expires, or who opened it, the user opens a terminal and runs `share status` or `share hits <id>`. Nothing on screen says the tunnel went down, and a user who never opens a terminal cannot share a file. Full framing: `docs/briefs/DECISION-BRIEF-menu-bar.md`.

## Solution

### Approaches considered

| Approach | What it is | Tradeoff |
|---|---|---|
| A. App parses share's files | Swift reads `index.tsv`, `config`, `serve.pid`, rebuilds URLs | Duplicates `share_url`; any CLI change to link shape breaks the app silently. |
| B. CLI JSON contract | New read-only `share status --json`; app renders it, runs CLI verbs for actions | One process spawn per menu open; one new public contract to keep stable. |
| C. Native engine | App reimplements share | Two engines. Rejected. |

### Chosen approach + why

B. The CLI stays the only code that knows what a share is (ADR-0003). The app is a view plus a verb runner. The JSON is testable in the existing bash suite.

UI toolkit is AppKit `NSStatusItem` + `NSMenu`, because `menuNeedsUpdate(_:)` refreshes at the instant the menu opens, per-share submenus can load hit counts lazily, and the status button can accept file drops. SwiftUI `MenuBarExtra` in menu style offers none of the three without AppKit escapes. The single window (setup) is SwiftUI inside an `NSWindow`.

The app ships with the CLI: same repo (`mac/`), same version tag, a cask `share-bar` whose `depends_on formula: "dwarvesf/tools/share"` installs both in one command.

### Extensibility & boundaries

- Load-bearing dimension: the kinds of share and the shape of their links. A new kind or link rule changes bash only; the app renders `url` and `kind` as given. A new JSON field is additive and ignored by older apps.
- Second dimension: number of shares. The menu lists every share; beyond 20 rows the list scrolls natively in `NSMenu`. No paging.
- Units:
  - `share status --json` (bash): read-only snapshot on stdout.
  - `ShareBarCore` (Swift library, no AppKit): locate the CLI, run a verb with a timeout, decode the snapshot, map it to menu rows. Pure and unit-tested.
  - `ShareBar` (Swift executable): status item, menu, drop target, setup window, login item.
  - `mac/build.sh`: assemble, sign, notarize, zip the app.

## Picture

```
 brew install --cask dwarvesf/tools/share-bar ──▶ formula share + Share Bar.app
                                                       │
 ┌────────────── Share Bar.app ──────────────┐         │
 │ NSStatusItem                              │         ▼
 │  ├─ menuNeedsUpdate ─▶ status --json ─────┼──▶ bin/share ──owns──▶ ~/share/index.tsv
 │  ├─ submenu open ────▶ hits <id> ─────────┼──▶                     ~/share/serve.pid
 │  ├─ drop / Share File… ─▶ add <path> ─────┼──▶                     ~/.config/share/config
 │  ├─ Remove… / Refresh ─▶ rm|refresh <id> ─┼──▶                     launchd foundation.d.share
 │  └─ Start/Stop ───────▶ start|stop ───────┼──▶
 │ Setup window ─────────▶ setup <host>|--quick
 │ Open at Login ────────▶ SMAppService.mainApp (the app only, never the daemon)
 └───────────────────────────────────────────┘
```

## Design

### Approaches considered + chosen

See `## Solution`. The design view adds one call: hit counts stay on the existing text verb `share hits <id>`, shown verbatim, instead of a second JSON verb. The line is already human-readable and the app only displays it.

### Diagram

ASCII by house rule (the operator's global rules forbid Mermaid); see `## Picture`.

### ADR link(s)

- `docs/decisions/ADR-0003-menu-bar-reads-through-cli.md`: the app reads only through the CLI; the JSON is a versioned public contract.

### Boundaries & failure modes

The app never reads or writes share's files, never starts the daemon at login, and never holds a Cloudflare credential. Failure handling: `## Failure modes`.

## Technical Design

### Interfaces (I/O contract)

**`share status --json`** (new). Consumes `config`, `index.tsv`, `serve.pid`, `quick.url`, the pub tree (for `share_url`). Produces on stdout, exit 0 in every state:

```json
{
  "schema": 1,
  "state": "serving",
  "mode": "named",
  "host": "s.han.ws",
  "service": true,
  "serves_here": true,
  "shares": [
    {"id": "3d324a", "name": "theme-check.md",
     "url": "https://s.han.ws/3d324a/theme-check.html",
     "kind": "snapshot", "source": "/tmp/x/theme-check.md",
     "added": "2026-09-27", "expires": 1759000000, "source_gone": false}
  ]
}
```

| Field | Values |
|---|---|
| `schema` | integer; 1 for this spec |
| `state` | `serving` (pid alive), `stopped` (set up, not running), `not_setup` (no hostname and not quick mode) |
| `mode` | `named` or `quick` |
| `host` | `serving_host` output; `null` when empty (quick mode before the first start) |
| `service` | `svc_installed` as a boolean |
| `serves_here` | `host_ok` as a boolean: this machine is in `hosts=` and may serve |
| `shares[].kind` | `live` when opts has `live`; `host` when opts has `host=`; else `snapshot` |
| `shares[].expires` | epoch seconds; `0` means never |
| `shares[].source_gone` | `true` only for a snapshot whose source path no longer exists; `false` for live and host |

Invariants: never prunes, never writes a file, never needs a TTY, never touches the clipboard. Removing or renaming a field bumps `schema`; adding one does not. Built with `jq -n`, since jq is already a required dependency.

**CLI verbs the app runs** (unchanged): `add <path>` (first stdout line is the link), `rm <id>`, `refresh <id>`, `hits <id>` (one text line), `start`, `stop`, `setup <host>`, `setup --quick`. On failure the last stderr line starts with `share: ` and is shown to the user.

**`ShareBarCore` Swift API**

```swift
struct Snapshot: Decodable { schema, state, mode, host?, service, servesHere, shares: [Share] }
struct Share: Decodable { id, name, url, kind, source, added, expires: Int, sourceGone }
enum CLI { static func locate(env:fileExists:) -> URL?; static func run(_ args: [String], timeout: TimeInterval) async -> CLIResult }
struct CLIResult { status: Int32; stdout: String; stderr: String; timedOut: Bool }
struct MenuModel { init(snapshot: Snapshot?, error: CLIError?, now: Date); header: String; rows: [Row]; iconServing: Bool }
struct Row { id; title; trailing; url; canRefresh: Bool }
```

CLI location order: `SHARE_BIN` env, then `/opt/homebrew/bin/share`, `/usr/local/bin/share`, `~/.local/bin/share`. The child process gets `PATH=/opt/homebrew/bin:/usr/local/bin:~/.local/bin:/usr/bin:/bin:/usr/sbin:/sbin`, because a GUI-launched app inherits no login-shell PATH and share calls caddy, cloudflared and jq by name. stdin is `/dev/null`. The child also gets `SHARE_CLIPBOARD=0`; the app copies links itself, so `add` never races it for the pasteboard.

Trailing text for a row: `live` for live kind; `never` for `expires == 0`; `expired` when `expires <= now`; otherwise the largest whole unit left, `<n>d left`, `<n>h left`, or `<n>m left` (floor, minimum `1m left`). A snapshot with `source_gone` appends ` · source gone`.

### Data model changes

None. `index.tsv` is unchanged.

### API changes

`share status --json` as above. `share status` without the flag is unchanged, still prunes.

### UI changes

Status icon: SF Symbol `antenna.radiowaves.left.and.right` while `state == serving`, `antenna.radiowaves.left.and.right.slash` otherwise, template image, no badge. After a successful add, the icon shows `checkmark` for 1.5 seconds.

```
 ● Serving at s.han.ws           (else "Stopped" / "Serving from another Mac" / "Not set up" / "share CLI not found" / error line)
 ─────────────
 team-guide/        2d left  ▸   Copy Link
 notes.html         11h left ▸   Open in Browser
 localhost:3000     live     ▸   Refresh                      (snapshots only)
 ─────────────                   12 hits, 4 visitors, last …  (loaded when the submenu opens)
 Share File…              ⌘N     ─────────
 Stop Sharing | Start Sharing    Remove…                      (NSAlert confirm)
 ─────────────
 Set Up…                         (only in not_setup)
 Copy Install Command            (only when the CLI is missing)
 Open at Login  ✓
 Quit Share Bar           ⌘Q
```

Setup window (SwiftUI, 420pt wide): a hostname field, a "Quick link, no domain needed" toggle that disables the field, an "Open Share Bar at login" checkbox (on), a Set Up button, and a monospaced read-only log that streams the process output. Cancel terminates a running setup. Success (exit 0) closes the window and refreshes the icon. Failure keeps the window open with the log.

Dropping one or more files or folders on the status button runs `share add` per path in order; the last link lands on the pasteboard. A dropped item that fails shows an alert naming the path and the CLI's error line; the others still run.

### Infrastructure changes

- `mac/` Swift package (swift-tools-version 5.9, platform macOS 13), targets `ShareBarCore`, `ShareBar`, `ShareBarCoreTests`.
- `mac/build.sh`: universal release build, `.app` assembly, sign, optional notarize, zip.
- CI: a `mac` job on `macos-latest` runs `swift test` and an unsigned `mac/build.sh`; `shellcheck` covers `mac/build.sh`.
- Release: `bin/release` builds, notarizes and uploads the app zip to the same GitHub release, then bumps a new cask `Casks/share-bar.rb` in `dwarvesf/homebrew-tools`.

## Task Breakdown

### Phase 1: Foundation

- [ ] TASK-001: `share status --json` in `bin/share`, plus tests in `tests/share.sh`. Accept: the JSON validates with `jq -e`; `state` is `not_setup` before setup; `serves_here` follows `hosts=`; after an add, the share's `url` equals the first line `share ls` prints for it; an expired row is still in `index.tsv` after `status --json` and gone after plain `status`; bash 3.2 parses the script (`/bin/bash -n bin/share`); shellcheck clean.
- [ ] TASK-002: `mac/` package with `ShareBarCore` and `ShareBarCoreTests`. Accept: `swift test --package-path mac` passes, covering snapshot decode (fixture from TASK-001's real output, plus an unknown extra field), a `schema: 2` snapshot flagged as newer, locate order with an injected file-exists check, `run` timing out on `sleep 5` with a 0.5s timeout, and every trailing-text rule including the boundaries (exactly 24h, exactly 60m, expired at `now`).

### Phase 2: Core

- [ ] TASK-003: `ShareBar` executable: status item, menu built in `menuNeedsUpdate`, per-share submenu (copy, open, refresh, lazy hits, remove with confirm), Start/Stop, Share File…, Open at Login, Quit, the CLI-missing and not-set-up states. Accept: `swift build --package-path mac` succeeds; launching the assembled app shows the item in the menu bar (captured screenshot of the open menu against a live `SHARE_ROOT`); no Dock icon.
- [ ] TASK-004: Drop target on the status button. Accept: dropping a file (driven by a test harness or by hand) creates a share visible in `share ls`, the link is on the pasteboard, and the icon shows the checkmark.
- [ ] TASK-005: Setup window. Accept: with `SHARE_CONFIG_DIR` pointed at an empty dir, the menu shows Set Up…; running quick setup from the window streams output and ends in `state: serving` or shows the CLI's error line; Cancel kills the child process (no `share setup` left in `ps`).

### Phase 3: Wiring

- [ ] TASK-006: `mac/build.sh [--notarize] <version>`. Accept: without signing env it produces an ad-hoc signed universal `Share Bar.app` whose `lipo -archs` lists `x86_64 arm64` and whose Info.plist has `LSUIElement=true`, bundle id `foundation.d.share.bar`, the given version; with `SIGN_ID` and `--notarize` it prints `Accepted` from notarytool, staples, and `spctl -a -vv` says `Notarized Developer ID`; the last stdout line is the zip path.
- [ ] TASK-007: CI `mac` job plus shellcheck of `mac/build.sh`. Accept: the workflow YAML parses (`actionlint` if present, else `python3 -c yaml.safe_load`), and the job's commands pass locally.
- [ ] TASK-008: `bin/release` builds and uploads the notarized app zip after the tag, waits for release.yml's GitHub release to exist, and writes `Casks/share-bar.rb` (version, sha256, url to the release asset, `depends_on formula: "dwarvesf/tools/share"`, `depends_on macos: ">= :ventura"`, `app "Share Bar.app"`, `zap`) through the same throwaway-clone PR path as the formula. A non-macOS host or missing identity skips the app with one line and still bumps the formula. Accept: a dry run (`RELEASE_DRY=1`) prints the cask it would write and the upload it would do; `brew style` passes on the written cask.
- [ ] TASK-009: Docs. README gains a "Menu bar app" section (install command, first-run states, the JSON contract pointer); `docs/how-it-works.md` gains the `status --json` contract; the formula caveats name the cask. Accept: `grep` finds each section; the JSON example in docs matches TASK-001's schema field for field.

## After state

- [ ] `share status --json` prints the snapshot above and writes nothing. (Today: `share status` is text only and prunes.)
- [ ] `swift test --package-path mac` passes. (Today: no Swift code.)
- [ ] `bash mac/build.sh 0.0.0` produces a universal ad-hoc signed `Share Bar.app` and zip.
- [ ] The CI workflow has a `mac` job.
- [ ] After a release, `brew install --cask dwarvesf/tools/share-bar` installs the formula and the notarized app. (Today: no cask.)
- [ ] Launching the app on the Mini shows the antenna icon; opening it lists the live shares with working Copy Link.

## Acceptance Criteria (global)

- [ ] All tasks pass their individual acceptance criteria.
- [ ] Tests cover the happy path and the edge cases below.
- [ ] No regressions: `bash tests/share.sh` stays green on macOS and Linux.

## Verification

```sh
bash tests/share.sh
shellcheck bin/share install.sh tests/share.sh tests/e2e.sh demo/render.sh mac/build.sh
swift test --package-path mac
bash mac/build.sh 0.0.0 && lipo -archs "mac/build/Share Bar.app/Contents/MacOS/ShareBar"
```

Negative control: re-insert a `cmd_prune` call at the top of the `--json` branch; the "status --json never prunes" check must fail.

## Edge Cases

1. No config at all: `state: not_setup`, `shares: []`, exit 0.
2. Quick mode before the first start: `host: null`; rows show URLs with `<pending>.trycloudflare.com` exactly as `share ls` does.
3. A name with spaces, quotes, a tab-free unicode name: JSON-escaped by jq, URL percent-encoded as `share_url` does today.
4. A `.md` share with a render: `url` points at the `.html`, same as `ls`.
5. Expired but not yet pruned: listed, trailing text `expired`.
6. `serve.pid` present but the process is dead: `state: stopped`.
7. `index.tsv` missing or empty: `shares: []`.
8. The CLI is older than this spec (`--json` unknown): non-zero exit, no JSON; the menu shows "Update share CLI" with the brew command.
9. `schema` greater than 1: the menu shows "Update Share Bar" in the header and renders what decodes.
10. The CLI moves (brew upgrade, uninstall) while the app runs: located again on every call; missing shows the install state.
11. A drop of a symlink or a dotfile-only folder: the CLI refuses; the alert shows its error line.
12. Two menu opens while a status call is in flight: the second reuses the in-flight result instead of spawning a second process.
13. Remove on a share another terminal already removed: the CLI's `no share with id` error shows in the alert; the menu refreshes.
14. Setup window closed mid-run: the child process is terminated.
15. Open at Login toggled when the app runs from outside /Applications: `SMAppService` status error shown in an alert, the toggle reverts.
16. This Mac is not in `hosts=` (another machine serves): header reads "Serving from another Mac", Start Sharing is hidden, and shares still list. Adding still works: the CLI copies the file and prints the link.

## Failure modes

| Failure class | Detection signal | Mitigation / recovery |
|---|---|---|
| CLI not on the GUI PATH | locate returns nil | fixed probe list plus `SHARE_BIN`; missing state with install command |
| CLI hangs (network in setup, a stuck `du`) | timeout fires | status 5s, verbs 60s, setup cancellable; error row, no frozen menu (calls run off the main thread) |
| Contract drift between app and CLI versions | `schema` > known, or decode error | degrade with an update hint; additive fields never break decode |
| Destructive click | Remove chosen | NSAlert confirm; CLI moves the copy to Trash, not delete |
| Notarization rejected at release | notarytool status not `Accepted` | `bin/release` prints the notarytool log, skips the cask bump, still bumps the formula; nothing published for the app |

## Out of Scope

- The tool rename (porch, kite, etc.). The display name and cask name live in one constant and one file each so the rename is a small follow-up.
- Creating live (port) shares or `--host` shares from the app: they need input the menu cannot express well. The CLI still does it.
- Auto-update inside the app (Sparkle): Homebrew updates the cask.
- Notifications, charts of visits, a Dock icon, Linux.
- Supervising or restarting the serve daemon: share's own login service owns it.

## Touches

- bin/**
- tests/**
- mac/**
- docs/**
- .github/**

## Decision Log

- DEC-001: The app reads only through `share status --json` (ADR-0003). Rejected: parsing files (drift), native engine (two engines).
- DEC-002: AppKit `NSStatusItem` over SwiftUI `MenuBarExtra`: refresh-on-open, lazy submenus, drop target. Rejected: `MenuBarExtra` menu style.
- DEC-003: Hits stay a text verb displayed verbatim. Rejected: a `hits --json` verb nobody but the display needs.
- DEC-004: Ship in the same repo and tag; the cask depends on the formula. Rejected: a separate repo (version skew, second release pipeline).
- DEC-005: Swift package plus a shell build script, no Xcode project. Rejected: an `.xcodeproj` (binary-ish diffs, needs Xcode for CI edits).
- DEC-006: No App Sandbox; Developer ID with hardened runtime. The app must spawn the CLI and the CLI reads the home directory. Rejected: sandbox plus XPC helper (large, no user benefit for a direct-download tool).
- DEC-007: Working name "Share Bar", bundle id `foundation.d.share.bar`, cask `share-bar`, pending the rename decision.

## Open questions

(none)
