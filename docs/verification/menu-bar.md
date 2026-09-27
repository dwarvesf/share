# Proof of done: menu bar app

Date: 2026-09-27
Branch: feat/menu-bar-app
Spec: `docs/specs/SPEC-003-menu-bar.md` (17 tasks, AMEND-001, AMEND-002)
Pre-build base: 91e9a5b

## Green run (final, fresh re-audit at 88c8306)

```
Command: /bin/bash -n bin/share && shellcheck bin/share install.sh tests/share.sh tests/e2e.sh demo/render.sh mac/*.sh && bash tests/share.sh
Exit:    0
Checks:  215 ok, 0 FAIL (PASS)
Verdict: PASS

Command: swift test --package-path mac
Exit:    0
Output:  Executed 104 tests, with 0 failures (0 unexpected)
Verdict: PASS

Command: swift build -c release --package-path mac && strings <bin>/ShareBar | grep -c SHAREBAR_DEBUG_ADD_PATHS
Exit:    0 (build); count 0 (the debug build prints 1, so the grep can find it)
Verdict: PASS, the debug entry does not ship

Command: RELEASE_DRY=1 NOTARY_KEY_OP=op://x/y/z NOTARY_KEY_ID=K NOTARY_ISSUER=I bash mac/release.sh v0.0.0   (stub op on PATH writes a marker when called)
Exit:    0; marker absent
Verdict: PASS, a dry release never reads the key
```

The commit after the re-audit, 5b969f9, changes only the identity match in `bin/release` (capture, then match, no pipe); `bash -n` and shellcheck pass on it.

## Notarized build

```
Command: NOTARY_KEY=<p8> NOTARY_KEY_ID=<id> NOTARY_ISSUER=<issuer> bash mac/build.sh --sign --notarize 0.1.0
Result:  notarytool status: Accepted; xcrun stapler validate: The validate action worked!;
         spctl -a -vv: accepted, source=Notarized Developer ID; lipo -archs: x86_64 arm64
```

## Negative controls (each went red)

| Control | Where | Result |
|---|---|---|
| `cmd_prune` at the top of `cmd_state` | fresh scratch clone at 88c8306 | suite exit 1, 19 FAIL incl. `serving: writes nothing` |
| No index lock in `cmd_rm` | TASK-001 | parallel add/rm row checks fail in both rounds |
| Caddyfile rendered after the lock is released | TASK-001 | Caddyfile check fails in 5 of 6 rounds (2 rounds per run) |
| Old `\| while` prune loop under bash 5 | TASK-001 | prune lock check fails |
| Old rm/refresh ordering | leak fix c0e372b | `refresh racing rm` fails (170 ok + 1 FAIL) |
| `urlenc` keeps `#` | TASK-003 | encoder comparison fails under both shells |
| Doc missing `own_host` | TASK-015 | field-coverage check fails |
| Rounding instead of floor for time left | TASK-007 | 3 floor tests fail |
| Reentrant `MutationQueue`, uncoalesced `state` | TASK-006 | order test and spawn-count test fail |
| `depends_on macos: ">= :ventura"` | TASK-014 | `brew style` flags OSDependsOn |

## Tasks

