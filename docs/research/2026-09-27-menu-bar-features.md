# Feature Map: menu bar app surface of `bin/share`

## Endpoints (CLI subcommands a menu bar app would shell out to)

- `status`: `bin/share:714` `cmd_status()` -- prunes expired, prints serving state (`serving (pid N) on <host>` or quick-tunnel line or "not serving"/"not set up"), then `service: installed (...)` if applicable, then calls `cmd_ls`. Dispatch: `bin/share:1222`.
- `ls`: `bin/share:336` `cmd_ls()` -- one block per share: link line from `share_url`, then indented `id=... live -> src ...` or `id=... size=... added=... expires=... from=...`. Dispatch: `bin/share:1214` (`cmd_prune; cmd_ls`).
- `add <target>`: `bin/share:271` `cmd_add()` -- stdout: link line (`echo "$url"`, line 325) then `  (link copied)` if clipboard succeeded (line 327). stderr: live-share warnings (314-316), curl-probe-empty warning (316), "not serving: host not in hosts" note (330).
- `rm <id|link>`: `bin/share:365` `cmd_rm()` -- stdout `unpublished $1`.
- `refresh <id|link>`: `bin/share:352` `cmd_refresh()` -- stdout `refreshed $1 from $src`.
- `hits <id|link>`: `bin/share:387` `cmd_hits()` -- stdout `"$N hits, $M visitors, last <ts>"` or `0 hits`.
- `start`: `bin/share:659` `cmd_start()` -- stdout `  serving in the background (pid N); share stop to end`.
- `stop`: `bin/share:703` `cmd_stop()` -- stdout `stopped (all links down...)` or `not serving`.
- `setup [hostname]` / `setup --quick`: `cmd_setup` (`bin/share:991`), `cmd_setup_quick` (`bin/share:802`).
- `service install|uninstall|status`: `cmd_service` (`bin/share:643`).
- `teardown [--yes]`: `cmd_teardown` (`bin/share:1103`).
- `skill [--install]`: `cmd_skill` (`bin/share:1163`).
- Dispatch `case`: `bin/share:1209-1226` -- default (no args) and unknown-command both fall to `status`/help; unknown command exits 1 after printing the header comment (line 1225).

## Key helpers a menu bar app needs

- `running()`: `bin/share:44` -- `[[ -f $pidfile ]] && kill -0 "$(cat pidfile)"`. Cheapest liveness check, no subprocess needed beyond `kill -0`.
- `serving_host()`: `bin/share:75` -- quick mode reads `$root/quick.url` (empty while not serving); named mode echoes `$host_name` from config.
- `share_url(id, name, [opts])`: `bin/share:80` -- builds the printed link; handles `--host` fqdn, `live` opt, `.md`→`.html` rewrite, dir trailing slash, space-encoding.
- `svc_installed()`: `bin/share:544` -- `[[ -f $svc_plist || -f $svc_unit ]]`, tells the app whether the login service (vs manual start/stop) owns serving.
- `index` (`$root/index.tsv`, `bin/share:31`): tab-separated `id, name, source, added-date(YYYY-MM-DD), expiry-epoch(0=never), opts`. A 5-column legacy row (no opts) is still accepted everywhere via `awk -F'\t'` field access (test at `tests/share.sh:64-68`).
- `opts` column tokens (space-separated, checked with `has_opt`/`opt_val` at `bin/share:59-64`): `live` (proxy, not snapshot), `noindex` (no generated listing), `host=<fqdn>` (own hostname; mutually exclusive with quick mode, `bin/share:284`).

## Interactivity / TTY requirements (relevant to `setup`/`setup --quick`)

- `cmd_setup` (`bin/share:1009`): prompts `read -rp "Hostname for your links..."` ONLY if `[[ -z $host_name && -t 0 ]]` -- a menu bar app must pass the hostname as an argument, no TTY available for GUI-launched processes.
- `auth_login()` (`bin/share:760`): opens a browser (`cloudflared tunnel login`) unless a cached cert for the zone already exists (`bin/share:762`) -- first-run named setup needs a real browser round-trip; a GUI app should launch this in Terminal.app or shell out and poll, not run silently.
- `cmd_teardown` (`bin/share:1103`, `1120`): prompts `read -rp` for confirmation unless `--yes` is passed or `[[ ! -t 0 ]]` (then dies asking for `--yes`) -- a menu bar app must always pass `--yes`.
- `cmd_setup_quick` (`bin/share:802`) has NO prompts: no domain, no login, safe to call unattended from a GUI.
- `svc_install`/`svc_load` (`bin/share:555`, `593`) use `launchctl bootstrap`, no TTY needed but may need retry (`bin/share:593`, sleep 1 then retry on error 5).

