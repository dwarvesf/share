# Spec: menu bar app (Share Bar)
Generated: 2026-09-27
Status: APPROVED (built; validation gate overridden by the operator, see DEC-017)
Lane: full
References: `/Users/tieubao/workspace/dwarvesf/spacedown/scripts/release.sh` (Developer ID sign, `notarytool submit --wait`, staple the `.app`, then `ditto -c -k --keepParent` zip: imitate its precondition checks and order); `/Users/tieubao/workspace/dwarvesf/homebrew-tools/Casks/spacedown.rb` (cask shape: `livecheck`, `depends_on macos`, `zap`); `bin/share` `cmd_ls` and `share_url` (the row loop and link logic `share state` reuses).

## Problem

share is a CLI. To see whether links are live, what is shared, when a share expires, or who opened it, the user opens a terminal and runs `share status` or `share hits <id>`. Nothing on screen says the tunnel went down, and a user who never opens a terminal cannot share a file. Full framing: `docs/briefs/DECISION-BRIEF-menu-bar.md`.

## Solution

### Approaches considered

| Approach | What it is | Tradeoff |
|---|---|---|
| A. App parses share's files | Swift reads `index.tsv`, `config`, `serve.pid`, rebuilds URLs | Duplicates `share_url`; any CLI change to link shape breaks the app silently. |
| B. CLI JSON contract | New read-only verb `share state`; app renders it, runs CLI verbs for actions | One process spawn per refresh; one new public contract to keep stable. |
| C. Native engine | App reimplements share | Two engines. Rejected. |

### Chosen approach + why

B. The CLI stays the only code that knows what a share is (ADR-0003). The app is a view plus a verb runner.

The contract is a new verb, `share state`, not a `--json` flag on `status`. An older CLI dispatches `status` whatever follows it, so `status --json` there would prune and print text with exit 0. An older CLI given `state` falls to the unknown-verb branch: help text, exit 1, no write.

UI toolkit is AppKit `NSStatusItem` + `NSMenu`: the menu delegate refreshes on open, per-share submenus load hit counts lazily, and the status button accepts file drops. The setup window is SwiftUI inside an `NSWindow`.

The app ships with the CLI from the same repo (`mac/`) and version tag. A cask `share-bar` with `depends_on formula: "dwarvesf/tools/share"` installs both in one command.

### Extensibility & boundaries

- Load-bearing dimension: kinds of share and link shapes. A new kind or link rule changes bash only; the app renders `url`, `kind`, and `own_host` as given. New JSON fields are additive; older apps ignore them.
- Second dimension: number of shares. `share state` stays under 1 second for 500 rows on an idle Mac (fork-free row loop, one `jq` call). The menu shows the 25 newest shares and a disabled "N more (share ls)" line.
- Units:
  - `bin/share` hardening: index lock, id collision loop, name validation, `quick.url` lifecycle, fork-free `share_url`, streamed `hits`.
  - `share state` (bash): read-only snapshot on stdout.
  - `ShareBarCore` (Swift library, no AppKit): locate the CLI, spawn it with the right PATH and process group, read both pipes while it runs, decode the snapshot, map it to menu rows, serialize mutating verbs.
  - `ShareBar` (Swift executable): status item, menu, drop target, setup window, login item, poll timer.
  - `mac/build.sh` and `mac/release.sh`: assemble, sign, notarize, zip, publish, cask bump.

## Picture

```
 bin/release ─▶ tag ─▶ formula bump ─▶ mac/release.sh ─▶ build.sh (sign, notarize, staple) ─▶ zip on the GitHub release ─▶ tap PR: Casks/share-bar.rb + formula caveats

 brew install --cask dwarvesf/tools/share-bar ──▶ formula share + Share Bar.app
                                                       │
 ┌────────────── Share Bar.app ──────────────┐         │
 │ poll 60s / wake / menu open ─▶ state ─────┼──▶ bin/share ──owns──▶ ~/share/index.tsv (locked writes)
 │ submenu open ──────▶ hits <id> ───────────┼──▶                     ~/share/serve.pid, quick.url
 │ drop / Share File… ─▶ add <path> ─┐        │                        ~/.config/share/config
 │ Remove… / Refresh ─▶ rm|refresh ──┼─ serial queue ─▶               launchd foundation.d.share
 │ Start / Stop ──────▶ start|stop ──┘        │
 │ Setup window ──────▶ setup <host>|--quick (own process group, cancellable)
 │ Open at Login ─────▶ SMAppService.mainApp (the app only, never the daemon)
 └───────────────────────────────────────────┘
```

## Design

### Approaches considered + chosen

See `## Solution`. The design view adds: hit counts stay on the text verb `share hits <id>`, shown verbatim.

### Diagram

