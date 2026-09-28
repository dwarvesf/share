# Implementation notes: per-link Access gate

Delta from `docs/specs/SPEC-004-access.md`. Decisions already in the spec are referenced, never restated.

## TASK-1 spike, measured on the Dwarves LLC account (2026-09-28, read-only unless stated)

| Question | Answer |
|---|---|
| empty-body `POST access/apps {}` | HTTP 400, `errors[0].code` 12130, `access.api.error.invalid_request: app type is missing or invalid`; the app count stayed at 4. The preflight accepts exactly `400` + `12130` as the Apps Edit proof. |
| `GET /user/tokens/verify` with the Toolkit token | `success:true`, `status:active`; `GET /user/tokens/<id>` answers 9109 (no API Tokens Read), so scopes cannot be listed, only exercised. |
| `GET /zones?name=d.foundation&status=active` | exactly one zone, account Dwarves LLC (the 4-account token sees no duplicate). |
| `GET access/groups?name=dwarves-ops` | one group, 8 include entries, 1 page. |
| Access org, IdPs | org 200; IdPs `[onetimepin]` only. |
| inline `policies` on app create | accepted: the e2e apps were created with an inline allow policy and read back intact. |
| the `kid == aud` delay on an already-routed host | measured end to end on a NEW hostname (the stronger case): `share add --access` took 37-38 s from start to the printed link, three passing probe rounds included. See `docs/verification/access.md`. |

## Decisions made without the operator

- The build landed on a successor branch (`feat/access-gate`, the three spec commits cherry-picked onto main after SPEC-005) rather than a force-push of `docs/share-access-spec`; PR #30 is closed as superseded by the successor PR.
- `share api-token` refuses quick mode with the same line `add --access` prints: `need_host` passes in quick mode with an empty hostname, and the spec's "never `share-api:` with an empty host" needs the refusal.
- The name of the account-token form for the default profile is `share access (default)`; the spec fixes the form only for a named profile.
- The dry seam sits inside `cf_try` (`cf_dry`): every Access call, the group paging, the read-back, and the lost-POST lookup run the real code paths against fixture answers, instead of separate dry branches per function. Preflight outcomes are environment knobs (`SHARE_ACCESS_DRY_ZONES`, `_ORGS`, `_APPS`) rather than fixture files.
- `access_ls_check` (the PUBLIC warning) and the pending-count note run from `cmd_ls`, so `status` gets both through its `cmd_ls` call.
- `cmd_prune` takes a mode: `quiet` (`serve`, `status`: no token from any source), `listing` (`ls`: the exported environment token only, with a soft account lookup), bare (`share prune`: the full resolver). The spec names the outcome; the mode is how the one function serves the three callers.
- The preflight stays verbose on every gated add (the advisor lens asked for a quiet form): the spec pins the lines, and a gated add is a rare, deliberate act where seeing the scopes pass is worth four lines.

## Deviations

- Round 8 of the spec's Decision Log records what the build-time review changed: the
  main Caddy site is bound to the hostname with a 404 catch-all (a security BLOCKER: the
  any-Host default site served the whole `pub` tree to a `--host` name during the gate
  wait); every delete reads the app and requires the `share <id> <host> ` name; the sweep
  never acts on a malformed line; a deferred delete is owned by pid 0; `refresh` swaps
  under the lock; `status` never sweeps; the hourly prune inherits `SHARE_API_TOKEN_OFF`
  (the spec's `access_sweep` paragraph said it "sweeps normally"; the Onboarding section,
  written later, says the service and its prune never make an Access call, and the code
  follows that). The spec was amended before the live legs ran, and a fresh-context
  validator re-read the amended sections.
- Not done from the review: extracting the gated publish steps out of `cmd_add` into a
  helper (a shape change with no behavior behind it; `cmd_add` is 95 lines and reads top
  to bottom in the spec's own order).
- Row 20 (two profiles on two zones) runs as "the gated id is a 404 on another setup's
  hostname" with `SHARE_E2E_OTHER_HOST` (the operator's `s.han.ws`, another account and
  machine); no second zone token exists for a same-machine two-profile leg.

## Landmines found while building

- `case` patterns: `*/access/apps?*` also matches `/access/apps/<uuid>` because `?` is a glob wildcard; the id pattern comes first and the list pattern quotes the `?` (a quoted `\?` is a literal backslash, which matched nothing and read Zone: Read as MISSING for one run).
- `rows()` validates `access=` and `access_rule=` in awk with `index`/`substr`/`length` only: mawk has no `{n}` intervals and no `\b`.
- macOS BSD `grep` treats a `$` before `\|` as a literal, so a combined `a$\|b` pattern silently loses its first alternative; the suite uses one `-e` per pattern.
- `script -q /dev/null cmd` with the paste piped on stdin races its EOF against the data on macOS (the pty echoed `^D` then the token, and `read -rs` saw EOF); the pseudo-terminal test drives the prompt with `expect` and skips when it is absent.
- `${4:-$$}` turns an empty fourth argument back into this pid; a "no owner" line needs `${4-$$}` then `${o:-0}` (the re-validation caught it: serve's own prune was still pinning lines).
- Sites that share a port land in one adapted Caddy server, each site's routes nested under a host-matched subroute, so a route-order check has to walk `..` in document order rather than the top-level `routes[]`.
- `env -u X func` fails: `env` cannot exec a shell function; the test passes `VAR=` as an empty assignment instead.

## Found while finishing the build (the second green pass and the live legs)

- `api_token_store` ran inside `$( )` in `cmd_api_token`, so its `die` killed only the substitution: a token outside `[A-Za-z0-9_-]` printed the refusal, stored nothing, then ran the preflight and exited 0. The store now reports through `api_token_store_out` and is called directly. The same footgun pattern (`die` under `$( )`) is worth grepping for when a new "refuse" path lands.
- An `ls` or `status` holding an exported `CLOUDFLARE_API_TOKEN` really sweeps: the deferred app in the suite's expiry test was deleted by a later `ls`, not by `prune`. A test that asserts a pending count must read it before any token-holding `ls`.
- `access_account soft` used to warn once per caller, so `ls` printed the skip line twice (once for the prune pass, once for the per-row check). It now warns once per process.
- `stage_publish` logs `PUBLISH` before the `mv`, not after: a watcher that polls "pub changed while the marker is absent" races a microsecond window otherwise and flaked red once.
- `access_open_url` backgrounds the opener in a subshell that sets `trap "" HUP` and execs through `nohup`: under a pty the process group can get a HUP before a bare `( cmd & )` child installs its own trap, which is how the row-33 leg lost its opener.
- The `share state` row loop reads `host=`/`access_rule=` with `${opts#*...=}` expansion, not `$(opt_val ...)`: two subshells per row doubled the 500-row time. The perf check now takes the min of two runs; a loaded machine still inflates it.
- e2e fixture: the backend caddy was addressed `http://127.0.0.1:<port>`, which answers only `Host: 127.0.0.1`. share's `--host` proxy passes the visitor's Host upstream, so the fixture answered an empty 200 forever. The fixture now binds the bare port. If a real upstream is host-strict the same symptom appears live: a 200 with `Content-Length: 0` and `Via: 1.1 Caddy`.
