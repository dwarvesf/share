# SPEC-008: one hostname per tenant, cloud storage optional per link

Status: VALIDATED (three rounds; the round-3 critical folded without a fourth review per the cap; remaining warnings in the Decision Log, round 3)
Lane: full (an API and data contract between the CLI, the Worker, and Share Bar; a new public route in front of live links; a migration of two production hostnames)
Depth: research (outside: a route Worker passing requests through to a tunnel on its own hostname, Access order against a route Worker, custom-domain rebind, Access destination edits; TASK-1a and TASK-1b sample each before the task that consumes it) | blind-spot (failure: the Worker passes a request to the tunnel that a cloud record or a gate should have stopped, or the migration leaves a link dead)
References: SPEC-004 (Access gate), SPEC-005 (profiles), SPEC-006 (Share Bar across profiles), SPEC-007 (R2 backend), ADR-0002, ADR-0003, ADR-0005, ADR-0006, ADR-0007; `bin/share` `cmd_add`, `cmd_add_r2`, `rand_id`, `rows`, `share_url`, `cmd_ls`, `cmd_state`, `cmd_state_r2`, `cmd_profiles_json`, `cmd_setup`, `cmd_setup_r2`, `cmd_teardown`, `worker_js`, `r2_call`, `r2_snapshot`, `r2_healthz`; `mac/Sources/ShareBarCore/Snapshot.swift`, `MenuModel.swift`; `mac/Sources/ShareBar/StatusItemController.swift`.
Supersedes: SPEC-007 DEC-006 (a second hostname `f.d.foundation` beside `s.d.foundation`); SPEC-007 `## Out of scope` items "Share Bar reading an r2 default profile" (now in scope through the Keychain token only) and "migrating a tunnel profile's shares into a bucket" (now `share migrate` between machines; tunnel to bucket stays out).

## Problem

A tenant today can be two hostnames. Dwarves publishes machine-local links at `s.d.foundation` (the `dfoundation` tunnel profile on the Mac Mini) and cloud links at `f.d.foundation` (the `files` r2 profile, bucket `share-dfoundation`). People must know which hostname holds which link, and Share Bar shows two sections for one team. The personal tenant `s.han.ws` is served from the MacBook Air, so every personal link answers 530 while the Air sleeps.

The operator direction (Han, firm):

- A tenant is ONE hostname with ONE shared list.
- Storage is local by default: the origin machine's files through the tenant's tunnel, exactly as share works today.
- R2 is optional per tenant. It is off until the tenant admin enables it. Once on, each link picks local or cloud (`--cloud`), with a tenant default the admin sets.
- Exactly one always-on machine per tenant is the tunnel origin. The Mini is the origin for both tenants.
- Storage shows as a small indicator in the app, never as a separate subdomain. Share Bar rows also show the file type and the link type.

## Context (research, 2026-10-01)

Read-only probes from the Mini with the Toolkit API token (names, codes, and counts only; no id, token, or account id quoted). Commands: `## Grounding`.

| Item | State |
|---|---|
| Mini profiles | `default` not set up; `dfoundation` serving `s.d.foundation` (tunnel `share-s-d-foundation`, `hosts=Mac-mini`, port 8791, one gated snapshot `a68960`); `files` serving `f.d.foundation` (`backend=r2`, bucket `share-dfoundation`, one gated cloud share `ba6377`) |
| `d.foundation` zone | `s.d.foundation` is a proxied CNAME to the tunnel; `f.d.foundation` is the Worker custom domain of `share-f-d-foundation` (an AAAA record the domain manages); one existing route Worker on the zone (`chat.d.foundation/dw-chat/*`), so route Workers work on this plan |
| Dwarves Access apps named `share ...` | one on `f.d.foundation/ba6377{,/*}`, one on `s.d.foundation/a68960{,/*}` |
| The guide link | `https://f.d.foundation/ba6377/support-ticket-guide/` answers 302 to the Dwarves Access login with `kid` equal to the app's AUD (gated cloud share) |
| `han.ws` zone (account "Han Ngo") | `s.han.ws` is a proxied CNAME to tunnel `air-share`, healthy with 4 connections (the Air is online now); R2 enabled, no share bucket; Analytics Engine answers; one route Worker exists (`radar.han.ws/*`); no Access app named `share ...`, so no personal gated share exists |
| Reachability | the Air reaches the Mini over ssh; the Mini cannot reach the Air |

## Picture

The request path for one tenant hostname:

```
 visitor  https://s.d.foundation/<id>/<name>
          https://f.d.foundation/<path>  -- Worker answers 301 --> https://s.d.foundation/<path>
              |
              v
 Cloudflare edge: TLS; per gated share an Access app on <host>/<id> and <host>/<id>/*
              |                       (one app per link, either storage, as today)
              v
 +-- R2 off (s.han.ws) -----------+   +-- R2 on (s.d.foundation) ---------------------------+
 | no Worker; the CNAME sends the |   | Worker share-<host-with-dashes> on route <host>/*   |
 | request to the tunnel (today)  |   |   400 on %2F %5C %2E, low escapes, //               |
 +---------------+----------------+   |   /healthz: own answer plus a probe of the tunnel   |
                 |                    |   GET m/<id> from the bucket                        |
                 |                    |     cloud record -> R2 bytes (SPEC-007 checks, the   |
                 |                    |                     Access JWT for a gated record)   |
                 |                    |     machine record, no record, R2 error             |
                 |                    |       -> fetch(request): same host, the route is    |
                 |                    |          skipped, the request goes to the origin    |
                 |                    +--------------------------+--------------------------+
                 v                                               v
 tunnel (one per tenant) --> cloudflared on the origin (the Mini) --> caddy --> pub/<id> or a live port
```

Who writes what:

```
 origin (Mini)                         member (any other machine, R2 on only)
 share add f          -> pub/<id>      share add f -> o/<id>.<nonce>/ + m/<id> (cloud)
 share add --cloud f  -> o/ + m/<id>   share add --local f, add 3000 -> refused: not the origin
 share add 3000       -> live row
 every local add, R2 on: m/<id> = {"v":2,"storage":"machine",...}  (reserves the id, feeds the list)
                     \___________________ bucket share-<tenant> ___________________/
                                          m/<id> records = the one shared list
```

## Design

### Approaches considered

