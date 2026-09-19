# DECISION-BRIEF: quick tunnel mode (trycloudflare)

## Problem

`share setup` today requires a Cloudflare domain: a zone, a named tunnel, a
stored token, and a DNS record. A user who has no domain, or does not want to
wire one up, cannot use share at all, even though `cloudflared` supports a
zero-account mode: `cloudflared tunnel --url http://127.0.0.1:$port` prints a
random `*.trycloudflare.com` URL and serves it immediately.

## Options

1. **Quick mode beside named mode** (`share setup --quick`). One config file
   carries `mode=quick`; serve swaps `cloudflared tunnel run` for
   `cloudflared tunnel --url`, parses the printed URL into runtime state, and
   every other layer (caddy, index.tsv, live shares, folder index, hits) is
   reused unchanged.
2. A separate `share quick` command that runs a throwaway tunnel per
   invocation. Rejected: it bypasses index.tsv, `ls`/`rm`/`hits`, the service,
   and every guarantee the tool exists to provide.
3. Stay named-only. Rejected: the no-domain case is real and the incremental
   surface is small.

## Decision

Option 1. `--quick` is a setup-time mode, not a per-share flag.

## Consequences

- The URL is random and changes on every `start`/service restart. Links from a
  previous run are dead. This is inherent to trycloudflare and must be
  surfaced in `status`, the printed link flow, and docs, not hidden.
- `--host` is refused in quick mode: there is no zone to put a record in and
  no tunnel ingress to edit.
- `teardown` in quick mode has no Cloudflare resources; it stops serving,
  removes the service, and trashes the config.
- No token, no cert, no `jq`-level API work, no login is needed. `mode=quick`
  is the only new config key; a named config keeps working byte-for-byte.
