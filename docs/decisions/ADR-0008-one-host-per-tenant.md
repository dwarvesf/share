# ADR-0008: a tenant is one hostname; storage is local by default and cloud per link

Status: accepted
Date: 2026-10-05

## Context

Dwarves ran one team as two hostnames: machine-local links at `s.d.foundation` (a tunnel profile on the Mac Mini) and cloud links at `f.d.foundation` (an r2 profile, ADR-0007). People had to know which hostname held which link, and Share Bar showed two sections for one team. The personal tenant `s.han.ws` ran from a laptop, so every link answered 530 while it slept.

The operator direction: a tenant is one hostname with one shared list; storage is local by default exactly as share works today; R2 is optional per tenant and per link; one always-on machine is the origin. The design, the test plan, and the live probes are in `docs/specs/SPEC-008-one-host-per-tenant.md` and `docs/implementation-notes/one-host-per-tenant.md`.

## Decision

- One hostname per tenant. Storage shows as a badge on a row, never as a subdomain.
- Local by default. A tenant with R2 off runs today's code paths: no Worker, no bucket call, files byte-identical. `--cloud` is refused there with the line that names the admin command.
- R2 is turned on by the admin on the origin: `setup <host> --r2 --bucket <name> [--storage-default local|cloud] [--alias <old-host>]`. It adds a route Worker on `<host>/*` over the existing tunnel CNAME, so `--no-r2` (delete the route) is the whole rollback.
- The Worker reads one bucket key per request. A cloud record (`v:1`) is served from R2 and never reaches the tunnel. A machine pointer (`v:2`, `storage: machine`), no record, or an R2 error passes the request through to the origin on the same hostname. Any other record shape answers 404, so a stale or forged cloud id never falls back to a file on the origin.
- The origin writes a pointer record for every local link while R2 is on. Pointers feed one shared list on every machine and make the id namespace collision-proof (`If-None-Match: *`). A local add fails closed when the pointer cannot be written.
- Bucket rows are display data. A record read from the bucket never enters `rows()`, the index, the Caddyfile, a stage path, or shell arithmetic.
- A member machine publishes cloud links only. `--local`, live ports, and `--host` stay on the origin; a member cannot remove or refresh a machine row.
- `--alias <old-host>` folds a former r2 hostname into the tenant: the tenant Worker takes the alias's custom domain and answers 301 to the same path. The bucket and each gated link's Access app (name, AUD) are adopted in place, so every old link keeps working.
- `share migrate --to <ssh-target>` moves an R2-off origin between machines over ssh with the receiver's own `share import`, keeping ids, names, dates, expiries, and gates. The new origin always gets its own tunnel (`<old name>-m`); nothing on the old machine is deleted, only moved aside.
- The Worker passes an origin's 502 through unchanged. Only 530, 520 to 527, and a 503 with no `cf-cache-status` mean the machine is offline and answer the 503 offline page. A dead live port is a working machine, and its 502 is the origin's own answer.

Alternatives rejected:

- Two hostnames (the starting point): the operator direction rules it out.
- R2 as the default storage: every tenant would pay for and depend on Cloudflare storage it did not ask for.
- A second internal origin hostname behind an Access service token: a hostname, a secret with an expiry, and a token that would open every machine link to its holder. The route pass-through needs none of them.
- Tunnel first, R2 on a 404: cloud links would need the origin up, which defeats them.
- Reusing the old tunnel on the new origin: two connectors until the old machine stops, and a later `teardown` on the old machine would delete the new origin's tunnel.
- A Cloudflare redirect rule for the old hostname: the 301 stays in code the suite tests and the CLI deploys.

## Consequences

- With R2 on, every request to the tenant runs the Worker and one bucket read (two for a cloud hit). The origin's local publishing depends on R2 answering and on a stored publisher token; the gain is that no member's cloud link can collide with an origin link.
- Cloud links answer while the origin is off; machine links answer the 503 offline page. `/healthz` reports both legs through headers, so members join and publish while the origin is down.
- A Worker change ships only with a `WORKER_VERSION` bump, as ADR-0007 fixes. This work moved the Worker to version 4.
- A tenant moves between machines in one command, but only with R2 off. Moving an R2-on origin also moves the pointers and the publisher token, which is out of scope.
- An older share CLI on an origin with R2 on still serves and adds local links, without pointers. The next upgraded `ls` writes them and names any collision.
- Share Bar reads one list per tenant, with a storage badge, file-type icon, link type, and lock on each row.