ASCII by house rule (the operator's global rules forbid Mermaid); see `## Picture`.

### ADR link(s)

- `docs/decisions/ADR-0003-menu-bar-reads-through-cli.md`

### Boundaries & failure modes

The app never reads or writes share's files, never starts the daemon at login, and never holds a Cloudflare credential. Failure handling: `## Failure modes`.

## Technical Design

### Interfaces (I/O contract)

**`share state`** (new verb). Prints on stdout, exit 0 in every state:

```json
{
  "schema": 1,
  "state": "serving",
  "ready": true,
  "mode": "named",
  "host": "s.han.ws",
  "hosts": "hans-air-m4",
  "serves_here": true,
  "service": true,
  "shares": [
    {"id": "3d324a", "name": "theme-check.md",
     "url": "https://s.han.ws/3d324a/theme-check.html",
     "kind": "snapshot", "own_host": null, "expires": 1759000000}
  ]
}
```

| Field | Values |
|---|---|
| `schema` | integer, 1 |
| `state` | `serving` (pid alive), `stopped` (set up, not running), `not_setup` (no hostname and not quick mode) |
| `ready` | named mode: `curl -sf -m 1 127.0.0.1:<metrics_port>/ready` succeeds; quick mode: serving and `quick.url` non-empty; with `SHARE_TUNNEL=0`: equal to serving; `false` when not serving |
| `mode` | `named` or `quick` |
| `host` | named: the configured hostname; quick: `quick.url` content only while serving, else `null` |
| `hosts` | the `hosts=` config value, `""` when unset |
| `serves_here` | `host_ok` as a boolean |
| `service` | `svc_installed` as a boolean |
| `shares[]` | ordered newest first (reverse `index.tsv` order) |
| `shares[].kind` | `live` when opts has `live`, else `snapshot` |
| `shares[].own_host` | the `host=` value, else `null` |
| `shares[].expires` | epoch seconds; `0` means never |
| `shares[].url` | exactly what `share ls` prints for that row |

Invariants: never prunes, never writes or creates a file, never needs a TTY, never touches the clipboard. Removing or renaming a field bumps `schema`; adding one does not. A row with 5 fields (v0.1.x) is read with empty opts; a row is skipped, and counted in a top-level `"skipped": <n>` field (present only when non-zero), when it has fewer than 5 or more than 6 tab fields, when its id is not exactly 6 lowercase hex characters, or when its `host=` opt is the main hostname or fails the hostname pattern. Rows are emitted as TSV from a fork-free bash loop and converted by one `jq -R` pass.

**CLI verbs the app runs** (existing): `add <path>`, `rm <id>`, `refresh <id>`, `hits <id>`, `start`, `stop`, `setup <host>`, `setup --quick`. After any verb, the app runs `state` again and renders from it; it never parses `add`'s stdout for the link. On a non-zero exit it shows the last non-empty stderr line, or `share exited <n>` when stderr is empty. On exit 0 it shows an alert for any stderr line starting `share: WARNING` (the private-repo warning), with a Remove button for that share.

**`bin/share` hardening** (behavior changes to existing verbs):

- `index_lock` covers the whole publish step of `add` and `rm`: the index write, `write_caddyfile`, and `caddy_reload`. It is taken after `host_add`/`host_rm` return and released after the reload. `write_caddyfile` renders to a `mktemp` file in `$root` and moves it into place, so caddy never reads a half-written file. The index rewrite also goes through `mktemp`.
- Both locks use one acquire function, `lock_take <name>`: the lock is a symlink `$root/.lock-<name>` whose target is the holder's pid, created atomically with `ln -s`. A waiter that reads a target pid that `kill -0` says is dead removes the link and retries (stale-lock rule). `host_lock` moves onto it, so a leaked host lock no longer needs a manual `rmdir`. Inside a subshell `$$` is the parent's pid (bash 3.2 has no `BASHPID`), so a lock taken during `prune`'s pipeline is recovered once the parent exits; that is accepted.
- Lock cleanup: `lock_take` appends the path to a global `held_locks` and re-arms `trap release_locks EXIT` on every take (the same handler, so re-arming is idempotent and also covers subshells, which do not inherit EXIT traps). `cmd_serve`'s existing EXIT trap calls `release_locks` as its first step. No other function sets an EXIT trap.
- `cf()` gains `--max-time 30`, so a stalled Cloudflare call cannot hang an own-host `add` or `rm` forever.
- `rm` on a share with `own_host` refuses before any change when neither `CLOUDFLARE_API_TOKEN` nor `$config_dir/cert.pem` is present: `share: no Cloudflare credential for <host>; set CLOUDFLARE_API_TOKEN or run share setup --login, then rm again`, exit 1. `prune` keeps today's behavior for such a share (removes the copy, warns that DNS stays behind), so expiry is never blocked.
- Every `write_caddyfile` plus `caddy_reload` pair runs under `index_lock`, in `add`, `rm`, `refresh`, and `cmd_serve` startup. In `add` the lock is released after the reload and before `share_url`, the clipboard step, and `cmd_start`; when nothing is serving, `add` releases it before `cmd_start` (serve's own startup prune and render take the lock themselves).
- Breaking a stale lock: the waiter renames the link to a unique name (`mv` to `.lock-<name>.stale.$$`), reads the moved link's target, and removes it only when that pid is still dead; otherwise it moves it back. Two waiters can never both break a live lock. `cmd_serve` takes its locks only before it sets its own EXIT trap; the hourly prune runs as a separate `bash "$0" prune` process, so it never shares serve's trap.
- Index rows with 5 fields (written by v0.1.x) are read with empty opts, in `state` and everywhere else; only rows with fewer than 5 or more than 6 fields are skipped.
- `rand_id` loops until the id is not in the index and `pub/<id>` does not exist.
- `add` refuses the whole realpath containing a tab or a newline: `share: paths with tabs or newlines are not supported`. It also refuses a source name containing `{`, `}`, `"`, or `\`: `share: names with { } " or \ are not supported` (unescaped, `{...}` expands as a Caddy placeholder in `root *`, and `"` breaks the rendered Caddyfile line). `--host` refuses the main hostname: `share: --host cannot be the main hostname` (a row hiding it from `rows()` while staying served).
- `quick.url` is removed by `cmd_stop` and by the serve process's exit trap.
- `urlenc` becomes pure bash and fork-free: an `LC_ALL=C` byte loop that sets its result in a global (no `$( )`), keeps exactly `A-Za-z0-9-_.~` and `/`, and writes every other byte as `%XX` in uppercase hex. The byte value is masked with `$((c & 255))`, because bash 3.2's `printf '%d' "'c"` sign-extends bytes above 127. The keep-set is the contract; it matches `jq @uri` in jq 1.7 and later, so `gen_index` links do not change. A test compares both encoders over a fixed name list: spaces, `#?%&+=`, `!*'()`, `é`, CJK, emoji.
- `share_url` sets its result in a global without forking (`printf -v`, parameter expansion, `[[ -d ]]`/`[[ -f ]]` tests) and encodes the path with the new `urlenc`. `cmd_ls` output is unchanged for names made of unreserved characters and spaces; names with `#`, `?`, `%` or non-ASCII now print working links where they printed broken ones.
- `hits` streams the access log (`jq -n '[inputs | …]'`) instead of slurping it.

**`ShareBarCore` Swift API**

```swift
struct Snapshot: Decodable { schema, state, ready, mode, host?, hosts, servesHere, service, shares: [Share], skipped? }
struct Share: Decodable { id, name, url, kind, ownHost?, expires: Int }
enum CLI {
  static func locate(env: [String: String], fileExists: (String) -> Bool) -> URL?
  static func run(_ args: [String], timeout: TimeInterval?) async -> CLIResult   // nil timeout = never killed
  static func spawnCancellable(_ args: [String], onOutput: (String) -> Void) -> CLIJob // setup
}
struct CLIResult { status: Int32; stdout: String; stderr: String; timedOut: Bool }
actor MutationQueue { func run(_ args: [String]) async -> CLIResult }   // one mutating verb at a time
struct MenuModel { init(snapshot: Snapshot?, failure: Failure?, now: Date); header; rows: [Row]; more: Int; icon: Icon; showStart: Bool; showSetUp: Bool }
struct Row { id; title; trailing; url; canRefresh: Bool; canCopy: Bool; removeText: String }
```

- Location order: `SHARE_BIN`, `/opt/homebrew/bin/share`, `/usr/local/bin/share`, `$HOME/.local/bin/share`, `/opt/local/bin/share`. `$HOME` is expanded in Swift.
- Child environment: inherited, plus `PATH` = the resolved CLI's directory, then `/opt/homebrew/bin:/opt/homebrew/sbin:/usr/local/bin:$HOME/.local/bin:/opt/local/bin:$HOME/.nix-profile/bin:/nix/var/nix/profiles/default/bin:/usr/bin:/bin:/usr/sbin:/sbin`, `LANG=en_US.UTF-8` when unset, `SHARE_CLIPBOARD=0`. stdin is `/dev/null`.
- Spawning uses `posix_spawn` with `POSIX_SPAWN_SETPGROUP`, so a kill reaches grandchildren. Both pipes are drained while the process runs; a run completes when the process exits and both pipes hit EOF.
- Timeouts: `state` 10s, `hits` 15s, both TERM the group, then KILL after 3s. Mutating verbs (`add`, `rm`, `refresh`, `start`, `stop`) have no timeout and are never killed automatically; the header shows "Working…" while one runs. After 60 seconds the menu adds "Stop Waiting…", which asks first and then TERMs the group, so a stuck call cannot block the queue forever. The confirm text says: "The share may be left half-published; run it again from the terminal to finish. If sharing was starting, this also stops it." (Without a login service, `start` runs serve in the app's process group, so the TERM reaches it.) Setup is cancellable (TERM the group, KILL after 3s).
- A `state` call already in flight is shared, not duplicated.
- The app logs every spawn (argv, exit status, duration, timed out) and every decode failure through `os_log`, subsystem `foundation.d.share.bar`, category `cli`. `log stream --predicate 'subsystem == "foundation.d.share.bar"'` is the debugging entry point, named in the README.

Trailing text: `live` for live kind; `never` for `expires == 0`; `expired` when `expires <= now`; else the largest whole unit left, `<n>d left`, `<n>h left`, `<n>m left` (floor, minimum `1m left`). A row with `own_host` shows the host as its title.

Header text, first match wins, in this order: `share CLI not found`; `Update share CLI`; `Update Share Bar`; the failure line; `Not set up`; `Not serving on this Mac (hosts=<hosts>)`; `Stopped`; `Serving, tunnel not connected`; `Serving at <host>`. Definitions: `Serving at <host>` (serving and ready); `Serving, tunnel not connected` (serving, not ready); `Stopped`; `Not serving on this Mac (hosts=<hosts>)` (not serving and `serves_here` false); `Not set up`; `share CLI not found`; `Update share CLI` (exit 1 and stdout starts with the CLI's help text, which is how a CLI without `state` answers); `Update Share Bar` (`schema` > 1); for any other failure, `share: ` plus the last stderr line, or `share exited <n>`.

Model rules, all unit-tested in `ShareBarCore`: `canCopy` is false when `url` contains `<pending>` or `<no-hostname>`; `canRefresh` is true only for `snapshot`; `removeText` is "Remove <name>? The copy goes to the Trash." for plain shares and "Remove <name>? This also deletes the DNS record for <own_host>." for own-host shares (true because `rm` refuses when it cannot delete the record); `showStart` is false when serving or when `serves_here` is false; `showSetUp` is true whenever the state is not `serving`; rows are capped at 25 and `more` holds the rest.

### Data model changes

None to `index.tsv`'s columns. Writes gain a lock.

### API changes

New verb `share state`. `share status` and `share ls` are unchanged in output.

### UI changes

Status icon: template SF Symbol `antenna.radiowaves.left.and.right` when serving and ready, `antenna.radiowaves.left.and.right.slash` otherwise; `checkmark` for 1.5s after a successful add. `accessibilityLabel` mirrors the header text. The icon state refreshes from `state` every 60 seconds, on wake (`NSWorkspace.didWakeNotification`), and on menu open.

```
 Serving at s.han.ws              (header, see Header text)
 ─────────────
 team-guide/        2d left  ▸    Copy Link
 notes.html         11h left ▸    Open in Browser
 localhost:3000     live     ▸    Refresh                       (snapshots only)
 … 12 more (share ls)             hits line, "Loading…" until it returns
 ─────────────                    ─────────
 Share File…              ⌘N      Remove…      (confirm; text differs for own_host shares:
 Stop Sharing | Start Sharing                    "also deletes the DNS record for <host>")
 ─────────────
 Set Up…                          (not_setup only)
 Copy Install Command             (CLI missing only)
 Open at Login  ✓
 ─────────────
 About Share Bar
 Quit Share Bar           ⌘Q
```

- The menu opens instantly from the last snapshot; the fresh `state` result replaces the items in place on the main queue (run loop common modes), so the open menu updates.
- Copy Link and Open are disabled when the `url` contains `<pending>` or `<no-hostname>`.
- Start Sharing follows `showStart`. Set Up… follows `showSetUp` and opens the window prefilled with the current host, because rerunning `share setup <host>` is the recovery for a setup that was cancelled or failed halfway.
- Hits: one call in flight; opening another submenu cancels the previous one; results cached until the menu closes.
- Adding on a Mac where `serves_here` is false shows an alert after the add: the link works only once a Mac in `hosts=` serves it.

Setup window (SwiftUI, 420pt wide): hostname field, "Quick link, no domain needed" toggle that disables the field, "Open Share Bar at login" checkbox (on), Set Up button, monospaced read-only log streaming the child output, Cancel. While the window is open the app switches to `.regular` activation policy (Dock icon, Cmd-Tab), back to `.accessory` on close. Success closes the window and refreshes. Failure keeps the log. Cancel or closing the window terminates the setup process group and shows "Setup cancelled; Set Up again to finish". Quitting the app while setup runs terminates the group in `applicationWillTerminate`.

Drop target: first spike whether AppKit delivers drags to a subview whose `hitTest` returns nil; if it does not, register on `statusItem.button.window` with a window-level drag handler instead. The planned shape is a transparent `DropView: NSView` added as a subview of the status item's button, sized to it, implementing `NSDraggingDestination` and registered for `[.fileURL]` (its `hitTest` returns nil so clicks reach the button). A drop that contains a folder asks first: "Publish the folder <name> at a public link for 30 days?" with Publish and Cancel. Each dropped path runs `add` in order through the mutation queue. The app records the share ids from `state` before the batch and copies the `url` of the id that is new afterwards (the last new one for a batch). File promises (Mail attachments, Photos) are refused with an alert. Folders chosen through Share File… get the same confirm.

Open at Login reads `SMAppService.mainApp.status` each time the menu opens (`.enabled` shows ✓, `.requiresApproval` shows "Open at Login (approve in System Settings)" and opens Login Items settings). The setup checkbox registers it.

### Infrastructure changes

- `mac/` Swift package (swift-tools-version 5.9, macOS 13), targets `ShareBarCore`, `ShareBar`, `ShareBarCoreTests`.
- `mac/Info.plist`: `CFBundleIdentifier foundation.d.share.bar`, `CFBundleName`/`CFBundleDisplayName` "Share Bar", `CFBundleExecutable ShareBar`, `CFBundlePackageType APPL`, `LSUIElement true`, `LSMinimumSystemVersion 13.0`, `CFBundleShortVersionString`/`CFBundleVersion` set by the build, `NSDocumentsFolderUsageDescription`, `NSDesktopFolderUsageDescription`, `NSDownloadsFolderUsageDescription`, `NSRemovableVolumesUsageDescription`, `NSNetworkVolumesUsageDescription` (each: "share copies the files you choose so it can publish them").
- `mac/build.sh [--sign] [--notarize] <version>`: universal release build, bundle assembly, sign (ad-hoc without `--sign`), notarize and staple the `.app`, then zip. Last stdout line is the zip path.
- `mac/release.sh <tag>`: runs `build.sh --sign --notarize`, waits up to 5 minutes for the tag's GitHub release to exist (`gh release view` every 10s; `release.yml` creates it asynchronously), uploads the zip with `--clobber`, writes `Casks/share-bar.rb` through a throwaway tap clone PR and merges it; a rerun for the same tag force-updates an open cask PR branch. The same tap PR adds a caveats line to `Formula/share.rb` naming the cask (idempotent: skipped when present). It is idempotent, so the recovery for "formula released, cask did not" is rerunning `mac/release.sh <tag>`. `bin/release` calls it after the formula bump when on macOS with the signing identity; otherwise it prints `CASK NOT RELEASED: run mac/release.sh <tag> on a signing Mac` and exits 3.
- Signing inputs: the Developer ID Application identity for team `W777S7V8TN` in the release Mac's login keychain (its p12 lives in 1Password vault dfoundation-prod) and the notarytool keychain profile `DWARVES_NOTARY` (from the App Store Connect API key). `build.sh` checks both and never creates them; a missing one is named and the script exits. As an alternative to the profile, `NOTARY_KEY` (path to the `.p8`), `NOTARY_KEY_ID`, and `NOTARY_ISSUER` authenticate `notarytool` directly with the App Store Connect key (item "Hacker Bar Release" in dfoundation-prod); this is the mode an unattended release uses, since storing a keychain profile needs an interactive keychain. Rotation: import the new p12 into the keychain and rerun `xcrun notarytool store-credentials DWARVES_NOTARY`.
- CI: a `mac` job on `macos-latest` runs `swift test --package-path mac` and `bash mac/build.sh 0.0.0`; shellcheck adds `mac/*.sh`.

## Task Breakdown

### Phase 1: Foundation

- [x] TASK-001: Locks and the publish critical section. `lock_take` with pid symlinks and the rename-then-check stale rule, `host_lock` moved onto it, `index_lock` around every index write plus `write_caddyfile` (via `mktemp`) plus `caddy_reload` in `add`, `rm`, `refresh`, and serve startup, the re-armed `release_locks` trap, `cmd_serve`'s trap calling it. Accept: in `tests/share.sh`, 6 parallel `rm` plus 6 parallel `add` end with exactly the expected rows and a Caddyfile listing exactly the surviving ids; a lock whose pid is dead is broken and the command succeeds; a `host_rm` die leaves neither `.lock-host` nor `.lock-index`; a die inside `prune`'s pipeline leaves no lock; a `refresh` running during parallel `add`/`rm` leaves a Caddyfile listing exactly the surviving ids; `/bin/bash -n bin/share` and shellcheck pass. -- DONE (commit: b7c0d06, c0e372b, verified)
- [x] TASK-016: Small CLI hardening. `cf()` `--max-time 30`; `rand_id` collision loop; tab/newline name refusal; `rm` refusal on an own-host share without a credential; 5-field rows read with empty opts. Accept: with a stubbed `curl` that sleeps, `cf` returns within 35s; with a stubbed `rand_id` source returning a taken id twice, `add` gets a third id; a tab name and a newline name are each refused; `rm` of a `host=` row with no credential exits 1 and leaves the row and the payload in place, while `prune` of the same row past expiry removes it and warns; a 5-field row lists in `share ls` and in `state`. -- DONE (commit: 849b823, verified)
- [x] TASK-002: `quick.url` lifecycle. Accept: after `stop` in quick mode the file is gone; after the serve process exits the file is gone. -- DONE (commit: 92b22c8, verified)
- [x] TASK-003: Pure-bash `urlenc` and fork-free `share_url`. Accept: the encoder comparison test passes over the fixed name list under `/bin/bash` 3.2; a name with `#` and `é` serves 200 through the printed link; `share ls` output is unchanged for the existing fixtures. -- DONE (commit: 9907e04, verified)
- [x] TASK-004: Streamed `hits`. Accept: output is byte-identical to the slurping version on the test log. -- DONE (commit: e25b3c4, verified)
- [x] TASK-005: `share state`. Accept: `jq -e` validates it in `not_setup`, `stopped`, and serving (`SHARE_TUNNEL=0`); each share's `url` equals its `share ls` line; `kind` and `own_host` are right for snapshot, live, and host rows; `find "$SHARE_ROOT" "$SHARE_CONFIG_DIR" -newer <marker>` is empty after `state` with an expired row present; a 500-row index finishes under 3s in the suite (target under 1s on an idle Mac, measured time recorded); `state` on the v0.5.1 script (`git show v0.5.1:bin/share`; the CI checkout sets `fetch-depth: 0`) exits 1 and writes nothing; `ready` equals serving under `SHARE_TUNNEL=0`. -- DONE (commit: 30edf55, 4065d9e, verified)
- [x] TASK-006: `mac/` package and the `ShareBarCore` CLI runner: locate, `posix_spawn` with its own process group, both pipes drained while running, timeouts with TERM then KILL, the shared in-flight `state` call, `MutationQueue`. Accept: `swift test --package-path mac` covers locate order with an injected file check and expanded `$HOME`; a 200KB stdout child completes; a `state` timeout kills a `sleep 30` grandchild; two queued verbs run strictly in order; concurrent `state` requests spawn one process. -- DONE (commit: a8b5461, verified)
- [x] TASK-007: `ShareBarCore` model: `Snapshot` decode and every `MenuModel` rule. Accept: `swift test` covers decode of a real `state` fixture plus an unknown extra field; every header rule, including exit 1 with help text versus a jq-missing stderr line and `schema: 2`; every trailing-text rule with boundaries (exactly 24h, exactly 60m, `expires == now`); `canCopy`, `canRefresh`, `removeText`, `showStart`, `showSetUp`; the 25-row cap. -- DONE (commit: e47258b, 605167b, c5a4046, verified)

### Phase 2: Core

- [x] TASK-008: Status item and menu rendering: header, rows, submenus, instant open from the cached snapshot with in-place update, 60s poll, wake refresh, accessibility label. Accept: `swift build` succeeds; the app run against a test `SHARE_ROOT` shows the item with no Dock icon; a screenshot of the open menu goes into the verification record; manual checks recorded there: an open menu updates when `state` returns, the icon changes within 60s after `share stop` in a terminal, the icon refreshes after sleep and wake. -- DONE (commit: fb69b65, f0f868e, 1e8d741, verified)
- [x] TASK-009: Read and app actions: Copy Link, Open, lazy hits (one in flight, cancel on switch, cached per open), Set Up…, Copy Install Command, the brew command on Update share CLI, Open at Login, Quit, `os_log` logging. Accept: each run by hand against a test `SHARE_ROOT` has the effect the spec names, recorded in the verification record, including the `.requiresApproval` login state, a hits call cancelled by opening another submenu, and `log stream` showing a spawn line. -- DONE (commit: 791c847, f2466a0, verified)
- [x] TASK-017: Mutating actions: Refresh, Remove with confirm, Start/Stop, Stop Waiting…, Share File… with the folder confirm, the private-repo WARNING alert with Remove, the not-serving-here alert after an add. Accept: each run by hand against a test `SHARE_ROOT` has the effect the spec names, recorded in the verification record; a verb stubbed to sleep 90s shows Stop Waiting… after 60s. -- DONE (commit: 5491a68, 88c8306, verified)
- [x] TASK-010: Drop target. Accept: dropping a file creates a share visible in `share ls`, its link is on the pasteboard, the icon shows the checkmark; dropping a folder asks first and Cancel publishes nothing; a file-promise drag is refused. -- DONE (commit: 3ae7a27, verified)
- [x] TASK-011: Setup window. Accept: with an empty `SHARE_CONFIG_DIR`, the menu shows Set Up…; the window streams output; Cancel and Quit each leave no member of the setup process group alive (`pgrep -g <pgid>` empty); no Dock icon after the window closes. -- DONE (commit: 43fe5cc, verified)

### Phase 3: Wiring

- [x] TASK-012: `mac/Info.plist` and `mac/build.sh`. Accept: without `--sign` it produces an ad-hoc signed universal app (`lipo -archs` lists `x86_64 arm64`) with every Info.plist key above and the given version; with `--sign --notarize` notarytool reports `Accepted`, `xcrun stapler validate` passes on the `.app`, and `spctl -a -vv` says `Notarized Developer ID`; a missing identity exits non-zero naming it. -- DONE (commit: b13fd33, 992dd2a, verified)
- [x] TASK-013: CI `mac` job and shellcheck of `mac/*.sh`. Accept: the workflow YAML parses and the job's commands pass locally. -- DONE (commit: 8341eac, verified)
- [x] TASK-014: `mac/release.sh` and the `bin/release` hook. Cask: `version`, `sha256`, `url` to the release asset, `livecheck` (`strategy :github_latest`), `depends_on formula: "dwarvesf/tools/share"`, `depends_on macos: :ventura`, `app "Share Bar.app"`, `uninstall quit: "foundation.d.share.bar"`, `zap trash: "~/Library/Preferences/foundation.d.share.bar.plist"` (never `~/share`, `~/.config/share`, or the `foundation.d.share` LaunchAgent, which the formula owns). The tap PR also adds the formula caveats line. Accept: `RELEASE_DRY=1 mac/release.sh v0.0.0` prints the cask, the caveats edit, and the upload without writing; `brew style` passes on the printed cask; `bin/release` without the identity prints the CASK NOT RELEASED line and exits 3. -- DONE (commit: ec13440, 974a0cc, 54db7ec, 0600277, verified)
- [x] TASK-015: Docs. README "Menu bar app" section (install, first-run states), `docs/how-it-works.md` gains the `share state` contract, and a `docs/verification/menu-bar.md` record. Accept: a test greps each JSON field name of the implemented output in the docs. -- DONE (commit: 92510eb, verified)

## After state

- [ ] `share state` prints the snapshot and writes nothing. (Today: no JSON; `status` and `ls` prune.)
- [ ] Parallel `add`/`rm` no longer lose rows. (Today: they do.)
- [ ] `swift test --package-path mac` passes. (Today: no Swift code.)
- [ ] `bash mac/build.sh 0.0.0` produces a universal ad-hoc signed `Share Bar.app` and zip.
- [ ] CI runs a `mac` job.
- [ ] After a release, `brew install --cask dwarvesf/tools/share-bar` installs the formula and the notarized app. (Today: no cask.)
- [ ] The app on the Mini shows the antenna icon; opening it lists live shares with working Copy Link.

## Acceptance Criteria (global)

- [ ] All tasks pass their acceptance criteria.
- [ ] Tests cover the happy path and the edge cases below.
- [ ] No regressions: `bash tests/share.sh` stays green on macOS and Linux.

## Verification

```sh
bash tests/share.sh
shellcheck bin/share install.sh tests/share.sh tests/e2e.sh demo/render.sh mac/*.sh
swift test --package-path mac
bash mac/build.sh 0.0.0 && lipo -archs "mac/build/Share Bar.app/Contents/MacOS/ShareBar"
```

Negative controls: (1) add a `cmd_prune` call at the top of `cmd_state`: the "state writes nothing" check fails; (2) remove the index lock from `cmd_rm`: the parallel-writers check fails; (3) make `urlenc` keep `#`: the encoder comparison fails; (4) render the Caddyfile after releasing `index_lock`: the parallel Caddyfile check fails.

## Edge Cases

1. No config at all: `state: not_setup`, `shares: []`, exit 0.
2. Quick mode, stopped: `host: null`; rows carry `<pending>.trycloudflare.com` URLs; Copy and Open are disabled.
3. Names with spaces, `#`, `?`, `%`, non-ASCII: JSON-escaped by jq, URL-encoded by `urlenc`, link serves 200.
4. A name with a tab or newline: `add` refuses it.
5. A `.md` share with a render: `url` points at the `.html`.
6. Expired but not yet pruned: listed, trailing text `expired`.
7. `serve.pid` present, process dead: `state: stopped`, `ready: false`.
8. Serving, tunnel dropped: `ready: false`, header "Serving, tunnel not connected", slashed icon within 60s.
9. `index.tsv` missing or empty: `shares: []`.
10. A malformed row: skipped, counted in `skipped`, the rest render.
11. The CLI predates `state`: exit 1 with help text, nothing written; header "Update share CLI" with the brew command.
12. `schema` > 1: header "Update Share Bar", decodable fields still render.
13. The CLI moves (brew upgrade) while the app runs: located again on every call.
14. Drop of a symlink or a dotfile-only folder: the CLI refuses; the alert shows its error line.
15. Two refreshes at once: one `state` call serves both.
16. Remove on a share already removed elsewhere: the CLI's "no share with id" shows; the menu refreshes.
17. Remove on an `own_host` share with no Cloudflare credential in the app's environment: the CLI's credential error shows; the share stays.
18. Setup cancelled mid-login: the process group dies, including `cloudflared tunnel login`.
19. Open at Login from a build outside /Applications: registration pins that path; the status shows it; moving the app later requires toggling again.
20. This Mac not in `hosts=`: header "Not serving on this Mac (hosts=…)", Start hidden, adds warn that the link needs a serving Mac.
21. More than 25 shares: 25 newest listed, then "N more (share ls)".
22. A private GitHub repo dropped: the add succeeds, the warning alert offers Remove.
23. A folder dragged across the menu bar by accident: the confirm dialog stops it.
24. Two dropped files with the same basename: the queue reads `state` before and after each `add`, and the copied link is the id that one `add` created. A terminal `add` that lands in the same moment can still be picked; that residual race is accepted.
25. A command dies holding a lock: the next command finds a dead pid in the lock and takes it over.
26. `jq` missing or a bash error in the CLI: the header shows the CLI's error line, not an update hint.

## Failure modes

| Failure class | Detection signal | Mitigation / recovery |
|---|---|---|
| CLI not on the GUI PATH | locate returns nil | fixed probe list plus `SHARE_BIN`; install state with the brew command |
| A read hangs | `state`/`hits` timeout | TERM then KILL the process group; last snapshot stays, header shows the error |
| A write is slow (big folder, `start` waits on the tunnel) | mutating verb running | no automatic kill; "Working…" header; queue holds the next verb; "Stop Waiting" after 60s with a confirm |
| A Cloudflare call stalls | `cf()` hits `--max-time 30` | the verb fails with the CLI's error line |
| Cask lags the formula | `bin/release` could not sign | it prints `CASK NOT RELEASED: run mac/release.sh <tag> on a signing Mac` and exits 3 after the formula release |
| Contract drift | decode failure, or `schema` > 1 | update headers; additive fields never break decode |
| Concurrent index writers (app, terminal, hourly prune) | lost rows before this spec | `index_lock` around every write |
| Destructive click | Remove chosen | confirm dialog naming what goes (copy to Trash; DNS record for own-host shares) |
| Notarization rejected at release | notarytool status not `Accepted` | `mac/release.sh` prints the notary log, skips the cask; the formula release already happened and stays valid because the app degrades on an old or new CLI |

## Out of Scope

- The tool rename. Display name, bundle id, and cask name each live in one place (DEC-007).
- Creating live (port) shares or `--host` shares from the app.
- A TTL picker and a Finder Share extension: next iteration once the contract lands.
- Auto-update inside the app: Homebrew updates the cask.
- File promises (Mail, Photos drags), notifications, visit charts, Linux.
- Supervising the serve daemon.

## Touches

- bin/**
- tests/**
- mac/**
- docs/**
- .github/**

## Decision Log

- DEC-001: The app reads only through `share state` (ADR-0003).
- DEC-002: AppKit `NSStatusItem` over SwiftUI `MenuBarExtra`.
- DEC-003: Hits stay a text verb, streamed, shown verbatim.
- DEC-004: Same repo and tag; cask depends on the formula; app release in its own script called by `bin/release`.
- DEC-005: Swift package plus shell build script, no Xcode project.
- DEC-006: No App Sandbox; Developer ID with hardened runtime, because the app spawns the CLI.
- DEC-007: Working name "Share Bar", bundle id `foundation.d.share.bar`, cask `share-bar`, pending the rename.
- DEC-008: A new verb over a flag, so an old CLI cannot prune on the app's first call.
- DEC-009: Reads have timeouts and kill the process group; writes are never killed.
- DEC-010: The app always re-reads `state` after a verb instead of parsing verb output.
- DEC-011: One composed EXIT trap owns every lock; locks carry a pid for stale-lock recovery.
- DEC-012: `urlenc` is pure bash and must match `jq @uri` byte for byte.
- DEC-013: Folder publishes from the app always confirm; the CLI stays unprompted.
- DEC-014: The publish step (index write, Caddyfile render, reload) is one critical section under `index_lock`; locks are pid symlinks shared by both lock kinds.
- DEC-015: A stuck write can be stopped by the user after 60s with a confirm; never automatically.
- DEC-016: `rm` refuses an own-host removal it cannot finish; `prune` does not, so expiry always proceeds.
- DEC-017: The operator overrode the third validation after its critical and warnings were folded, because each round was finding new edge cases in existing concurrency code that per-task verifiers and negative controls catch against real code.

## Review

Parallel review, 2026-09-27, base 91e9a5b, 42 files. Lenses: security (Opus), architecture, test coverage, frontend (domain), infra (domain), advisor (critique). Design-time reviews and the three spec validations are in git history of this file.

### Verdict: FIX THEN SHIP

### Findings

| # | Severity | Finding | Lens(es) | Confidence | Status | Route |
|---|---|---|---|---|---|---|
| 1 | HIGH | A newline or tab in a parent folder of the shared file forges index rows; a forged row can serve `$HOME` or proxy the main hostname to a local port. `add` checks only the basename (bin/share:354); readers accept any 5 or 6 field line. Pre-existing on main. | security | 75 | validated (reproduced: forged site block in the Caddyfile) | gated_auto |
| 2 | HIGH | VoiceOver hears only the share name; the row's status (`2d left`, `expired`, `live`, `never`) is stripped by `setAccessibilityTitle(row.title)` (StatusItemController.swift:192-196). | frontend | 75 | validated | gated_auto |
| 3 | MEDIUM | The notary `.p8` is moved to the Trash (or a temp dir), never deleted (mac/release.sh:49-58). | security, infra | 100 | convergent | gated_auto |
| 4 | MEDIUM | `rm` rewrites the index before trashing `pub/<id>`; a killed `rm` (Stop Waiting) leaves content served with no row (bin/share:441-442). | security | 75 | | gated_auto |
| 5 | MEDIUM | Bundle id literal repeated in four Swift files; the pending rename becomes four edits. | architecture | 75 | | gated_auto |
| 6 | MEDIUM | Setup window has no Escape (`.cancelAction`). | frontend | 75 | | gated_auto |
| 7 | MEDIUM | `hitsLine` parsing sits in the untested app target, duplicating a tested Core rule. | test coverage | 75 | | gated_auto |
| 8 | MEDIUM | `docs/how-it-works.md:95` still describes `rm` as always succeeding; own-host removals without a credential now refuse. | advisor | 75 | | gated_auto |
| 9 | LOW | Full file paths logged with `privacy: .public`. | security | 100 | | gated_auto |
| 10 | LOW | Child PATH puts user-writable dirs before `/usr/bin:/bin:/usr/sbin:/sbin`. | security | 75 | pushed back: spec-pinned order; no security gain, since the CLI's own directory already comes first; system-first would swap in Apple's `jq` and `trash` for Homebrew's | gated_auto |
| 11 | LOW | "Stop Waiting" opens a confirm but lacks the ellipsis. | frontend | 75 | | gated_auto |
| 12 | LOW | No Swift test decodes a non-zero `skipped`. | test coverage | 75 | | gated_auto |
| 13 | LOW | Cask PR merges with no `brew style` on the generated file. | infra | 75 | | advisory |
| 14 | LOW | Spec After-state boxes unticked; release and Mini install not yet asserted anywhere. | advisor | 75 | | advisory |

### Suppressed (below the confidence gate)

- Child env inherited wholesale; `SHARE_BIN`, `BASH_ENV`, `DYLD_*` honored in release builds (security, 50). Worth doing as hardening; not verified end to end.
- New-share id diff can pick a concurrent terminal add (security, 50). Already an accepted residual race (edge case 24).
- Lock breaker can leave two holders in a three-way race (security, 50). Accepted in TASK-001.
- Setup status changes not announced to VoiceOver (frontend, 50); drop overlay may shadow the status button's AX node (frontend, 50); setup window has no initial focus (frontend, 50).
- Kill-timing sleeps in Swift tests could flake under load (test coverage, 50).
- Edge case 19 missing from the "not verified" table (test coverage, 50).
- Signing identity default duplicated in two scripts; notary-timeout die does not print the zip path (infra, advisory).

### Previously rejected

None (no rejected-findings ledger in this repo).

### Scores

| Lens | Score |
|---|---|
| Security | 6/10 (worst: finding 1) |
| Architecture | 9/10 (worst: finding 5) |
| Test coverage | 9/10 (worst: finding 7) |
| Frontend | 7/10 (worst: finding 2) |
| Infra | 7/10 (worst: finding 3) |
| Combined | 7.6/10 |

### TODOs

Findings 1 to 12 go to verification, then a fix batch; round 2 re-reviews the fix diff. Findings 13 and 14 are recorded only.

## Amendments

- AMEND-001: 2026-09-27 | `build.sh` notarizes with an App Store Connect key (`NOTARY_KEY`, `NOTARY_KEY_ID`, `NOTARY_ISSUER`) as well as the keychain profile | why: the `DWARVES_NOTARY` profile was absent and `notarytool store-credentials` fails without an interactive keychain, which would make every release a manual step | at TASK-012 checkpoint | new tasks: none | re-validated: delta-only, by the TASK-012 re-verification

- AMEND-002: 2026-09-27 | `mac/release.sh` gets the notarization key from 1Password when `NOTARY_KEY` is unset and `NOTARY_KEY_OP` (an `op://` reference to the `.p8` field) plus `NOTARY_KEY_ID` and `NOTARY_ISSUER` are set: it reads the key with `op read` straight into a `mktemp` file (mode 600), exports `NOTARY_KEY`, and deletes the file on exit, since it is a temp copy of a secret the script made and the original stays in 1Password | why: the keychain profile cannot be stored headlessly (AMEND-001), so without this a real `bin/release` would build and sign, then stop at notarization; the reference lives in the operator's environment, never in this public repo | at TASK-014 checkpoint | new tasks: none | re-validated: delta-only, by its task verifier

## Open questions

(none)