| Question | Options | Chosen, with the reason |
|---|---|---|
| Default storage | R2 for snapshots, the tunnel for live and `--local`; the tunnel for everything, R2 per link | the tunnel (operator direction, 2026-10-01). A tenant with R2 off is today's share, byte for byte, with zero new infrastructure. R2 adds survival while the origin is off and publishing from other machines, and the tenant pays for it only when the admin turns it on. |
| How cloud and machine links share one hostname | two hostnames (today); a Worker in front that routes per id; a tunnel in front that proxies cloud ids to R2 | a Worker in front, only on tenants with R2 on. The edge already terminates TLS and runs Access there; a Worker can read the bucket through its binding with no token. A tunnel in front would need the origin up to serve cloud links, which defeats them. |
| How the Worker reaches the tunnel | (A) a route `<host>/*` over the existing proxied CNAME, `fetch(request)` passes through to the origin; (B) a second, internal origin hostname behind an Access service token, the Worker fetching it with the token's secret; (C) the Worker as custom domain and the tunnel on another name | (A). The tunnel and its CNAME stay exactly as they are, so deleting the route is the whole rollback. No new hostname, DNS record, Access app, or service-token secret exists (the Worker keeps holding no credential, SPEC-007's rule). (B) costs a hostname, a secret with an expiry, and a second ingress rule, and its token would open every machine link to anyone holding it. (C) would change every existing link. TASK-1a(a) proves the pass-through. |
| Order inside the Worker | the tunnel first, R2 on 404; R2 first, the tunnel otherwise | R2 first (operator direction): one bucket read decides, the origin is never asked about a cloud link, and cloud links answer while the origin is off. |
| The shared list across machines | merge only on the origin (its index plus the bucket); a pointer record `m/<id>` for every machine link | pointer records, written only when R2 is on. A member's `ls` and Share Bar see the origin's links too, and one namespace means a cloud add can never take an id the origin holds (`If-None-Match: *` on one key). With R2 off there is one publisher, so its index is the list. |
| The old hostname `f.d.foundation` | keep both; a Cloudflare redirect rule plus a placeholder DNS record; the tenant Worker answers 301 for an alias host | the tenant Worker takes the alias's custom domain and answers 301 to the same path on the tenant host. One Worker per tenant; the redirect lives in code the suite tests and the CLI deploys. |
| Moving the Air's shares to the Mini | publish through R2 and back; rsync plus a hand-edited index; `share migrate --to <ssh>`, the receiver's own `share import` writing each share | `migrate` over ssh: the Air can reach the Mini, R2 is off on `s.han.ws`, and the receiving CLI validates and writes its own index (the only writer, as ADR-0003 keeps the app out of share's files). Ids and paths stay, so every link stays. |
| Which tunnel the new origin runs | reuse `air-share` on the Mini (`setup --tunnel-name air-share`, no DNS change); a new tunnel `share-<host>` with the CNAME repointed (`setup --force`) | a new tunnel. A reused tunnel has two connectors until the Air stops, so setup's own three-in-a-row live check can land on the Air and fail; and the Air's config would keep the tunnel id the Mini now runs, so any later `teardown` on the Air deletes the Mini's tunnel. A new tunnel keeps each machine's teardown confined to its own tunnel (teardown deletes a DNS record only when it points at that tunnel). The cost is the DNS Edit scope and a short gap, bounded in `### Moving a tenant's origin`. |

### Tenant, origin, member

- A tenant is one hostname. Its origin is the one machine in the tunnel profile's `hosts=` (already a single machine: Cloudflare load-balances between connectors, so two serving machines give random 404s).
- R2 off: the origin is the only publisher. Other machines have no profile for the tenant; `share setup --quick` stays available to them as today.
- R2 on: the origin profile keeps its tunnel and gains `bucket=`, `r2_endpoint=`, and `storage_default=`. Any other machine is a member: a SPEC-007 r2 profile joined with a publisher token (`share --profile <p> setup <host> --backend r2 --bucket <b>`). A member publishes cloud links only.
- `docs/setup.md` onboarding says so plainly: a teammate can publish to a tenant only when its R2 is on.

### Enabling R2 on a tenant (admin, on the origin)

`CLOUDFLARE_API_TOKEN=<admin> share [--profile <p>] setup <host> --r2 --bucket <name> [--storage-default local|cloud] [--alias <old-host>]`

It runs on the origin only (`host_ok`, else `run this on the origin, <hosts>`), on a tunnel profile already set up for `<host>`. SPEC-007's setup steps hold where this table does not replace them. Every read and every refusal comes before the first write.

| Step | Call | Refuse or stop when |
|---|---|---|
| 1 | profile checks | not a named tunnel profile for `<host>`; quick mode; `--alias` equal to `<host>` or not a hostname |
| 2 | zone, account, role | the token cannot read `workers/scripts/<worker>/settings` (only an admin enables R2) |
| 3 | SPEC-007 steps 4 and 5 on the bucket and the Worker `share-<host-with-dashes>` | as SPEC-007, with one change: a marker naming `--alias` instead of `<host>` is accepted (the fold) |
| 4 | with `--alias`: `GET workers/domains?hostname=<alias>` | the alias's custom domain names a service that is not `share-<alias-with-dashes>`, or that Worker's bindings are not `HOST == <alias>` and `BUCKET == <b>` |
| 5 | `GET zones/<z>/workers/routes` | a route on `<host>/*` or a wider pattern naming another script |
| 6 | the bucket snapshot (every `m/` record) and the local index | a local row's id holds a cloud record (a collision; named, nothing written) |
| 7 | with `--alias`: every gated cloud record's Access app (`GET access/apps/<uuid>`) | an app whose name is not `share <id> <alias> <nonce>`, or no Apps Edit scope |
| 8 | deploy the Worker (bindings below), subdomain and previews off with the read-back (SPEC-007 step 10) | read-back not `false,false` |
| 9 | pointer records: `PUT m/<id>` with `If-None-Match: *` for every local row | a 412 on an id step 6 saw free: die, the route is not attached yet |
| 10 | with `--alias`: each step-7 app gains `<host>/<id>` and `<host>/<id>/*` (PUT keeps every field and the AUD; TASK-1b(g)); the gate probe on the new destinations passes three rounds (SPEC-004) | gate timeout: the added destinations are removed, die |
| 11 | write `bucket=`, `r2_endpoint=`, `storage_default=` (default `local`), and `aliases=` into the config, so every later die leaves a state `--no-r2` and a rerun can read | |
| 12 | marker `PUT share.json` with `If-Match`: `{"v":1,"host":"<host>","aliases":["<alias>"]}` | 412 |
| 13 | `POST zones/<z>/workers/routes {pattern:"<host>/*", script:<worker>}` | an API error |
| 14 | with `--alias`: `PUT workers/domains {hostname:<alias>, service:<worker>}` (TASK-1b(f): rebind in place, or DELETE then PUT with the gap measured) | an API error |
| 15 | live checks: `/healthz` three times in a row with this CLI's `X-Share-Worker` pair and `X-Share-Tunnel: 1`; a probe file through the tunnel leg; with `--alias`: `https://<alias>/healthz` answers 301 to `https://<host>/healthz` | timeout: die naming the leg. Without `--alias` the named rollback is `--no-r2`. With `--alias` the die prints the alias rollback list (`## Migration`, Dwarves), never `--no-r2` alone |
| 16 | with `--alias`: each step-7 app drops its `<alias>` destinations; the local profile whose `hostname` is `<alias>` hands its `r2-own` lines to this profile | |

A folded app keeps its name `share <id> <alias> <nonce>` and its AUD. `access_delete` and the by-name purge accept an app named for this host or for any host in `aliases=`, so `rm` and expiry of a folded share delete its app.

A rerun of the same command after a die at any step converges: each write is idempotent (deploy compares the SHA, pointers answer 412 for an id that already holds this machine's pointer and count as done, the app PUT and the marker PUT compare before writing, the route and domain reads show an existing binding to this Worker).

Worker bindings on a tenant: SPEC-007's set plus `PASS="1"` (pass misses to the origin) and `ALIASES` (comma list). An r2-only profile (SPEC-007, custom domain) keeps `PASS=""` and today's answers.

SPEC-007's `setup <host> --backend r2 --bucket <b>` refuses a tenant host in its admin role, even with `--force`, before any write: when the deployed Worker binds `PASS="1"`, when the marker holds `aliases`, or when a route on `<host>/*` exists. Its message names the tenant command, `run '<me> setup <host> --r2 --bucket <b>' on the origin`. Without this, an admin token in the environment on a member (the join path's version hint points there) would redeploy the Worker without `PASS` and `ALIASES`, and replace the tunnel CNAME with a custom domain, taking every machine link and the alias down. The join role is unchanged; the join's version-mismatch hint names the tenant command when `X-Share-Tunnel` is present.

`share [--profile <p>] setup <host> --no-r2` (admin token, on the origin) is the rollback for a tenant without an alias: delete the route, then drop the four config keys. It refuses while the config's `aliases=` or the marker's `aliases` is non-empty (`<alias> redirects here; run the alias rollback first: ...` with the list), because an alias whose 301 lands on a plain tunnel turns every folded cloud link into a 404. The tunnel serves the hostname alone again. Pointer records, cloud records, the bucket, and the Worker stay; `teardown --yes --purge` on a member, or the purge path on the origin, removes them as SPEC-007 says.

### Per-link storage on the origin

| `add` form | R2 off | R2 on, `storage_default=local` | R2 on, `storage_default=cloud` |
|---|---|---|---|
| `add <file\|dir>` | local | local | cloud |
| `add --cloud <file\|dir>` | refused: `R2 is off for <host>; the tenant admin enables it with '<me> setup <host> --r2 --bucket <name>'` | cloud | cloud |
| `add --local <file\|dir>` | local | local | local |
| `add <port>`, `--host` | local (live, own host) | local | local |
| `--cloud` with a port or `--host` | refused: `live links and --host stay on the origin's tunnel` | refused | refused |
| `--cloud` with `--local` | refused (usage) | refused | refused |

A cloud add on the origin runs SPEC-007's `cmd_add_r2` path unchanged. A member runs it for every add; `--local` and `<port>` on a member die with `<host> serves local links from its origin; this machine publishes cloud links only`.

`rm`, `refresh`, and `hits` dispatch on the row's storage. On the origin a machine row takes today's tunnel path (plus its pointer delete) and a cloud row takes SPEC-007's r2 path. On a member, `rm` and `refresh` of a machine row die before any call with `<id> is served from the tenant's origin; remove it there`, because deleting the pointer would report success while the origin keeps serving the file (gated or public), and the origin's next reconcile would write the pointer back.

With R2 on, a local add on the origin also writes the id's pointer record:

1. `rand_id` checks the local index, `pub/`, and `access-pending` as today, then the bucket as SPEC-007's r2 branch does (`GET m/<id>`, the `o/<id>.` prefix scan).
2. After the stage is built and before `stage_publish` (and, for a gated add, before the Access app): `PUT m/<id>` with `If-None-Match: *` and `{"v":2,"id","storage":"machine","name","by","added","expires","opts","type"}`. `opts` keeps only `noindex`, `live`, and `gated` (a flag, never the rule, so teammates' addresses stay out of objects every member reads). A 412 picks a fresh id; any other failure dies before anything is served, naming R2 (a tenant with R2 on keeps one namespace, so a local add fails closed; DEC-006 states the cost).
3. `rm` and `prune` of a local row delete its pointer after the local removal. Without a resolvable token (the login service's hourly prune runs with `SHARE_API_TOKEN_OFF=1`) the pointer stays; it is harmless (the Worker passes the id to the tunnel, which answers 404), and the next interactive `ls` or `prune` on the origin, or any member's `prune` once `expires` is past, deletes it.
4. Reconcile on the origin's interactive `ls` and `prune`, keyed on `storage == "machine"` alone (one origin per tenant, so every machine record is the origin's, migrated rows included): a machine record with no local row, whose S3 `LastModified` is over 10 minutes old, and whose id is neither in `access-pending` nor under a held add lock, is deleted (an add that died after step 2); a local row with no pointer gets one (`If-None-Match: *`; a 412 means a cloud record holds the id: printed as `<id> is shadowed by a cloud link; rm one of them`, never auto-deleted).

Bucket rows are display data. A record read from the bucket, cloud or machine, never enters `rows()`, `index.tsv`, the Caddyfile, `refresh`, or a stage path, so a forged record cannot add a reverse proxy, a site block, or a source path on the origin. On a profile with a tunnel, the bucket reader writes its own snapshot file and never assigns `index` (SPEC-007's `r2_snapshot` rebinds `index` for the process, which on the origin would hand bucket rows to `write_caddyfile` in the same run). Every bucket key is checked against `^m/[0-9a-f]{6}$` (after URL decoding) before its record is read, displayed, built into a URL, or deleted. The same holds for every cloud verb on a profile with a tunnel: `cmd_rm_r2`, `r2_prune`, the cloud expiry, `hits`, and the purge read the reader's own file and never call `r2_snapshot`, never assign `index`, and never write `$index` (today `cmd_rm_r2` falls back to `r2_snapshot` and moves a file over `$index`), so one `prune` that expires a cloud row and then a local row renders only local rows.

The origin's interactive bare `prune` and `ls` run SPEC-007's cloud expiry, its gated-expiry rule, and the orphan sweep through that reader, because after the fold the origin may be the only publisher left; the login service's hourly prune (token off) touches local rows only, as today.

`by` is always `r2_by` (lowercase, `a-z0-9.-`): on local rows, pointers, `import`'s argument, and `refresh`'s `<host>:` match, so `Mac-mini` and `mac-mini` never disagree. The `v:2` reader applies `r2_record_row`'s checks plus: `id` equal to the key's id; `expires` matching `^[0-9]{1,11}$` and `added` matching `^[0-9]{4}-[0-9]{2}-[0-9]{2}$` before any shell arithmetic sees them; `name` and `by` free of control bytes and tabs, `by` in the hostname set; `opts` tokens only from `noindex`, `live`, `gated`; `type` from the type table; any other field ignored. A record that fails is skipped like a forged row.

Record versions: cloud records stay `v:1` and gain an optional `type` field that `v:1` readers ignore, so a v0.8.0 CLI and Worker keep reading every cloud record. Machine records are `v:2` (`WORKER_RECORD_V` becomes 2): a v0.8.0 CLI drops them from `ls` and its orphan sweep skips with a warning, and a v0.8.0 Worker answers 404 for them, which is correct for a Worker that cannot pass through. The new CLI's orphan sweep (`r2_record_raw`) accepts a `v:2` record whose `storage` is `machine` and which has no `prefix` as readable and referencing no upload, so pointers never block the sweep; only an unreadable record or one above `v:2` still does.

### The Worker (WORKER_VERSION 3)

Checks run in this order. Rows marked "as SPEC-007" are unchanged.

| # | Request | Answer |
|---|---|---|
| 1 | Host is in `ALIASES` | GET or HEAD: 301 to `https://<HOST><raw path and query>`; other methods: 405 |
| 2 | Host is not exactly `HOST` | 404 |
| 3 | raw path holds `%2F`, `%5C`, `%2E`, a low escape, or `//` | 400 (as SPEC-007; now also in front of the tunnel leg) |
| 4 | `/healthz`, `PASS` empty | as SPEC-007 |
| 5 | `/healthz`, `PASS` set | the Worker fetches `https://<HOST>/healthz` (the route is skipped, TASK-1a(a)) with a 3 s timeout. A `200 ok` sets `X-Share-Tunnel: 1` and answers `200 ok`; anything else sets `X-Share-Tunnel: 0` and answers `503 tunnel down`. Both carry `X-Share-Worker` and `X-Share-Gate` |
| 6 | first segment is not 6 lowercase hex | `PASS` set: pass through (step 9); else 404 |
| 7 | `GET m/<id>` returns a `v:1` record with no `storage` | SPEC-007 rows: version, id, prefix, and expiry checks (404 on any), the JWT for a gated record (404), then GET or HEAD served from R2 (other methods 405), hits counted |
| 8 | a `v:2` record whose `storage` is exactly `machine`; no record; or `BUCKET.get` itself throws or exceeds 2 s | `PASS` set: pass through; else 404 |
| 8b | any other record: not JSON, a `v` above 2, `v:2` with another `storage`, `v:1` with a `storage` key | 404, never passed through |
| 9 | pass through | `fetch(request)`, any method, the body streamed, the original headers (the Access JWT and cookie included). The origin's answer goes back rewrapped (`new Response(r.body, r)`, so `no-store` and `noindex` can be set on headers a `fetch` answer holds immutable), with status and body unchanged; a 101 WebSocket answer goes back untouched (TASK-1a(d)); except a 502, 503 that is not the origin's own, 520 to 527, or 530 (TASK-1a(e) pins the set): `503`, `Retry-After: 60`, `Cache-Control: no-store`, `X-Robots-Tag: noindex, nofollow`, body `the machine serving this link is offline; try again later`. No hit is counted |

Callers of `/healthz` read the cloud leg from the headers, never from the status alone: a `503` carrying a well-formed `X-Share-Worker` pair and `X-Share-Tunnel: 0` means the Worker is up and the origin is down. `r2_healthz` sets `hz_code=200` for it and a new `hz_tunnel=0`, so a member's join (`r2_wait_healthz join`), a gated `add` on a member, and an r2 `state` (`ready: true`) keep working while the origin is off, which is the case R2 exists for. Only the origin's own `status` and `state` report the tunnel leg, as they do today.

A pass-through never serves R2 bytes, and a cloud record never reaches the tunnel. A gated machine link keeps its gate at the edge: Access runs before a route Worker (TASK-1a(b)) and the Worker forwards the visitor's credentials (TASK-1a(c)). An expired or malformed cloud record answers 404 and is never passed through, so a stale cloud id cannot fall back to a same-id file on the origin. Caddy keeps its own `@encsep` rule, so the origin refuses encoded separators even with the route deleted.

Every s.d.foundation request now runs the Worker and one bucket read (two for a cloud hit). Dwarves is on the Workers paid plan; live dev-server links (many small requests) cost Worker requests in the included 10 million.

### One shared list

`ls`, `state`, and `profiles --json` read one row set per profile:

| Profile | Rows |
|---|---|
| origin, R2 off | the local index, as today |
| origin, R2 on | the local index, plus every cloud record (machine records are the origin's own pointers; the local index is their truth, and an orphan pointer is the reconcile's, not a row) |
| member | every bucket record |

Each row carries:

| Field | Values | Source |
|---|---|---|
| `storage` | `machine` or `cloud` | the row's origin |
| `kind` | `snapshot` or `live` (the link type, unchanged) | the index opts, the record `opts` |
| `type` | `pdf`, `image`, `video`, `audio`, `folder`, `site`, `markdown`, `archive`, `text`, `other` | the table below |
| `by` | the machine that published it: the origin's own `this_host` for local rows, the import's `by=` for migrated rows, the record's `by` for bucket rows | |
| `access` | the rule or `null` (unchanged); a member sees `gated` for the origin's gated machine rows, because pointers carry no rule | |

`share ls` prints one tag before each link: `cloud`, `machine`, or `live` (a live row is always machine), then the type and `by=<machine>`.

File type, first match wins:

| `type` | Rule |
|---|---|
| `site` | a live link; a folder holding `index.html` at its root; a single `.html` or `.htm` file |
| `folder` | any other folder |
| `markdown` | `.md`, `.markdown` |
| `pdf` | `.pdf` |
| `image` | `.png .jpg .jpeg .gif .webp .svg .heic .ico .avif` |
| `video` | `.mp4 .mov .webm .m4v .mkv` |
| `audio` | `.mp3 .wav .m4a .aac .flac .ogg` |
| `archive` | `.zip .tar .gz .tgz .bz2 .xz .7z .rar .dmg` |
| `text` | `.txt .csv .json .yaml .yml .toml .xml .log .sh .py .js .mjs .ts .go .rs .rb .swift .java .c .h .css .sql` |
| `other` | anything else |

Local rows are typed at read time from `pub/<id>` (`-d`, `-f`). New cloud records and pointers store `type` at add time. A `v:1` cloud record without `type` is typed by its name's extension, and a name with no extension counts as `folder`.

`state` (schema stays 1; every addition is a new key): `shares[].storage`, `shares[].type`, `shares[].by`; top-level `r2` (`true` when the profile reads a bucket) and, on an origin with R2 on, `storage_default`. When bucket rows cannot be read, `state` still prints the local rows and adds `cloud_error` (the reason line), so the menu never loses machine links to an R2 problem.

Token rule for listings: `state` and `profiles --json` read the bucket only with a token from the Keychain item or the 600 file. A profile whose token source is `api_token_cmd` (it may prompt) or the environment gets `cloud_error: "the menu reads cloud links only with a stored token: <me> api-token"`. `ls` uses the full resolution, as SPEC-007. `profiles --json` already lists r2 rows (only the text `profiles` sets `SHARE_STATE_BRIEF`). To bound the poll's cost, `state` reads the `m/` listing (its `LastModified` per key), drops the keys whose id is in the local index (the origin's own pointers), and fetches only the newest 25 of the rest, the most any section shows; it reports the remaining listing count as `cloud_more`, which the section adds to its `more` line. `ls` still reads every record. At a 60 s poll that is about 1.1 million Class B reads and 43,000 listings a month per polling Mac, roughly $0.60 at list prices, whatever the record count.

