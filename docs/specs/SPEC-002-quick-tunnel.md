# SPEC-002: quick tunnel mode (trycloudflare)

Status: DRAFT
Lane: normal
ADR: docs/decisions/ADR-0002-quick-tunnel-mode.md
Brief: docs/briefs/DECISION-BRIEF-quick-tunnel.md

## Problem

`share setup` requires a Cloudflare domain. Users without one (or unwilling
to configure one) cannot publish anything, though `cloudflared tunnel --url`
needs no account and yields a working `*.trycloudflare.com` URL.

## Behavior contract

### Setup

- `share setup --quick` writes `mode=quick`, `hosts=<this_host>`, `port` to
  config; no hostname prompt, no login, no token, no DNS, no zone.
- `share setup --quick` refuses when a named config exists (`tunnel_id`
  present): "already set up with a named tunnel; run 'share teardown' first".
- `share setup <hostname>` refuses when a quick config exists, same message.
- `share setup --quick <hostname>` is a usage error.
- `setup --quick` accepts `--no-service`; `--login`, `--force`,
  `--tunnel-name` are meaningless in quick mode and are usage errors.
- After writing config and (when `host_ok`) starting serving, setup prints
  the parsed `*.trycloudflare.com` URL and warns it changes every restart.
  The public live check is advisory in quick mode (warn, never fatal): the
  trycloudflare edge can lag the URL banner by seconds.

### Serving

- `cmd_serve` in quick mode skips `need_host`/`token_read`, deletes any stale
  `$root/quick.url`, and runs
  `cloudflared tunnel --no-autoupdate --url http://127.0.0.1:$port --metrics 127.0.0.1:$metrics_port`
  with stdout+stderr appended to `$root/cloudflared.log`.
- The first `https://[a-z0-9.-]+\.trycloudflare\.com` match in that log is
  written (fqdn only) to `$root/quick.url`. Parse waits up to 30s in the
  foreground; on timeout serve dies pointing at `cloudflared.log`.
- `wait_running` in quick mode returns when the pidfile lives and
  `quick.url` is non-empty; metrics `/ready` is not required.
- `serving_host()`: named -> `$host_name`; quick -> contents of `quick.url`,
  empty when absent. `share_url` prints `https://<pending>.trycloudflare.com/...`
  when the host is empty in quick mode (the `<pending>` marker makes a dead
  link obvious instead of silently wrong).
- `cmd_status` quick line: `serving (pid N) on https://<fqdn> (quick tunnel; the URL changes on every start)`; when not serving and no quick.url, `not serving: share start`.

### Refusals and no-ops

- `share add ... --host <fqdn>` in quick mode dies:
  "--host needs a named tunnel: 'share teardown', then 'share setup <hostname>'".
- `share teardown` in quick mode: confirm, `svc_uninstall`, `cmd_stop`, trash
  config and `quick.url`; no Cloudflare calls. `need_host`/`tunnel_id` checks
  are skipped.
- `token_read`, `cert`, `cf()`, `host_*`, `ingress_*` are never reached in
  quick mode.
- `need_host` passes in quick mode (setup ran; there is just no hostname).
- `service install` works; the service runs `share serve`, so each boot gets
  a new URL. Documented as a consequence, not blocked.

### Everything else unchanged

Snapshot/live rows, folder indexes, `--no-index`, `ls`, `rm` (pasted
trycloudflare links resolve through `id_of` like any link), `refresh`,
`hits`, `prune`, TTL, `SHARE_TUNNEL=0` local mode.

## Files

- `bin/share`: `mode=` read once near config load; `quick()` helper;
  `serving_host()`; `share_url`, `need_host`, `live_check`, `warn_not_live`,
  `cmd_status`, `cmd_serve`, `wait_running`, `cmd_setup`, `cmd_teardown`,
  `cmd_add` changes; `write_config_quick()`; header usage line; embedded
  SKILL.md quick section.
- `README.md`: quick-mode row + setup example.
- `docs/how-it-works.md`: quick mode in the diagram/files/lifecycle.
- `docs/setup.md`: `setup --quick` section.
- `tests/share.sh`: quick-mode section (see test plan).
- `docs/verification/quick-tunnel.md`: proof of done.

## Security / safety

- A quick URL is unguessable but public: same exposure class as named links.
  The "live share exposes the port" warning applies unchanged.
- `quick.url` content is fqdn-only, written by share itself; it never enters
  a Caddyfile or a shell eval. `serving_host` output is used in URLs and
  curl probes only.
- The URL regex is anchored to `*.trycloudflare.com` so a fake/redirected
  cloudflared log line cannot smuggle an arbitrary host into printed links.
- Quick mode cannot reach `cf()` or `host_add`: `--host` dies before
  `host_check`, and setup never writes `tunnel_id`.

## Test plan

| Row | Scenario | Assert |
|---|---|---|
| 1 | `setup --quick` writes mode/hosts/port, no token/cert/DNS touched | config contains `mode=quick`; no `tunnel_id`, no `cert.pem`, no `tunnel-token` file |
| 2 | `setup --quick` refuses over a named config | die names teardown; config untouched |
| 3 | `setup <hostname>` refuses over a quick config | die names teardown; config untouched |
| 4 | `setup --quick <hostname>` | usage error, exit != 0 |
| 5 | fake cloudflared emits a trycloudflare URL; `share start` | `quick.url` holds the fqdn; `status` prints it with the volatility note |
| 6 | `share add <file>` in quick mode | printed link is `https://<fqdn>/<id>/<name>` on the trycloudflare host |
| 7 | `share add 19993` live share in quick mode | link is `https://<fqdn>/<id>/`; live proxy still works through caddy locally |
| 8 | `share add x --host a.b` in quick mode | dies naming teardown + named setup; no index row written |
| 9 | restart serve; fake emits a second URL | `quick.url` holds the NEW fqdn; stale file cannot survive |
| 10 | cloudflared emits no URL | serve dies naming `cloudflared.log` |
| 11 | `teardown` in quick mode | no curl/cf calls happen (fake curl would fail if called); config + quick.url trashed; exit 0 with --yes |
| 12 | `rm <pasted trycloudflare link>` | resolves the id, share unpublished |
| 13 | quick mode + `SHARE_TUNNEL=0` | still local-only; no cloudflared spawned |

Test seam: a fake `cloudflared` executable earlier in PATH that prints the
banner line `https://<value>.trycloudflare.com` (value from
`SHARE_FAKE_QUICK_URL`, default `fake-tunnel`) to stderr and then sleeps.
Quick mode reads `SHARE_FAKE_QUICK_URL` only through the fake binary, never
in `bin/share` itself.

## Verification

`shellcheck bin/share tests/share.sh` and `bash tests/share.sh` green,
including rows 1-13 and the pre-existing 92-check suite unchanged.

## After state

`share setup --quick` gets a user with no domain from zero to a public link
with one command. Named mode is untouched. Docs and the agent skill state
plainly that quick URLs are random, public, and die on restart.