| Task | Commits | Verifier | Fresh re-audit |
|---|---|---|---|
| 001 locks and publish section | b7c0d06 | PASS 6/6 (Opus) | PASS |
| leak fix: refresh racing rm | c0e372b | PASS 2/2 | PASS |
| 002 quick.url lifecycle | 92b22c8 | PASS 2/2 | PASS |
| 003 pure-bash urlenc | 9907e04 | PASS 4/4 | PASS |
| 004 streamed hits | e25b3c4 | PASS 1/1 | PASS |
| 005 `share state` | 30edf55, 4065d9e | PASS 7/7 (500 rows 0.55 to 1.25s) | PASS |
| 006 CLI runner | a8b5461 | PASS 5/5 | PASS |
| 007 model | e47258b, 605167b, c5a4046 | FAIL (double prefix) then PASS 7/7 | FAIL (no floor test) then fixed with mutation proof |
| 008 menu rendering | fb69b65, f0f868e, 1e8d741 | PASS 4/4 | PASS; cold-launch header fixed in 009 |
| 009 read and app actions | 791c847, f2466a0 | FAIL (cache cleared only on close) then PASS 4/4 | PASS |
| 010 drop target | 3ae7a27 | PASS 4/4 by code and shared tested logic | PASS |
| 011 setup window | 43fe5cc | PASS 4/4 | PASS |
| 012 build and notarize | b13fd33, 992dd2a | FAIL (key mode) then AMEND-001 then PASS | recorded path overwritten; substitute check on the 0.1.0 zip passed |
| 013 CI | 8341eac | PASS 1/1 | PASS |
| 014 release and cask | ec13440, 974a0cc, 54db7ec, 0600277, 5b969f9 | PASS 3/3; AMEND-002 PASS 6/6 | PASS |
| 015 docs | 92510eb | PASS 3/3 | PASS |
| 016 small CLI hardening | 849b823 | PASS | PASS (lead ran the suite alone: 168 ok) |
| 017 mutating actions | 5491a68, 88c8306 | FAIL (debug entry in release) then PASS 7/7 | PASS |

Integration verifier: PASS, 24 of 24 components reach their activation point, 6 of 6 end-to-end chains connect (app verbs to CLI dispatch, snapshot fields to `cmd_state`, old-CLI mapping, locks, build to release to cask names, CI, docs strings).

## Live checks (accessibility, no screenshots)

Screen Recording is not granted to these sessions, so `screencapture` returns black frames. The menu was read through System Events instead; `docs/verification/menu-bar-menu.txt` holds the dump for serving, stopped, and 30 shares (25 rows plus `5 more (share ls)`).

| Check | Result |
|---|---|
| No Dock icon; accessibility label mirrors the header | pass |
| Open menu updates in place when `state` returns; 60s poll fires | pass |
| Copy Link to the pasteboard; hits line replaces Loading…; cancel on switch | pass |
| Loading… on a cold launch before a slow `state` | pass |
| Open at Login toggle (registered, then unregistered again) | pass |
| Remove confirm, Stop Waiting after 60s, private-repo warning, not-serving-here alert, folder confirm | pass |
| Setup window: stream, Cancel and Quit kill the whole process group | pass |

## Not verified here (needs a human)

| Check | Why |
|---|---|
| A real Finder drag of a file, a folder, and a Mail or Photos item onto the icon | no way to synthesize a Finder drag from these sessions |
| Refresh after sleep and wake | the shared Mac cannot be put to sleep from a session |
| The `.requiresApproval` login-item wording | needs a GUI approval revoke |
| The icon and menu look | no Screen Recording permission |

## Rollback

Every change is on `feat/menu-bar-app`. The CLI changes are additive (a new verb) or internal (locks, encoding, streaming); reverting the merge commit restores v0.5.1 behavior. A published cask is removed by reverting its tap commit in `dwarvesf/homebrew-tools`.

## Real end-to-end run

Date: 2026-09-27. Ran the real primary flow against the real `bin/share` CLI and a DEBUG `ShareBar` build, in an isolated sandbox under one `mktemp -d` root. `SHARE_TUNNEL=0` throughout, so nothing left the machine. Named mode was faked the way `tests/share.sh` does it, by exporting `SHARE_HOSTNAME` and `SHARE_HOSTS` so `bin/share` sees a configured hostname without a real Cloudflare tunnel. `swift build --package-path mac` built the debug binary; it ran with `SHAREBAR_DEBUG_ADD_PATHS` set to one fixture file. The app's menu was driven through System Events, clicking or AXPress only on elements of process `ShareBar`, and Screen Recording was available this run, so `screencapture` captured real menu content used to confirm the trailing text.

