# ADR-0002: quick tunnel is a setup-time mode, not a per-share flag

Status: accepted
Date: 2026-09-19

## Context

Two cloudflared modes exist: a remotely managed named tunnel (stable
hostname, token, DNS, ingress rules) and a quick tunnel
(`cloudflared tunnel --url`, random `*.trycloudflare.com`, no account).
share was built around the named tunnel. Supporting quick tunnels means
deciding where the mode lives.

## Decision

The mode is a config key, `mode=quick`, written once by `share setup --quick`.
Absence of the key means named mode; existing configs are unchanged.

- `cmd_serve` branches on the mode: quick runs
  `cloudflared tunnel --no-autoupdate --url http://127.0.0.1:$port` with output
  to `$root/cloudflared.log`, parses the first `*.trycloudflare.com` URL into
  `$root/quick.url`, and treats that file (not `/ready`) as the readiness
  signal.
- `serving_host()` resolves the public hostname: `host_name` in named mode,
  the contents of `quick.url` in quick mode. `share_url`, `live_check`,
  `warn_not_live`, and `cmd_status` all go through it.
- `--host` is refused in quick mode before any other check.
- `teardown` in quick mode never calls the Cloudflare API.
- `quick.url` is deleted at serve start so a stale URL can never pass as
  current; `wait_running` in quick mode waits for the file, not metrics.

## Consequences

- One mode per install. `setup --quick` refuses when a named config exists
  and vice versa; switching modes goes through `teardown`.
- The URL file is runtime state, not config: it is never written by setup,
  only by serve.
- No new dependencies; cloudflared was already required.