## Data model: index.tsv + opts

- Columns (tab-sep): `id` (6 hex, `rand_id` `bin/share:58`), `name`, `source` (path or `http://127.0.0.1:port`), `added` (YYYY-MM-DD), `expiry` (unix epoch, 0=never), `opts`.
- `opts` tokens: `live`, `noindex`, `host=<fqdn>` -- built up in `cmd_add` (`bin/share:272-307`) and consumed by `share_url`, `cmd_ls`, `write_caddyfile` (`bin/share:403`), `cmd_rm`/`cmd_hits` (`opt_val host`).

## Test scaffolding a menu bar app's own tests can mirror

- `tests/share.sh:8-14` -- isolation: `SHARE_ROOT`, `SHARE_CONFIG_DIR` point at a `mktemp -d`; `SHARE_PORT=18787` avoids the real 8787; `SHARE_TUNNEL=0` skips cloudflared; `SHARE_CLIPBOARD=0` skips pbcopy; `SHARE_HOSTNAME=s.example.test` fakes a hostname; `SHARE_SERVICE_LABEL=share-selftest-$$` so no real launchd job is touched; `SHARE_HOSTS` set to the real hostname so `host_ok` passes.
- `check()` helper: `tests/share.sh:19-21` -- `check <label> <expected> <actual>`, string-compares, increments `$fails`, prints `ok`/`FAIL` lines; no framework, just a counter and an `exit 1` at the end (`tests/share.sh:396-403`).
- `local_url()` / `code()` / `hcode()` / `header()` (`tests/share.sh:22-25`) rewrite the fake public hostname to `http://127.0.0.1:$SHARE_PORT` so curl checks never leave localhost.
- `wait_for_port` / `wait_code` (`tests/share.sh:26-39`) poll instead of sleep-and-check, used throughout for eventual-consistency after `add`/`start`/`refresh`.
- Negative control: `tests/share.sh:374-376` -- `SHARE_HOSTS=not-this-host bash "$SH" start` must exit 1 (host guard). Process-leak checks at `tests/share.sh:378-393` (`lsof`, `pgrep -f "$WORK"`, orphaned `sleep 3600` prune loop) are the closest thing to a "did we leave anything running" check a menu bar app's start/stop cycle should also satisfy.

## Gaps for a menu bar app

- No JSON/machine-readable output mode anywhere: `status`, `ls`, `add` are human-text only (line-oriented, parseable via `cut -f`/`grep`, but no `--json`). A menu bar app must scrape stdout.
- No event/notification hook on state change (share added, expired, serve died) -- polling `status`/`ls` is the only path.
- `cmd_setup`'s browser-login step is the one path with no non-interactive equivalent besides pre-supplying `CLOUDFLARE_API_TOKEN`.

## Key files ranked

1. `bin/share:271-334` `cmd_add` -- stdout/stderr contract + clipboard, the main thing a UI wraps.
2. `bin/share:714-726` `cmd_status`, `bin/share:336-350` `cmd_ls` -- the polling surface for a status-bar view.
3. `bin/share:44`, `75`, `80` -- `running`, `serving_host`, `share_url`: cheap state without shelling to `status`.
4. `bin/share:659-712` `cmd_start`/`cmd_stop`, `544` `svc_installed` -- toggle logic + service-vs-manual distinction.
5. `bin/share:31` index.tsv shape + opts tokens (`live`, `noindex`, `host=`) -- needed to render `ls` rows in a UI.
6. `bin/share:991-1101` `cmd_setup`, `802-820` `cmd_setup_quick` -- onboarding flows; note the TTY-only prompt at line 1009.
7. `tests/share.sh:1-40` -- isolation env vars and `check`/`wait_code` helpers to reuse for a menu-bar-app test harness.