| Step | Command or AX action | Observed result |
|---|---|---|
| a. Debug add + CLI list + menu read | Launch debug `ShareBar` with `SHAREBAR_DEBUG_ADD_PATHS=$R/src/a.txt`; `bin/share ls`; AX read of the status menu | `bin/share ls` listed `https://share.local.test/2a48b0/a.txt`. The menu (via AX) showed the row titled `a.txt` with trailing text `29d left`, confirmed both through `AXTitle` and a screenshot taken while the menu was open. Header read `Serving at share.local.test`. |
| b. Start Sharing | Intended: click "Start Sharing", then curl the file | The debug `add` auto-started the local Caddy server (the CLI's own documented behavior), so the share was already serving before any click; the menu showed "Stop Sharing", not "Start Sharing", and curl already returned 200 with no action taken. To exercise the Start path honestly, the server was stopped through the real CLI (`bin/share stop`) first; that call hung indefinitely. See the finding below; this step could not be completed as specified. |
| c. Copy Link | Click "Copy Link" in the `a.txt` row submenu | `pbpaste` returned `https://share.local.test/2a48b0/a.txt`, exactly the `url` field `bin/share state` reported for id `2a48b0`. Pass. |
| d. Hits line | One extra `curl` against the file, then open the `a.txt` submenu and read the hits row via AX | Hits row read `2 hits, 1 visitor, last 2026-09-27 16:36`, a real count reflecting the curls made against the link. Pass. |
| e. Refresh | Click "Refresh" in the `a.txt` submenu | No alert window appeared (`0` windows on the `ShareBar` process afterward). `bin/share state` still listed share `2a48b0`. Pass. |
| f. Remove | Click "Remove…", then click "Remove" in the confirm alert | Alert text read `Remove a.txt? The copy goes to the Trash.` with buttons Cancel and Remove. After clicking Remove: `bin/share state` no longer listed the share, `curl` against the old URL returned 404, and the file was found under `~/.Trash/2a48b0/a.txt` with its original content intact, not deleted. Pass. |
| g. Stop Sharing | Click "Stop Sharing" in the main menu | Failed. The app spawned the real `bin/share stop` as a subprocess and hung: reopening the menu afterward showed the header stuck on "Working…" and the local Caddy process kept running. Waited about 13 seconds total (well past when a normal stop returns) before concluding it was truly hung, not slow. |

### Finding: `share stop` / "Stop Sharing" hangs on this sandbox

`bin/share serve` backgrounds itself (`nohup bash "$0" serve & `), sets `trap 'exit 0' INT TERM`, and blocks on `wait "$caddy_pid"`. `bin/share stop` sends that process a plain `kill "$pid"` (SIGTERM) and then polls `kill -0` until it exits. In this run that polling never ended: sending SIGTERM to the `serve` process directly, by hand, also had no effect, while an isolated reproduction of the identical `trap ... TERM; wait "$pid"` pattern in the same `/opt/homebrew/bin/bash` responded to SIGTERM instantly. This points at something in this process's ancestry (most likely SIGTERM already ignored at the point `nohup bash "$0" serve &` was launched, which a non-interactive bash cannot override with `trap`, per POSIX) rather than a bash bug in general. Clicking "Stop Sharing" in the real app reproduces the exact same hang through `mutationQueue`, so this is not an artifact of driving the CLI directly; it blocks the real "Stop Sharing" primary-flow step in this sandbox.

### Cleanup

Per instructions, killed the app pid directly (`kill 11318`); the app quit cleanly, but it left the hung `share stop`, the backgrounded `share serve`, and `caddy` running as orphans, exactly as expected given the finding above. `bin/share stop` was given a further bounded wait and stayed hung, so the three leftover PIDs were force-killed (`kill -9`) as sandbox teardown, not as a fix to the finding. Final state: `pgrep -x ShareBar` empty, `lsof -iTCP:38787 -sTCP:LISTEN` empty. `$R` (the `mktemp -d` sandbox root) was left in place per instructions.

Not run further: steps b and g are the only two that depend on a start/stop cycle, and both surfaced the same underlying hang; per instructions the run stopped at the first genuine failure (g) rather than working around it.
