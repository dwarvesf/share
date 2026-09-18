# ADR-0001: a live or SPA share gets a named first-level hostname, never a random subdomain

Status: accepted

## Context

Sharing a running dev server needs a URL a browser can use without rewriting the app. A path prefix (`https://s.example.com/<id>/`) breaks any app that emits absolute asset paths. The natural fix is a hostname per share. Cloudflare Universal SSL covers the zone apex and one label (`*.example.com`) and nothing deeper; `*.s.example.com` needs Advanced Certificate Manager.

## Decision

- Keep the path prefix as the credential-free default for live shares, and print its caveat.
- `--host <fqdn>` gives a share its own hostname. The name must be a first-level label in the setup zone. `add` creates the CNAME and the ingress rule; `rm`, `prune`, and `teardown` delete them.
- No wildcard DNS record is ever created.

## Consequences

- A hostname share needs a Cloudflare credential at `add` time (`CLOUDFLARE_API_TOKEN` or the login `cert.pem`). The credential-free path still works for the prefix case.
- Every hostname share is one DNS record and one ingress rule that share must clean up; teardown sweeps them.
- Caddy needs a reload path, so its admin endpoint moves from `off` to a unix socket inside `$root`.
