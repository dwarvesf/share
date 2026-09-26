# Pitfall Report: `share status --json` + menu bar app

## Critical (will block implementation)
- `cmd_status` writes before it reads: `bin/share:714-726` calls `cmd_prune()` first, which deletes expired shares (`cmd_rm` -> `host_rm` Cloudflare API delete, `to_trash`/`mv`, `write_caddyfile`, `caddy_reload`) -- a menu bar app polling status every few seconds will trigger real deletes/API calls/caddy reloads on a timer, not just read state. New `--json` path must skip `cmd_prune` or make status genuinely read-only.
- Mixed stdout streams: `cmd_prune` calls `cmd_rm` which itself `echo`s `"unpublished $1"` (`bin/share:375`), piped through `sed 's/$/ (expired)/'` (`bin/share:383`) -- any prune side effect during a `--json` call will emit plain-text lines onto stdout ahead of/mixed with the JSON blob, breaking `jq`/`JSONDecoder` parsing on the Swift side.
- `host_ok` gate is silent-fail shaped for JSON: `host_ok()` (`bin/share:43`) and the `share: $(this_host) is not in hosts=$hosts` messages (`bin/share:330,479,646`) are free text via `die`/`echo`, not structured -- the menu bar app needs a machine-readable "not the serving host" state, or it will show generic errors on every non-primary machine.
- `set -u` + `hosts` unset: `hosts="${SHARE_HOSTS:-$(cfg hosts || true)}"` (`bin/share:36`) can legitimately be empty string; `host_ok`'s `case " $hosts "` pattern is fine, but any new `--json` code building an array from `$hosts` under `set -u` must guard the empty case explicitly (documented landmine in CLAUDE.md: "no empty arrays under `set -u`").

## Warnings (will cause problems if ignored)
- GUI-launched PATH: `svc_path()` (`bin/share:556`) already exists specifically because launchd services get a minimal PATH and can't find `caddy`/`cloudflared`/`jq`/`trash`/`security` under Homebrew prefixes. A menu bar app spawning `bin/share` via `NSTask`/`Process` inherits the same minimal-PATH problem (Finder-launched apps get `/usr/bin:/bin:/usr/sbin:/sbin` only) -- reuse `svc_path()`'s resolved PATH or hardcode `/opt/homebrew/bin:/usr/local/bin` into the spawned environment, don't rely on ambient `$PATH`.
- `cmd_add`'s clipboard write: `bin/share:326-327` does `pbcopy` unconditionally unless `SHARE_CLIPBOARD=0`. If the menu bar app shells out to `share add` for a quick-share button, it will silently overwrite the user's clipboard -- fine for a human-driven click, but surprising if the app ever calls `add` programmatically/in bulk. Set `SHARE_CLIPBOARD=0` in the spawned env when the app renders its own copy button.
- `cf()` reads the Cloudflare token via `curl -H @<(...)` process substitution (`bin/share:739`) -- process substitution under `/bin/bash` needs real bash (fine, shebang is `#!/bin/bash`), but if the Swift side ever spawns via `/bin/sh` or a POSIX-mode wrapper this breaks silently.
- No existing test or code path exercises JSON output at all (`grep -n json tests/share.sh` finds nothing) -- `--json` is a wholly new surface with zero regression coverage to build from.
- `host_lock()` (`bin/share:890`) is a polling lock with `SHARE_HOST_LOCK_TIMEOUT` (default 60s, polled 5x/sec) for Cloudflare-side edits. If `--json` avoids `cmd_prune`/`cmd_rm` per the Critical item above, this lock is irrelevant to status, but confirm the `--json` path never calls `host_rm`/`cf()` -- if it does (e.g. to check zone health) it inherits this lock and can block the menu bar UI thread for up to a minute.

## Noted (cosmetic, low risk)
- `die()` writes `share: $*` to stderr and exits 1 (`bin/share:41`) -- consistent and fine for the CLI; the Swift wrapper should read stderr separately from stdout rather than assume all output is on one stream.
- `this_host()` strips domain via `${h%%.*}` (`bin/share:42`) -- no landmine, just note the menu bar app's own "which machine am I" display should call the same function/logic rather than re-derive `uname -n`.

## Missing prerequisites
- [ ] Decide whether `--json` needs its own `host_ok`/serving-state enum (e.g. `{"serving":bool,"host_ok":bool,"mode":"quick"|"named","shares":[...]}`) before writing Swift model types against it.
- [ ] Decide PATH policy for the spawned CLI process (reuse `svc_path()` vs. a fixed list) before writing the Swift `Process` launch code.
- [ ] No `.github/workflows/*.yml` job builds/tests Swift yet; `ci.yml` only runs `shellcheck` + `tests/share.sh` on `ubuntu-latest`/`macos-latest`. A `mac/` Swift target needs its own CI job (macOS-only, already on the free public-runner tier per the repo's own comment at `.github/workflows/ci.yml:6-7`, so no self-hosted-runner exception needed).

## Files over 500 lines (split candidates)
- `bin/share`: 1226 lines -- already past the threshold before this change. Adding `cmd_status --json` grows a monolith that mixes CLI parsing, Cloudflare API calls, caddy/systemd/launchd service management, and now output-formatting. If this PR is the trigger, consider carving Cloudflare API helpers (`cf`, `doh`, `public_zone`, `resolves`, `cf_zone`, `auth_api`, `auth_login`) into a sourced lib -- but this is a "flag it, don't fix it in this PR" split candidate per the repo's surgical-changes convention.