### Share Bar

One section per profile, as SPEC-006. After the migration the Mini shows `default · s.han.ws` and `dfoundation · s.d.foundation`; the `files` section is gone. Each row:

```
 [type icon] support-ticket-guide        30d left  [storage] [link type] [lock]
```

- `NSMenuItem.image` is the file-type symbol (template).
- The trailing column, after the expiry text, holds three text attachments: the storage badge, the link-type marker, and `lock.fill` on a gated row (SPEC-006's lock moves from `image` into this group).
- The accessibility title is `<name>, <trailing>, <type word>, <storage word>, <link word>` plus `, login required` on a gated row.
- A section whose state has `cloud_error` gets one disabled line `Cloud links not listed: <cloud_error>`.

SF Symbols (every one ships on macOS 13, the package minimum; a unit test resolves each with `NSImage(systemSymbolName:)` and the app falls back to no image when one fails):

| Role | Value | Symbol | Accessibility word |
|---|---|---|---|
| type | `pdf` | `doc.richtext` | PDF |
| type | `image` | `photo` | image |
| type | `video` | `film` | video |
| type | `audio` | `waveform` | audio |
| type | `folder` | `folder` | folder |
| type | `site` | `globe` | site |
| type | `markdown` | `doc.plaintext` | Markdown |
| type | `archive` | `archivebox` | archive |
| type | `text` | `doc.text` | text |
| type | `other` (or an unknown value) | `doc` | file |
| storage | `machine` | `desktopcomputer` | on this tenant's machine |
| storage | `cloud` | `cloud` | in the cloud |
| link | `snapshot` | `doc.on.doc` | snapshot |
| link | `live` | `dot.radiowaves.right` | live server |
| access | gated | `lock.fill` | login required |

A row with no `storage` (an older CLI) shows no storage badge; a row with no `type` uses `doc`. `ShareBarCore` holds the mapping as plain strings (`RowGlyphs.type(_:)`, `.storage(_:)`, `.link(_:)`), so it is unit-tested without AppKit.

The publish dialog gains a `Storage` popup only for a profile whose state has `r2: true` and is the origin (`serves_here`): `On <machine>` or `In the cloud`, preselected from `storage_default`; the argv gains `--cloud` or `--local`. A member profile shows `In the cloud` as a disabled label.

### Moving a tenant's origin: `share migrate`

`share [--profile <p>] migrate --to <ssh-target> [--remote-profile <rp>] [--remote-bin <path>] [--yes]`, run on the current origin while it is online. It needs `CLOUDFLARE_API_TOKEN` (Tunnel Edit, DNS Edit, Zone Read on the tenant's zone) and an ssh login on the target as the user who will run share there. It moves a tenant with R2 off only: on a profile with `bucket=` it refuses (`R2 is on for <host>; moving its origin also moves the pointers and the publisher token, which this version does not do`).

Every remote call is one fixed string that any login shell (fish on Han's machines) parses the same way, because ssh joins its argv and the remote shell parses it: `/bin/bash -c "$(printf %s <base64 script> | base64 -D 2>/dev/null || printf %s <base64 script> | base64 -d)" share-migrate <args>` built with no quote or backslash outside the base64, where every argument is a checked slug or base64 (`--remote-bin` and `--remote-profile` included); the script sets `PATH` from the `--remote-bin` directory plus `/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin`, and a target starting with `-` is refused. The switch token travels on ssh stdin to a new `setup --token-stdin` flag, which reads one line into the process's own `CLOUDFLARE_API_TOKEN`.

```
 Air (old origin)                                     Mini (new origin), over ssh
 1 preflight: named tunnel profile, this host in      remote: <bin> import --probe -> "share-import 1";
   hosts, no --host row, token resolves               <bin> --profile <rp> state: not_setup, or set up
                                                      for the same hostname; an empty index and pub/
                                                      when not_setup; the profile's port pair free;
                                                      a Keychain write/read/delete round trip and
                                                      launchctl print gui/<uid> answering
 2 per snapshot row:                                  <bin> --profile <rp> import <id> <expires> <by>
   tar -C pub/<id> -cf - . | ssh ------------------->   <added> <b64 name> <b64 src> <b64 opts>
                                                        (stdin: the tar; validates, stages, publishes)
 3 the switch: the token on ssh stdin --------------> CLOUDFLARE_API_TOKEN from stdin;
                                                      <bin> --profile <rp> setup <host> --force
                                                        --token-stdin
                                                      (new tunnel share-<host>, CNAME repointed,
                                                       service, live check)
 4 verify through https://<host>/: a nonce file that only the target holds answers 200
   three times in a row (so the Air cannot answer for it), then each moved link answers
   200, and each gated one 302 with kid equal to its app's AUD (a 200 there fails)
 5 retire: moved rows -> index.migrated, pub/<id> -> migrated/<id> (nothing deleted),
   then the teardown path: service, tunnel air-share deleted, DNS left alone (it no longer
   points at this tunnel), tokens forgotten
```

- `import` is a new verb (one usage line: `share import ...   used by migrate over ssh`). It refuses: an `expires` outside `^[0-9]{1,11}$`, an `added` outside `^[0-9]{4}-[0-9]{2}-[0-9]{2}$`, a `src` with a control byte or a tab; an id that is not 6 lowercase hex, or that exists in the local index, `pub/`, or `access-pending`; a name that is empty, starts with `.`, holds `/` or a control byte; opts other than `noindex`, `access=<uuid>`, `access_rule=<rule>` (a live or `host=` row never arrives); a `by` outside the hostname character set. It spools stdin to a temp file under the profile root (capped at `SHARE_IMPORT_MAX_BYTES`, 2 GiB) and lists it with `tar -tvf` first: any member that is not a regular file or a directory (symlinks and hardlinks included), an absolute path, a `..` segment, or a dotfile refuses the whole import before anything is extracted. Only then does it extract into a fresh stage, and it refuses again if `find` sees a link count above 1 or anything but files and directories (TASK-7a (its first step) pins the flags on bsdtar and GNU tar). It then publishes as `stage_publish` does and appends the row with the original added date and expiry, `by=<by>` added to opts, and `src` set to `<by>:<original src>`. It reloads caddy when the profile is serving and works on a `not_setup` profile (pub and index need no setup). It never creates an Access app; the gated row keeps its `access=<uuid>`, because the app's destinations (`<host>/<id>`) do not change with the machine.
- `refresh` of a row whose `src` starts with `<host>:` for another host dies with `<id> was moved from <host>; re-add it from a source on this machine`.
- Live rows and their ports are listed as `not moved: live link <id> (port <n>); after the move run '<me> add <n>' on the new origin`. `migrate` refuses while a `--host` row exists (`<fqdn> has its own hostname on this tunnel; remove it first: <me> rm <id>`).
- Stop points: a failure in steps 1 and 2 changes nothing on this machine and leaves imported copies on the target, unserved unless its profile serves; a rerun skips ids the target already holds with the same name and added date. A failure in step 3 leaves this machine serving; the DNS record may already point at the new tunnel, and `migrate` then prints the rollback, `<me> setup <host> --tunnel-name <this config's tunnel_name> --force` on this machine. The tunnel name is explicit because `setup` derives `share-<host-with-dashes>` when none is given, which is the name the target just created: without it the old origin would join the new tunnel as a second connector. With it, setup reuses `air-share` and repoints the CNAME there; the target's new tunnel is left with no DNS record and serves nothing. A failure in step 4 stops before step 5 and names each link that did not answer.
- `--yes` skips the one confirmation (`Move <n> links of <host> to <ssh-target> and retire this machine as its origin? [y/N]`).
- Test seam: `SHARE_MIGRATE_SSH` replaces `ssh -o BatchMode=yes <ssh-target>` with a local command (for example `env HOME=<dir>`), so the suite and the rehearsal run both sides on one machine. The seam joins the remote argv into one string and runs it through `fish -c` when fish is installed, else `sh -c`, so the suite parses the command as a real login shell does.

What visitors see: before the run, the Air serves (530 whenever it sleeps, as today). During step 3, from the CNAME change until the Mini's connector is up (setup writes DNS before it stores the token, installs the service, and starts; its live check allows 60 s), up to about a minute of 530; R2 measures the real gap. After it, the Mini serves every moved link at the same URL. Live links from the Air end at step 5.

### Tokens

SPEC-007's model holds: an admin token from the environment for setup work, never stored; one bucket-scoped publisher token per machine, stored with `share api-token`, with an `expires_on`.

| Role | Scopes | Source |
|---|---|---|
| admin, `setup --r2`, `--no-r2` | SPEC-007's minimal admin set (Workers Scripts Edit on the account, DNS Read and Zone Read on the zone, Workers R2 Storage Edit), plus Workers Routes Edit on the zone (the route), plus Access Apps and Policies Edit and Access Organizations Read (the alias fold's destination edits and the `TEAM` binding) | `op://Toolkit/cf-api-token/credential` when TASK-1b(h) shows it holds every scope on the tenant's account; else a run-scoped token minted through `op://Toolkit/cf-tokens-admin` (`POST /user/tokens`, `expires_on` one day) |
| `migrate` switch | Cloudflare Tunnel Edit, DNS Edit, Zone Read on the tenant's zone | `op://Toolkit/cf-api-token/credential` when TASK-1b(i) shows it edits tunnels and DNS on the personal account; else a run-scoped token as above |
| origin publisher (Mini, `dfoundation`) | Workers R2 Storage Bucket Item Write on `share-dfoundation` only, plus SPEC-004's Access scopes (gated adds), plus Zone Read, plus Account Analytics Read (`hits` of a cloud row) | minted once through `cf-tokens-admin`, `expires_on` set, stored with `share --profile dfoundation api-token`. `api-token` and every bucket call key the r2 branch on `bucket=` (today they key on `backend == r2`), so `r2_publisher_check` refuses an admin or account-wide R2 token on the origin too, when stored and when first used from the environment |
| member publisher | as SPEC-007 | as SPEC-007 (DEC-007 there: one per teammate) |

No token reaches argv, a file, a Worker binding, or an object. `migrate` sends the switch token over ssh stdin, read on the target by `IFS= read -r` into the environment of the one `setup` process.

## Migration

Both runs follow a rehearsal on throwaway hostnames (`## Test plan`, R1 and R2). Each step names its rollback.

### Dwarves (`s.d.foundation`, R2 on, `files` folded in)

| # | Step | Check | Rollback |
|---|---|---|---|
| D1 | upgrade share on the Mini to the release | `share --profile dfoundation status` unchanged | `brew` pin of the previous version |
| D3 | `CLOUDFLARE_API_TOKEN=<admin> share --profile dfoundation setup s.d.foundation --r2 --bucket share-dfoundation --alias f.d.foundation` (storage default `local`) | the setup's live checks; `https://f.d.foundation/ba6377/support-ticket-guide/` answers 301 to `https://s.d.foundation/ba6377/support-ticket-guide/`, which answers 302 to the Access login with `kid` equal to the app's AUD; `a68960` still gated; `share --profile dfoundation ls` shows both rows, `ba6377` as `cloud`, `a68960` as `machine` | below |
| D2 | after D3 (its config gives `api-token` the bucket and endpoint): mint the origin publisher token (table above); `share --profile dfoundation api-token` stores it in the Keychain from a GUI login session on the Mini (the session Share Bar and Han's adds run in) | `api-token --check` passes the bucket and Access lines; a local `add` and `rm` from that session write and delete a pointer | revoke the token; local adds fail closed until a token is stored |
| D4 | `share --profile files teardown --yes` (r2 teardown is local: config, token, `r2-own` go; the bucket and every share stay) | `share profiles` lists `default` and `dfoundation`; Share Bar shows one Dwarves section | only after the D3 rollback (the join reads the marker host): `share --profile files setup f.d.foundation --backend r2 --bucket share-dfoundation`; revoke the `files` profile's publisher token once D6 is done |
| D5 | right after D3: move any external monitor of `f.d.foundation/healthz` to `s.d.foundation/healthz` | vps-mon shows the check green | revert the catalog line |
| D6 | after seven days with no rollback: delete the Worker script `share-f-d-foundation` (it has no domain since D3) | `GET workers/scripts/share-f-d-foundation` answers 404 | redeployable from the v0.8.0 `bin/share` |

Rollback of D3, in order, all with the admin token, rehearsed in R1 (the step-15 die with `--alias` prints exactly this list): rebind `f.d.foundation` to `share-f-d-foundation` (`PUT workers/domains`); restore the marker host `f.d.foundation` (`If-Match`); restore the `f.d.foundation/ba6377{,/*}` destinations on its app; clear `aliases` in the marker and the config; delete every `v:2` machine record (a v0.8.0 sweep refuses to run while one exists); `share --profile dfoundation setup s.d.foundation --no-r2` (the route goes; `s.d.foundation` is the plain tunnel again). The old Worker still serves every `v:1` cloud record, and it answers 404 for the `v:2` pointers it cannot pass through, which is correct on `f.d.foundation`. Hits recorded before D3 stay in dataset `share_f_d_foundation`; `share hits` after D3 reads `share_s_d_foundation` only.

### Personal (`s.han.ws`, R2 off, origin moves from the Air to the Mini)

| # | Step | Check | Rollback |
|---|---|---|---|
| P1 | upgrade share on the Air and on the Mini | `share import --probe` on the Mini prints `share-import 1` | `brew` pin |
| P2 | on the Air: `CLOUDFLARE_API_TOKEN=<token> share migrate --to tieubao@<mini> --remote-profile default` | its step 4 (every moved link answers through `https://s.han.ws/`); on the Mini `share ls` shows them with `by=<air>`; `share profiles` on the Mini lists `default · s.han.ws · serving` | `share setup s.han.ws --tunnel-name air-share --force` on the Air before step 5 (printed by `migrate`, run once in R2); after step 5 the Air's copies sit in `~/share/migrated/<id>` and its rows in `~/share/index.migrated` |
| P3 | Share Bar on the Mini | two sections, `default · s.han.ws · Serving` and `dfoundation · s.d.foundation · Serving` | |

The Mini's default profile is free today (`not_setup`), so `s.han.ws` lands there on port 8787 under the user that runs the `dfoundation` profile (`tieubao`). The new tunnel is `share-s-han-ws`; `air-share` is deleted in P2's step 5. R2 stays off; Han can enable it later with `setup --r2` on the Mini, which needs a bucket on the personal account (R2 is enabled there today, with no share bucket). After P2 the Air has no `s.han.ws` profile; it publishes personal links only after R2 is on (as a member) or by ssh to the Mini.

## Byte identity

A tunnel profile with no `bucket=` (every R2-off tenant) keeps every file, output line, and `state` key it has today, with three additions: the `ls` tag column (`machine` or `live`, the type, `by=`), and `state`'s new keys `storage`, `type`, `by`, `r2: false`. An r2 member profile keeps SPEC-007's behavior plus the same listing fields and its rows in `profiles --json`. Row 1 of the coverage matrix pins both.

## Files

- `bin/share`: `--cloud`, `--local`, `storage_default`; `setup --r2`, `--no-r2`, `--alias`; pointer records and the reconcile; the merged rows and the new fields in `ls`, `state`, `profiles --json`; `import`, `migrate`; Worker v3 in `worker_js`; usage lines and the skill rows.
- `tests/share.sh`: sections under `SHARE_R2_DRY=1` and `SHARE_MIGRATE_SSH`.
- `tests/worker.mjs`: pass-through, alias, and healthz cases with a stubbed origin `fetch`.
- `tests/e2e-tenant.sh` (new): live legs L1 to L10 and rehearsal R1. `tests/e2e-migrate.sh` (new): rehearsal R2.
- `mac/Sources/ShareBarCore/Snapshot.swift` (`Share.storage`, `.type`, `.by`; `Snapshot.r2`, `.storageDefault`, `.cloudError`), `RowGlyphs.swift` (new), `MenuModel.swift`, `Publish.swift`; `mac/Sources/ShareBar/StatusItemController.swift`; tests under `mac/Tests/ShareBarCoreTests/`.
- `README.md`, `docs/how-it-works.md`, `docs/setup.md` (tenant, origin, member, the onboarding rule), ADR-0008 (one hostname per tenant), `docs/verification/one-host-per-tenant.md`.

## Failure modes

| Failure | Detection | Behavior |
|---|---|---|
| the origin is off, R2 on | the Worker's pass-through gets 530 | cloud links serve; machine and live links answer the 503 offline page; `/healthz` answers 503 with `X-Share-Tunnel: 0` |
| the origin is off, R2 off | none at the edge | Cloudflare 530, as today |
| R2 or the bucket binding fails | the bucket read throws | the request passes through: machine links serve, cloud ids reach Caddy and answer 404, gated cloud ids are gated at the edge first; never served unchecked |
| a cloud record and a machine link share an id | `If-None-Match: *` on `m/<id>`; the reconcile | a cloud add picks another id; a pre-existing collision (an origin on v0.8.0 while R2 was on) is printed by the origin's `ls` and setup step 6; the Worker serves the cloud record |
| a pointer write fails on a local add | `r2_call` code | the add dies before `stage_publish`; nothing is served |
| a pointer outlives its link | the reconcile, prune | deleted after 10 minutes by the origin, or after expiry by any member; until then the id passes through and answers 404 |
| a request the route Worker passes through re-enters the Worker | TASK-1a(a) | the spike blocks the build: the pass-through design changes to (B) before TASK-3 |
| Access does not run before a route Worker | TASK-1a(b) | the spike blocks the build; a gated machine link must never reach the origin unauthenticated |
| a forged cloud record over a machine id (a publisher with bucket write) | none; same trust as SPEC-007 DEC-011 | the cloud bytes answer, inside the edge's Access app for that path when one exists; publishers are named teammates |
| an alias rebind leaves `f.d.foundation` without a Worker | step 14's API answer; step 15's 301 check | die naming the rollback; the old Worker stays deployed |
| the gate probe on the added destinations times out | step 10 | the added destinations are removed; nothing else has changed |
| `migrate` loses ssh mid-copy | the pipe's exit code | stop; the target holds the copies already imported, unserved unless its profile serves; a rerun skips them |
| the switch fails after the CNAME moved | the remote setup's exit | `migrate` prints the one rollback command; the Air's tunnel and copies are intact until step 5 |
| a moved link does not answer | step 4 | stop before step 5, naming each link |
| a tar entry escapes the stage, or a symlink arrives | `import`'s stage scan | the import of that id dies; nothing is published for it |
| a member removes or refreshes a machine link | the row's `storage` | refused before any call; only the origin removes it |
| a forged bucket record names a live port, a host, or a shell expression | the `v:2` reader's checks; bucket rows never reach `rows()` | skipped or shown as text; nothing reaches the Caddyfile or arithmetic |
| the origin is off and a member joins or adds a gated link | `X-Share-Worker` and `X-Share-Tunnel` on a 503 | treated as Worker up; join and add proceed |
| an alias fold dies after the marker moved | step 11 wrote the config first | the die prints the alias rollback list; `--no-r2` refuses until it ran |
| an old share CLI on the origin while R2 is on | none | it serves and adds local links without pointers; the reconcile on the next upgraded `ls` writes them and names any collision |
| the token source is a command and the menu polls | the listing token rule | local rows plus `cloud_error`; no prompt during a poll |

## Task Breakdown

- [ ] TASK-1a: edge spike on a throwaway hostname, one Worker, one tunnel, one Access app; answers in `docs/implementation-notes/one-host-per-tenant.md`. (a) A route Worker's `fetch(request)` and a `fetch` of `https://<HOST>/healthz` reach the tunnel origin without running the Worker again. (b) Access answers an unauthenticated request to a gated path with its 302 before the route Worker runs; an admitted request reaches the Worker with `Cf-Access-Jwt-Assertion`. (c) The pass-through of an admitted request reaches the origin. (d) A POST and a WebSocket upgrade pass through to a live dev server. (e) The status codes a pass-through sees with the connector down, and a header that tells Caddy's own 502 apart. AC: each answered; (a) or (b) failing blocks TASK-3 and amends `### Approaches considered`.
- [ ] TASK-1b: account spike with throwaway tokens and names. (f) Rebinding an existing custom domain to another Worker: in place, or DELETE then PUT, and the gap. (g) `PUT access/apps/<uuid>` with added destinations keeps the AUD. (h) Whether `op://Toolkit/cf-api-token` holds Workers Routes Edit and Access Apps Edit on the Dwarves account. (i) Whether it edits tunnels and DNS on the personal account. (k) The Workers plan on each account and the route's failure mode at the request limit. AC: each answered, the token table amended to the source each role uses.
- [ ] TASK-2a: per-link storage on the origin: config keys, `--cloud`, `--local`, their refusals, `rand_id` across both legs, the pointer write and its delete on `rm` and `prune`. Depends on TASK-1a. AC: rows 2, 4, 5.
- [ ] TASK-2b: storage dispatch for `rm`, `refresh`, `hits` with the member refusals, the reconcile, the sweep rule for pointers, and the origin's cloud expiry through its own reader. Depends on TASK-2a. AC: rows 3, 6, 26, 27.
- [ ] TASK-3: Worker v3 (`ALIASES`, `PASS`, two-leg `/healthz`, the record branches, the rewrap, the offline page, the method rule, `WORKER_RECORD_V` 2), `r2_healthz`'s header reading, and `tests/worker.mjs` with a stub whose responses hold immutable headers. Depends on TASK-1a. AC: rows 7 to 10, 29.
- [ ] TASK-4: `setup --r2` and `--no-r2` without `--alias` (steps 1 to 3, 5, 6, 8, 9, 11, 13, 15) and the rerun convergence. Depends on TASK-2a, TASK-3, TASK-1b(h). AC: rows 11, 12, 13, 32.
- [ ] TASK-5: `--alias` (steps 4, 7, 10, 12, 14, 16), the `--no-r2` alias refusal, the printed rollback list. Depends on TASK-4 and TASK-1b(f)(g). AC: rows 14, 30.
- [ ] TASK-6: one shared list: the separate bucket reader, merged display rows, the `v:2` reader's checks, `storage`, `type`, `by`, `r2`, `storage_default`, `cloud_error`, `cloud_more`, the listing token rule, the newest-25 fetch in `state`. Depends on TASK-2b. AC: rows 1, 15, 16, 17, 28.
- [ ] TASK-7a: `import` and `setup --token-stdin`. Depends on no other task; its first step measures the tar flags on bsdtar and GNU tar (absolute, `..`, symlink, and hardlink members) before the pre-scan is written. AC: row 18.
- [ ] TASK-7b: `migrate` (preflight, copy, switch, verify, retire, the printed rollback). Depends on TASK-7a and TASK-1b(i). AC: rows 19, 20, 21, 31.
- [ ] TASK-8: Share Bar: decode, `RowGlyphs`, row rendering, the `cloud_error` line, the `Storage` popup. Depends on TASK-6. AC: rows 22 to 25; `swift build` passes.
- [ ] TASK-9a: `tests/e2e-tenant.sh` (L1 to L10) and rehearsal R1, with its run log. Depends on TASK-2a to TASK-6. AC: L1 to L10, R1, every cleanup assertion.
- [ ] TASK-9b: `tests/e2e-migrate.sh` and rehearsal R2 (the one-machine leg, then the Air to the Mini on a throwaway name), with its run log. Depends on TASK-7b. AC: R2 and its cleanup assertions.
- [ ] TASK-10: README, how-it-works, setup (onboarding), ADR-0008, the verification record with the negative controls. Depends on TASK-9a, TASK-9b. AC: each negative control has a red and a green run; each `docs/how-it-works.md` command, flag, and state key named in this spec is found by a `tests/share.sh` grep against `bin/share`.
- [ ] TASK-11a: STOP for Han, then the Dwarves migration D1 to D5. Before D3 the lead posts the R1 log and the exact D3 command and waits for Han's explicit go; no loop may run D3 on its own. Each check is recorded in the verification record. Depends on TASK-10 and a release. AC: the Dwarves items of `## After state`. D6 runs seven days later, after a second go.
- [ ] TASK-11b: STOP for Han, then the personal move P1 to P3. Before P2 the lead posts the R2 log and the exact P2 command and waits for Han's explicit go; no loop may run P2 on its own (P2 deletes `air-share` at its step 5). Depends on TASK-10 and a release; independent of TASK-11a. AC: the personal items of `## After state`.

## Test plan

Local rows run in `tests/share.sh`: the r2 rows under `SHARE_R2_DRY=1` (SPEC-007's directory-backed bucket and call log), the migration rows with `SHARE_MIGRATE_SSH` pointing at a second `HOME` on the same machine. `tests/worker.mjs` drives the emitted Worker with an in-memory bucket and a stubbed global `fetch` that records each pass-through and answers from a fixture (200, 404, 530, a thrown error). Swift rows run in `swift test --package-path mac`.

### Coverage matrix

| # | Category | Case | Assert |
|---|---|---|---|
| 1 | compat | `origin/main`'s `bin/share` and the branch's, each under its own `HOME` with the same seams: a quick setup and a named dry setup with no `bucket=`, add file, add folder, add live, `--host`, `ls`, `state`, `profiles --json`; then an r2 member profile | every file byte-identical; stdout and stderr identical except the `ls` tag column; `state` equal after deleting the keys `storage`, `type`, `by`, `r2`; the member's `profiles --json` entry gains rows |
| 2 | storage | origin with R2 off: `add f`, `add --local f`, `add --cloud f`; R2 on with default `local`: `add f`, `add --cloud f`, `add 3000`, `add --cloud 3000`, `add --cloud --host x.<zone> f`, `add --cloud --local f`; default `cloud`: `add f`, `add --local f` | local, local, refused with the setup line; local plus pointer, cloud, live plus pointer, refused, refused, refused; cloud, local plus pointer; refusals log no PUT and write no row |
| 3 | member | an r2 member: `add f`, `add --local f`, `add 3000`; `rm` and `refresh` of a machine row; `rm` of a cloud row | cloud; refused; refused; both refused before any call (no `DELETE m/<id>` logged); the cloud rm runs SPEC-007's path |
| 4 | pointer | local add with R2 on; the bucket answers 412 for the first candidate | `GET m/<id>` and the prefix scan precede the pointer PUT; the pointer PUT carries `If-None-Match: *`, `v:2`, `storage:"machine"`, no `access=` and no `host=` in `opts`; the first candidate is skipped; the pointer PUT precedes the `pub/<id>` rename (a watcher on `pub/`); a gated add's pointer PUT precedes `POST app` |
| 5 | pointer | the pointer PUT answers 500 three times | exit 1 naming R2; no `pub/<id>`, no row, no app |
| 6 | reconcile | origin `ls` with: a machine record with no row, `LastModified` 11 min ago (one with `by` of another machine too); one 1 min ago; one 11 min ago whose id is in `access-pending`; a local row with no pointer; a local row whose id holds a cloud record; `rm` and `prune` of local rows with and without a token | both old orphan pointers deleted, the young one and the pending one kept; a pointer written for the bare row; the shadow line printed, nothing deleted; rm and prune delete the pointer with a token and leave it without one |
| 7 | Worker | `PASS` set: a cloud record; a machine record; no record; the bucket throws; a non-hex first segment; `/`; an expired cloud record; a cloud record whose prefix names another id | R2 bytes, no pass-through; pass-through x5 (machine, none, throw, non-hex, root); 404 with no pass-through x2 |
| 8 | Worker | `PASS` set, pass-through answers: 200 with a body; 404; 530; 502; a thrown fetch; a POST with a body; an `Upgrade: websocket` request | unchanged x2 (no Analytics Engine data point for any pass-through); 503 offline page with `Retry-After` x3; the POST forwarded with its method and body; the upgrade forwarded and its 101 returned unchanged |
| 9 | Worker | `ALIASES=f.test`: GET `https://f.test/ba6377/g/?a=1`, HEAD, POST, `/healthz`; Host `x.test`; `PASS` empty: a miss | 301 to `https://<HOST>/ba6377/g/?a=1`, 301, 405, 301; 404; 404 with no `fetch` call |
| 10 | Worker | `/healthz` with `PASS` set and the origin stub answering `200 ok`, then 530, then a timeout; with `PASS` empty | 200 `X-Share-Tunnel: 1`; 503 `X-Share-Tunnel: 0` x2; SPEC-007's answer with no stub call. Every row 7 to 10 answer carries `no-store` and `noindex`, and SPEC-007's rows 17 to 19 and 28 pass unchanged on the v3 source |
| 11 | setup | dry `setup --r2` on the origin | log order: script GET < bucket reads < marker GET < routes GET < `m/` list < script PUT < subdomain POST < subdomain GET < pointer PUTs < config write < route POST < healthz; config gains the four keys; the tunnel config and Keychain items unchanged |
| 12 | setup | refusals: on a non-origin; on quick mode; a publisher token (403 on the script read); a route on `<host>/*` naming another script; a local id holding a cloud record; a marker naming a third host | each dies before any PUT, POST, or DELETE in the log |
| 13 | rollback | `--no-r2` after row 11 | route DELETE logged; the four keys gone; the next `add` writes no pointer; `rows()` output equal to before row 11 |
| 14 | alias | dry `--alias f.test` with a gated cloud record (then `rm` of it on the tenant); the alias domain naming another service; the gate probe failing | order: app GET < script PUT < pointer PUTs < app PUT (destinations added, AUD unchanged) < probes < config write < marker PUT `If-Match` < route POST < domain PUT < healthz < app PUT (alias destinations dropped); the other service: dies before any write; probe failure: the added destinations removed, no marker PUT, no route; the `rm` deletes the folded app |
| 15 | list | origin with R2 on: two local rows (one live, one gated), their pointers, two cloud records (one by another machine, one gated), a `v:1` cloud record without `type` named `guide` | `ls` shows six rows with tags `machine`, `live`, `cloud`, `cloud`, their types, and `by=`; no id twice; `state` rows carry `storage`, `type`, `by`; `guide` is `folder` |
| 16 | type | the type table, one fixture per row, plus a folder with `index.html`, a folder without, `Report.PDF`, `a.tar.gz`, no extension on a local file | each `type` as the table; the extension match ignores case |
| 17 | list | `state` with the bucket listing failing; with the token source `api_token_cmd`; `profiles --json` with an r2 member and a tunnel profile | local rows plus `cloud_error` (exit 0); no command run (a sentinel command that touches a file is never run), `cloud_error` names `api-token`; the member entry lists its rows |
| 18 | import | a tar with a regular tree; a symlink; a dotfile; a `../x` member; an absolute member; an id already in the index; opts `live`; opts `host=x`; a name with `/` | the first published with the original dates, `by=`, and `src` `<by>:<src>`; each other refused with no `pub/<id>` and no row |
| 19 | migrate | two `HOME`s (A the old origin, B the target, `SHARE_MIGRATE_SSH` pointing at a wrapper that logs its own argv): A holds a snapshot, a folder, a gated snapshot, a live row | B's index holds the three snapshots with A's ids, names, expiries, and `access=`; B's `pub/<id>` trees equal A's byte for byte; the live row is listed as not moved; B's dry setup ran with `--force --token-stdin` (the token is in no argv the wrapper or a `curl` shim logged); A's rows are in `index.migrated`, its trees in `migrated/`; A's teardown path ran and logged no DELETE of an Access app |
| 20 | migrate | a `--host` row on A; `bucket=` on A; B's profile set up for another hostname; B's `not_setup` profile holding an old row; the copy failing on the second id; the remote setup failing; a gated link answering 200 at verify | refused before any copy x4; stop with the first id on B and A unchanged; A unchanged and the rollback line printed with `--tunnel-name <A's tunnel_name>`; stop before retire, the gated link named |
| 21 | migrate | rerun after row 20's copy failure | the first id skipped as already moved; the rest copied |
| 22 | swift | decode `profiles --json` fixtures with and without the new fields; a share with an unknown `type` | `storage`, `type`, `by`, `r2`, `storageDefault`, `cloudError` decoded; absent fields are nil; unknown type maps to `doc` |
| 23 | swift | `RowGlyphs` over every value in the SF Symbols table | the symbol names and words match the table; every symbol resolves with `NSImage(systemSymbolName:)` on the test host |
| 24 | swift | `MenuModel` rows: a gated cloud PDF, a live machine row, an older-CLI row with no `storage` | accessibility titles `<name>, <trailing>, PDF, in the cloud, snapshot, login required`; `..., site, on this tenant's machine, live server`; no storage word for the old row |
| 25 | swift | `PublishForm` on an origin with `r2: true` and `storage_default: cloud`; on a member; on a tunnel profile with `r2: false` | the `Storage` popup preselects `In the cloud` and the argv carries `--cloud`; a disabled `In the cloud` label and no flag; no popup and no flag |
| 26 | sweep | R2 on: bare `prune` with machine pointers present and an unreferenced upload 25 h old; then a record that is not JSON | the old upload deleted, no warning; with the broken record, nothing deleted and the warning names it |
| 27 | dispatch | on the origin: `rm` of a cloud row, `rm` of a machine row, `refresh` of each, `hits` of each | the cloud ones take the r2 path (S3 calls, the SQL call); the machine ones take the tunnel path plus the pointer DELETE; `hits` of a machine row reads the access log |
| 28 | hostile | on an R2-on origin, and again on a member (`ls`, `state`, `profiles --json` only), forged records, plus a key `m/../share.json`, an expired valid cloud record whose id sorts before an expired local row (one `prune` expires both, cloud first), `rm` and `hits` of a forged cloud id, and one local `add` in the same process: `v:1` with `opts:"live host=x.test"` and `src:"x:22"`; `v:2` machine with `opts:"live"`, `src:"x:22"`, and `expires:"a[$(touch S)]"`; `v:2` with `name` holding a tab; then `ls`, `state`, `profiles --json`, `prune`, `refresh <id>` | the Caddyfile and the running Caddy config hold exactly the local rows (the expired one gone, the new add present, no bucket row); `index.tsv` holds no bucket row; the file `S` does not exist; the odd key is skipped and `share.json` survives; each forged record is skipped or shown as display text only; `refresh` of the forged ids dies |
| 29 | healthz | dry Worker answer `503` with this CLI's pair and `X-Share-Tunnel: 0`: a member joins, adds a gated cloud link, and runs `state` | the join exits 0; the gated add publishes; `state` has `ready: true`; a `503` with no `X-Share-Worker` header still fails all three |
| 30 | alias | dry `--alias f.test`, die injected at each of steps 12, 13, 14, 15; then `--no-r2`; then the printed rollback list; then a rerun of the fold | each die prints the alias rollback list, not `--no-r2` alone; `--no-r2` refuses while `aliases=` is set; after the list, the integration Worker for the alias serves the cloud record itself; the rerun converges to row 14's end state |
| 31 | rollback | after row 20's remote-setup failure, run the printed line on A in dry mode | the dry DNS PUT names A's own tunnel; A's config keeps its `tunnel_id`; no call touches B's tunnel |
| 32 | refuse | SPEC-007 `setup <host> --backend r2 --bucket <b>` with the admin fixture against a tenant Worker (`PASS="1"`), with `--force`; against a marker holding `aliases`; against a route on `<host>/*` | each dies before any PUT, POST, or DELETE, naming `setup <host> --r2` on the origin |

### Negative controls

Each is a temporary one-line patch that must turn the named rows red, recorded with its red run in `docs/verification/one-host-per-tenant.md`.

| Patch | Expected red |
|---|---|
| the Worker passes an expired cloud record through instead of 404 | row 7 |
| the Worker passes a miss through with `PASS` empty | row 9 |
| the Worker serves R2 for a `storage:"machine"` record | row 7 |
| drop the encoded-separator check before the pass-through | SPEC-007 row 18 on the v3 source |
| write the pointer after `stage_publish` | row 4 (the watcher sees `pub/<id>` first) |
| let a pointer PUT failure warn instead of die | row 5 |
| take a member's `add --local` as cloud | row 3 |
| attach the route before the pointer backfill | row 11 |
| keep the alias destinations on the app after step 14 | row 14 |
| let `import` accept a symlink | row 18 |
| run the full teardown (with Access deletes) on the old origin before moving rows aside | row 19 |
| read the bucket in `state` through `api_token_cmd` | row 17 |
| write `bucket=` into a plain tunnel config at setup | row 1 |
| merge bucket rows through `rows()` | row 28 (the Caddyfile changes) |
| let SPEC-007's r2 setup take a tenant host with `--force` | row 32 |
| let the sweep count a machine pointer as unreadable | row 26 |
| let a member `rm` a machine row | row 3 |
| read the healthz status alone in `r2_healthz` | row 29 |
| print `--no-r2` as the step-15 rollback with an alias | row 30 |
| omit `--tunnel-name` from the printed migrate rollback | row 31 |

### Live legs (`tests/e2e-tenant.sh`, by hand before the release)

Inputs: `SHARE_E2E_TENANT_HOST` and `SHARE_E2E_ALIAS_HOST` (unused names on a zone the admin token edits), `CLOUDFLARE_API_TOKEN` (admin), `SHARE_E2E_R2_PUBLISHER_TOKEN`, `SHARE_E2E_ACCESS_EMAIL`. The bucket is `share-e2e-<6 hex>`, and the script refuses a hostname or bucket without the `share-e2e-` prefix, so `s.d.foundation`, `f.d.foundation`, `s.han.ws`, and every existing bucket are out of reach. Everything runs under mktemp `HOME`s with `SHARE_TEST_PORT_BASE` ports.

| # | Step | Assert |
|---|---|---|
| L1 | origin A: tunnel setup of the tenant host; a local file, a gated local file, a live server on a test port | all answer as today (the gated one 302 with `kid == aud`) |
| L2 | `setup --r2` on A | `/healthz` 200 with `X-Share-Tunnel: 1` and this CLI's pair; pointers exist for L1's ids; `https://<worker>.<sub>.workers.dev/healthz` does not answer 200 |
| L3 | through the Worker | L1's links answer as before; the gated one still 302s unauthenticated and serves with the service token (SPEC-007 TASK-1(l) method); the live server answers a POST and a WebSocket echo |
| L4 | A `add --cloud`; member B joins and adds | both cloud links 200 with `no-store`; `ls` on A and on B show the same five rows with tags |
| L5 | stop A's tunnel (`share stop`) | cloud links 200; machine and live links 503 offline page; `/healthz` 503 with `X-Share-Tunnel: 0`; a fresh member C joins and B adds a gated cloud link, both succeed, and B's `state` reads `ready: true`; start A, all back |
| L6 | encoded paths `/x/..%2F<id>/f`, `//<id>/f`, `/%2F<id>/f` on a machine id and a cloud id | 400 each, from the Worker |
| L7 | `--no-r2` | the route is gone; machine links serve straight from the tunnel; cloud links 404 at Caddy |
| L8 | `setup --r2` again | back to L4's state with no new pointer PUT for existing pointers |
| L9 | B's local teardown; A `rm` of each link | A's `ls` empty; every pointer and record gone; the gated apps 404 |
| L10 | admin purge and A teardown | cleanup below |

Rehearsals (each before its production run):

| # | Rehearsal | Assert |
|---|---|---|
| R1 | the Dwarves fold on throwaway names: A is a tunnel origin on `<tenant>`, C an r2 profile on `<alias>` with a gated cloud share; then `setup --r2 --alias <alias>` on A; then the rollback list in `### Dwarves`; then the fold again | after the fold: `https://<alias>/<id>/<name>/` 301 to `https://<tenant>/<id>/<name>/`, which 302s with `kid` equal to the original AUD and serves with the service token; after the rollback: the alias serves the share itself and the tenant is a plain tunnel; after the second fold: as after the first |
| R2 | the personal move on throwaway names: A (stand-in for the Air) sets up `<tenant>` with a snapshot, a folder, a gated snapshot, a live server; `migrate --to` B on the same machine (`SHARE_MIGRATE_SSH`), then once more from the real Air to the Mini over ssh (a second throwaway name) | every snapshot link answers from B (or the Mini) at the same URL; the gated one keeps its 302 and AUD; the live link is reported as not moved; A's tunnel is deleted, its DNS record points at B's tunnel; the measured 530 gap is logged. Before that, one run injects a remote-setup failure and runs the printed rollback: the hostname serves from A's tunnel again |

Cleanup is asserted, then enforced, as SPEC-007's live leg does: after L10 and each rehearsal the script checks that no route, Worker, custom domain, DNS record, tunnel, bucket, Access app, or minted token with the throwaway names remains, and its EXIT trap runs the purges and a by-name fallback whatever happened before, printing each leftover.

## Grounding

Read-only probes, 2026-10-01, from the Mini, through a helper that sends the Toolkit token as `-H @<(printf ...)` and prints names, codes, and counts only:

| Claim | Command (shape) | Excerpt |
|---|---|---|
| profiles on the Mini | `share profiles`; `share --profile <p> state \| jq` | `default not_setup -`, `dfoundation serving s.d.foundation`, `files serving f.d.foundation`; one gated snapshot `a68960` on `dfoundation`, one gated cloud share `ba6377` on `files` |
| config keys | `grep '^(backend\|hostname\|hosts\|port\|bucket\|tunnel_name)='` | `files`: `backend=r2`, `bucket=share-dfoundation`, `port=r2`; `dfoundation`: `tunnel_name=share-s-d-foundation`, `hosts=Mac-mini`, `port=8791` |
| hostnames live | `curl -w %{http_code} https://<h>/healthz` | `s.d.foundation 200`, `f.d.foundation 200`, `s.han.ws 200` |
| the guide link | `curl -w '%{http_code} %{redirect_url}'` | `302 https://dwarves.cloudflareaccess.com/cdn-cgi/access/login/f.d.foundation?kid=<64 hex>...` |
| DNS | `GET zones/<z>/dns_records?name=<h>` | `s.d.foundation CNAME proxied tunnel`, `f.d.foundation AAAA proxied` (the Worker custom domain), `s.han.ws CNAME proxied tunnel` |
| Workers on the zones | `GET zones/<z>/workers/routes`, `GET accounts/<a>/workers/domains` | `chat.d.foundation/dw-chat/* -> df-chat-ui`, `radar.han.ws/* -> price-radar`; `f.d.foundation -> share-f-d-foundation` |
| tunnels | `GET accounts/<a>/cfd_tunnel?is_deleted=false` | `share-s-d-foundation healthy, 4 connections`; `air-share healthy, 4 connections` |
| Access apps | `GET accounts/<a>/access/apps` filtered on `share ` | Dwarves: `f.d.foundation/ba6377{,/*}`, `s.d.foundation/a68960{,/*}`; personal: none |
| personal account | `GET accounts/<a>/r2/buckets`, `POST .../analytics_engine/sql` | `200`, no bucket named `share*`; `200` |
| zone plans | `GET zones?name=<z>` | both `Free Website`; Workers paid status not probed (SPEC-007 cost section assumed the Dwarves paid plan) |

Not sampled (TASK-1a, TASK-1b, TASK-7a): the route pass-through, Access order against a route Worker, the subrequest under Access, WebSocket pass-through, the down-origin status codes, the custom-domain rebind, the AUD after a destination edit, the Toolkit token's route, Access, and tunnel scopes, tar member handling.

Dry trace for one negative control: "write the pointer after `stage_publish`" moves the `r2_call PUT m/<id>` line below the `mv` in the local add; row 4's background watcher records the first time `pub/<id>` exists and compares it with the line number of `PUT m/<id>` in `r2-calls.log` (the watcher appends a `SEEN pub/<id>` line to the same log), so the order flips and the row fails mechanically.

## Verification

```sh
shellcheck bin/share install.sh tests/share.sh tests/e2e.sh tests/e2e-r2.sh tests/e2e-tenant.sh tests/e2e-migrate.sh demo/render.sh mac/*.sh
/bin/bash -n bin/share
bash tests/share.sh          # includes tests/worker.mjs
swift test --package-path mac
bash mac/build.sh 0.0.0
```

Then by hand: `tests/e2e-tenant.sh` (L1 to L10, R1) and `tests/e2e-migrate.sh` (R2); logs go to `docs/verification/one-host-per-tenant.md`.

## After state

- [ ] `https://f.d.foundation/ba6377/support-ticket-guide/` answers 301 to the same path on `s.d.foundation`, which keeps its Access gate.
- [ ] `share --profile dfoundation ls` on the Mini lists `a68960` (`machine`) and `ba6377` (`cloud`) in one list; the `files` profile is gone.
- [ ] `share --profile dfoundation add ./x` publishes from the Mini's disk; `add --cloud ./x` publishes to the bucket; both at `https://s.d.foundation/<id>/...`.
- [ ] With the Mini's `dfoundation` service stopped, the cloud link answers and the machine link answers the 503 offline page.
- [ ] `s.han.ws` serves from the Mini; every Air snapshot link answers at its old URL; no Worker or bucket exists for `han.ws` share.
- [ ] Share Bar on the Mini shows two sections, each row with its type icon, storage badge, and link-type marker, and the lock on gated rows.

## Acceptance Criteria (global)

1. A tenant with R2 off runs today's code paths: no Worker, no bucket call, files byte-identical (row 1).
2. With R2 on, a cloud record is never passed to the tunnel, a machine link is never served from R2, and an expired or malformed cloud record answers 404 (rows 7, 8).
3. A gated link stays gated on both legs: the edge app on every path, plus the Worker's JWT check for cloud records (rows 10, 14; L3; R1).
4. Every existing link keeps its URL or answers a 301 to it, through both migrations (R1, R2; `## After state`).
5. No token appears in argv, output, a file, a binding, or an object (rows 19, SPEC-007 row 16 on the new paths).
6. Every migration step has a rollback that the rehearsal ran.

## Out of scope

Moving a tunnel tenant's local shares into its bucket (a `--cloud` re-add covers one link); a member publishing a local link through the origin over ssh; more than one origin per tenant; `--host` and live links in R2; enabling R2 on `s.han.ws` now; a CSP sandbox on shared HTML (SPEC-007 Decisions item 6); per-link storage changes after publish.

## Decisions for Han

1. Personal SSH target and user for P2: the spec assumes `tieubao@<mini>` (the user that runs `dfoundation` today), so both tenants live under one account on the Mini. Proposed: accept.
2. The Mini's `s.han.ws` lands in its `default` profile (port 8787, Keychain item `share-tunnel:s.han.ws`). Proposed: accept; a named `personal` profile works the same if you prefer explicit names on the Mini.

## Decision Log

- DEC-001 (operator, 2026-10-01): one hostname and one shared list per tenant; storage is a per-link indicator, never a subdomain.
- DEC-002 (operator, 2026-10-01): local storage is the default; R2 is optional per tenant, off until the admin enables it, then per link (`--cloud`, `--local`) with an admin-set tenant default (`storage_default`).
- DEC-003 (operator): the Mini is the single origin for both tenants, because it is the only always-on machine; the Air's sleep is the cause of today's 530s on `s.han.ws`.
- DEC-004: the Worker reaches the tunnel by route pass-through on the same hostname; no internal hostname, no service token, and the rollback is one route delete.
- DEC-005: R2 first, then the tunnel; a cloud id never falls back to the origin.
- DEC-006: pointer records exist only with R2 on; they make the list shared on every member and the namespace collision-proof. A local add fails closed when R2 is on and the pointer cannot be written. The cost, stated plainly: on an R2-on tenant, local publishing depends on R2 answering and on a stored publisher token (Share Bar and the CLI alike); the gain over failing open is that no member's cloud add can take an id the origin holds, a 1 in 16.7 million chance per add, plus a list that is never missing a machine link. Accepted because the tenant admin turned R2 on deliberately; an R2-off tenant keeps today's independence.
- DEC-007: cloud records stay `v:1` (plus an optional `type`), pointers are `v:2`, so the old Worker remains a valid rollback for every cloud link.
- DEC-008: `f.d.foundation` becomes an alias the tenant Worker answers with 301; the bucket `share-dfoundation` is adopted in place, so `ba6377` keeps its record, bytes, and Access app AUD.
- DEC-009: `share migrate` moves an origin over ssh with the receiver's `import`, keeping ids, names, dates, expiries, and gates; nothing on the old origin is deleted, only moved aside.
- DEC-010: the new origin gets its own tunnel; reusing the old one would leave its id in the old machine's config, where a later teardown deletes the new origin's tunnel.
- DEC-011: bucket rows are display data only; the origin's index, Caddyfile, and stage paths never read a record another publisher could write.
- Round 1 (seven fresh-context reviewers, 2026-10-01): eleven criticals, all folded. Warnings that do not change the design went to `docs/implementation-notes/one-host-per-tenant.md` for the builder.

| Change | Why (reviewer) |
|---|---|
| Bucket rows never enter `rows()`, the index, the Caddyfile, `refresh`, or a stage; the `v:2` reader checks every field before shell arithmetic; pointers carry `gated`, not the rule; row 28 | a forged record could add a reverse proxy to a local port or run a command through `expires` (1) |
| `setup --r2` writes its config before the marker; `--no-r2` refuses while an alias is set; the step-15 die prints the alias rollback list; reruns converge; row 30 | a die after the rebind plus the printed `--no-r2` would leave the guide link 404 for good (2) |
| A member's `rm` and `refresh` of a machine row refuse; `rm`, `refresh`, `hits` dispatch on storage; rows 3, 27 | a member saw "unpublished" while the origin kept serving the file (2) |
| The migrate rollback names `--tunnel-name <old tunnel>`; row 31; R2 runs it | `setup` derives the new origin's tunnel name, so the printed line joined the old origin to the new tunnel (3) |
| `/healthz` 503 with a valid Worker pair counts as Worker up for joins, gated member adds, and r2 `state`; row 29; L5 | members could not join or publish while the origin was off, the case R2 exists for (3) |
| TASK-1 split into an edge spike and an account spike, the tar check moved into TASK-7a; TASK-7, TASK-9, TASK-11 split; TASK-11a and TASK-11b start with an explicit stop for Han | task size, and no human gate before the production migrations (4) |
| The orphan sweep reads a `v:2` machine pointer as readable and referencing nothing; row 26 | every pointer counted as unreadable, so the sweep would never run again on any machine (5) |
| Also fixed because the text was false or unsafe: `profiles --json` already lists r2 rows; the poll cost (newest 25 records, about $0.60 a month); reconcile keyed on `storage` and aged by `LastModified`; `migrate` refuses an R2-on tenant, runs a fixed `/bin/bash -c`, takes the token through `setup --token-stdin`, pre-scans the tar, validates `added`, `expires`, `src`, preflights the target, and verifies through a target-only nonce and the gated AUD; the real 530 bound; D2 after D3, D5 with D3, D4's rollback only after D3's; the Worker record branches, its 2 s read cap, and the response rewrap | reviewer warnings with a concrete wrong statement or unsafe default behind each (1, 2, 3, 5) |
| Not taken: reusing `air-share` (DEC-010); failing open on a pointer write (DEC-006); a redirect rule in place of `--alias` (the 301 stays in tested code; the alias surface is permanent but small, and it retires with `--no-r2` after the alias rollback) | (5) |
- Round 2 (five fresh-context reviewers re-ran the lenses that raised round-1 criticals, 2026-10-01): every round-1 critical cleared; two new criticals, both folded.

| Change | Why (reviewer) |
|---|---|
| SPEC-007's r2 setup refuses a tenant host in its admin role, even with `--force`; row 32 | an admin token on a member would redeploy the Worker without `PASS` and swap the tunnel CNAME for a custom domain, and the new healthz reading would call that ready (3) |
| TASK-2 split into TASK-2a (storage and pointers) and TASK-2b (dispatch, reconcile, sweep, origin cloud expiry) | seven AC rows in one task (4) |
| Also folded: a bucket reader on the origin that never rebinds `index`; the 6-hex key check; row 28 with a same-process add and a member leg; `by` through `r2_by`; the origin prunes cloud rows; `api-token` and bucket calls keyed on `bucket=`; Analytics Read for the origin; the newest 25 skip local ids and report `cloud_more`; folded apps deletable by alias name; a base64 ssh script and a seam that parses like a login shell; no hit counted on a pass-through; the TASK-11b loop stop | warnings with a concrete wrong outcome behind each (1, 2, 3, 4, 5) |
- Round 3 (three fresh-context reviewers on the round-2 diff, the cap, 2026-10-01): every round-2 critical cleared. One new critical, folded without a fourth review because of the cap: the SPEC-007 cloud verbs on a tunnel profile (`cmd_rm_r2`, `r2_prune`) still rebound or overwrote `$index`, so a `prune` that expired a cloud row before a local row could render a forged `v:1` record into the Caddyfile. The reader rule now covers every cloud verb on a tunnel profile, and row 28 gains the cloud-then-local expiry, `rm`, and `hits` legs. Remaining warnings, binding on the build:

| Warning (reviewer) | Build rule | Task |
|---|---|---|
| A v0.8.0 CLI with the admin token passes the `v:1` tenant marker and its version die suggests `--force` (3) | D1 checks that every machine holding the Dwarves admin token runs the release; the tenant marker gains a field v0.8.0's setup refuses only if TASK-4 finds one that does not break v0.8.0 joins | TASK-4, TASK-11a |
| `access_sweep` decides stale lines by `$backend`, so on the origin a crashed gated `--cloud` add's line is checked against the local index and the sweep deletes the app of a published gated cloud link (3) | the sweep decides per id: a line whose id holds a cloud record (fresh `GET m/<id>`) takes SPEC-007's r2 rule | TASK-2b |
| Members have no `aliases=`, so a member's `rm` or expiry of a folded gated share cannot delete its app (1, 3) | a member stores `aliases=` at join, read once from the marker and confirmed against the Worker's `ALIASES` binding through the alias's 301; never read live from the marker (any publisher can write it); row 14 gains a member leg | TASK-5 |
| The SPEC-007 refusal's route read may answer 403 for SPEC-007's minimal admin scopes (1) | a non-200 on the Worker settings read or the marker read dies; a 403 on the routes read alone is tolerated because the `PASS` binding check already catches a tenant; row 32 gains that leg | TASK-4 |
| The ssh template: GNU `base64` wraps lines, `"$(...)"` needs fish 3.4 or later, the "no quote" wording contradicts the template, and a runner without fish exercises sh only (1, 3) | encode with `| tr -d '\n'`; the preflight names the minimum fish; the fixed template is the only quoting and arguments add none; CI installs fish for the seam | TASK-7b |
| `api-token` keyed on `bucket=` takes the r2 form and reports Access scopes as optional (3) | on a profile with a tunnel, the Access scopes stay required as SPEC-004 has them, and the form names both the bucket and Access permissions | TASK-2a |
| `cloud_more` and the newest 25 count orphan pointers and unreadable records (3) | display only; the count says "about" in the menu line | TASK-6, TASK-8 |
| TASK-1a and TASK-1b run long as lettered probes; TASK-4, TASK-8, TASK-10 sit at the five-file or five-row edge (4) | accepted: each letter is one probe; split TASK-8's tests if they exceed one file per source | all |
