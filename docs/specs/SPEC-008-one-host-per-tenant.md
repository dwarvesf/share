# SPEC-008: one hostname per tenant, cloud storage optional per link

Status: DRAFT
Lane: full (an API and data contract between the CLI, the Worker, and Share Bar; a new public route in front of live links; a migration of two production hostnames)
Depth: research (outside: a route Worker passing requests through to a tunnel on its own hostname, Access order against a route Worker, custom-domain rebind, Access destination edits; TASK-1 samples each before the task that consumes it) | blind-spot (failure: the Worker passes a request to the tunnel that a cloud record or a gate should have stopped, or the migration leaves a link dead)
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
| How the Worker reaches the tunnel | (A) a route `<host>/*` over the existing proxied CNAME, `fetch(request)` passes through to the origin; (B) a second, internal origin hostname behind an Access service token, the Worker fetching it with the token's secret; (C) the Worker as custom domain and the tunnel on another name | (A). The tunnel and its CNAME stay exactly as they are, so deleting the route is the whole rollback. No new hostname, DNS record, Access app, or service-token secret exists (the Worker keeps holding no credential, SPEC-007's rule). (B) costs a hostname, a secret with an expiry, and a second ingress rule, and its token would open every machine link to anyone holding it. (C) would change every existing link. TASK-1(a) proves the pass-through. |
| Order inside the Worker | the tunnel first, R2 on 404; R2 first, the tunnel otherwise | R2 first (operator direction): one bucket read decides, the origin is never asked about a cloud link, and cloud links answer while the origin is off. |
| The shared list across machines | merge only on the origin (its index plus the bucket); a pointer record `m/<id>` for every machine link | pointer records, written only when R2 is on. A member's `ls` and Share Bar see the origin's links too, and one namespace means a cloud add can never take an id the origin holds (`If-None-Match: *` on one key). With R2 off there is one publisher, so its index is the list. |
| The old hostname `f.d.foundation` | keep both; a Cloudflare redirect rule plus a placeholder DNS record; the tenant Worker answers 301 for an alias host | the tenant Worker takes the alias's custom domain and answers 301 to the same path on the tenant host. One Worker per tenant; the redirect lives in code the suite tests and the CLI deploys. |
| Moving the Air's shares to the Mini | publish through R2 and back; rsync plus a hand-edited index; `share migrate --to <ssh>`, the receiver's own `share import` writing each share | `migrate` over ssh: the Air can reach the Mini, R2 is off on `s.han.ws`, and the receiving CLI validates and writes its own index (the only writer, as ADR-0003 keeps the app out of share's files). Ids and paths stay, so every link stays. |

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
| 10 | with `--alias`: each step-7 app gains `<host>/<id>` and `<host>/<id>/*` (PUT keeps every field and the AUD; TASK-1(g)); the gate probe on the new destinations passes three rounds (SPEC-004) | gate timeout: the added destinations are removed, die |
| 11 | marker `PUT share.json` with `If-Match`: `{"v":1,"host":"<host>","aliases":["<alias>"]}` | 412 |
| 12 | `POST zones/<z>/workers/routes {pattern:"<host>/*", script:<worker>}` | an API error |
| 13 | with `--alias`: `PUT workers/domains {hostname:<alias>, service:<worker>}` (TASK-1(f): rebind in place, or DELETE then PUT with the gap measured) | an API error |
| 14 | live checks: `/healthz` three times in a row with this CLI's `X-Share-Worker` pair and `X-Share-Tunnel: 1`; a probe file through the tunnel leg; with `--alias`: `https://<alias>/healthz` answers 301 to `https://<host>/healthz` | timeout: die naming the leg; the route stays (the tunnel leg serves through it), and `--no-r2` is the named rollback |
| 15 | with `--alias`: each step-7 app drops its `<alias>` destinations; the local profile whose `hostname` is `<alias>` hands its `r2-own` lines to this profile | |
| 16 | write `bucket=`, `r2_endpoint=`, `storage_default=` (default `local`), `aliases=` into the config | |

Worker bindings on a tenant: SPEC-007's set plus `PASS="1"` (pass misses to the origin) and `ALIASES` (comma list). An r2-only profile (SPEC-007, custom domain) keeps `PASS=""` and today's answers.

`share [--profile <p>] setup <host> --no-r2` (admin token, on the origin) is the rollback: delete the route, then drop the four config keys. The tunnel serves the hostname alone again. Pointer records, cloud records, the bucket, and the Worker stay; `teardown --yes --purge` on a member, or the purge path on the origin, removes them as SPEC-007 says.

### Per-link storage on the origin

| `add` form | R2 off | R2 on, `storage_default=local` | R2 on, `storage_default=cloud` |
|---|---|---|---|
| `add <file\|dir>` | local | local | cloud |
| `add --cloud <file\|dir>` | refused: `R2 is off for <host>; the tenant admin enables it with '<me> setup <host> --r2 --bucket <name>'` | cloud | cloud |
| `add --local <file\|dir>` | local | local | local |
| `add <port>`, `--host` | local (live, own host) | local | local |
| `--cloud` with a port or `--host` | refused: `live links and --host stay on the origin's tunnel` | refused | refused |
| `--cloud` with `--local` | refused (usage) | refused | refused |

A cloud add on the origin runs SPEC-007's `cmd_add_r2` path unchanged. A member runs it for every add; `--local` and `<port>` on a member die with `<host> serves local links from <origin by>; this machine publishes cloud links only`, where `<origin by>` is the `by` of the newest machine record, else `the origin`.

With R2 on, a local add on the origin also writes the id's pointer record:

1. `rand_id` checks the local index, `pub/`, and `access-pending` as today, then the bucket as SPEC-007's r2 branch does (`GET m/<id>`, the `o/<id>.` prefix scan).
2. After the stage is built and before `stage_publish` (and, for a gated add, before the Access app): `PUT m/<id>` with `If-None-Match: *` and `{"v":2,"id","storage":"machine","name","by","added","expires","opts","type"}`. `opts` keeps `noindex`, `live`, and `access_rule=<rule>`; it never carries `access=<uuid>` or `host=`. A 412 picks a fresh id; any other failure dies before anything is served, naming R2 (a tenant with R2 on keeps one namespace, so a local add fails closed).
3. `rm` and `prune` of a local row delete its pointer after the local removal. Without a resolvable token (the login service's hourly prune runs with `SHARE_API_TOKEN_OFF=1`) the pointer stays; it is harmless (the Worker passes the id to the tunnel, which answers 404), and the next interactive `ls` or `prune` on the origin, or any member's `prune` once `expires` is past, deletes it.
4. Reconcile on the origin's interactive `ls` and `prune`: a machine record whose `by` is this machine, with no local row, older than 10 minutes, is deleted (an add that died after step 2); a local row with no pointer gets one (`If-None-Match: *`; a 412 means a cloud record holds the id: printed as `<id> is shadowed by a cloud link; rm one of them`, never auto-deleted).

Record versions: cloud records stay `v:1` and gain an optional `type` field that `v:1` readers ignore, so a v0.8.0 CLI and Worker keep reading every cloud record. Machine records are `v:2` (`WORKER_RECORD_V` becomes 2): a v0.8.0 CLI drops them from `ls` and its orphan sweep skips with a warning, and a v0.8.0 Worker answers 404 for them, which is correct for a Worker that cannot pass through.

### The Worker (WORKER_VERSION 3)

Checks run in this order. Rows marked "as SPEC-007" are unchanged.

| # | Request | Answer |
|---|---|---|
| 1 | Host is in `ALIASES` | GET or HEAD: 301 to `https://<HOST><raw path and query>`; other methods: 405 |
| 2 | Host is not exactly `HOST` | 404 |
| 3 | raw path holds `%2F`, `%5C`, `%2E`, a low escape, or `//` | 400 (as SPEC-007; now also in front of the tunnel leg) |
| 4 | `/healthz`, `PASS` empty | as SPEC-007 |
| 5 | `/healthz`, `PASS` set | the Worker fetches `https://<HOST>/healthz` (the route is skipped, TASK-1(a)) with a 3 s timeout. A `200 ok` sets `X-Share-Tunnel: 1` and answers `200 ok`; anything else sets `X-Share-Tunnel: 0` and answers `503 tunnel down`. Both carry `X-Share-Worker` and `X-Share-Gate` |
| 6 | first segment is not 6 lowercase hex | `PASS` set: pass through (step 9); else 404 |
| 7 | `GET m/<id>` returns a record with no `storage` or `storage == "cloud"` | SPEC-007 rows: version, id, prefix, and expiry checks (404 on any), the JWT for a gated record (404), then GET or HEAD served from R2 (other methods 405), hits counted |
| 8 | a `v:2` record whose `storage` is `machine`; no record; or the bucket read throws | `PASS` set: pass through; else 404 |
| 9 | pass through | `fetch(request)`, any method, the body streamed, the original headers (the Access JWT and cookie included). The origin's answer goes back unchanged (a WebSocket upgrade included, TASK-1(d)), except a 502, 503 that is not the origin's own, 520 to 527, or 530 (TASK-1(e) pins the set): `503`, `Retry-After: 60`, `Cache-Control: no-store`, `X-Robots-Tag: noindex, nofollow`, body `the machine serving this link is offline; try again later`. No hit is counted |

A pass-through never serves R2 bytes, and a cloud record never reaches the tunnel. A gated machine link keeps its gate at the edge: Access runs before a route Worker (TASK-1(b)) and the Worker forwards the visitor's credentials (TASK-1(c)). An expired or malformed cloud record answers 404 and is never passed through, so a stale cloud id cannot fall back to a same-id file on the origin. Caddy keeps its own `@encsep` rule, so the origin refuses encoded separators even with the route deleted.

Every s.d.foundation request now runs the Worker and one bucket read (two for a cloud hit). Dwarves is on the Workers paid plan; live dev-server links (many small requests) cost Worker requests in the included 10 million.

### One shared list

`ls`, `state`, and `profiles --json` read one row set per profile:

| Profile | Rows |
|---|---|
| origin, R2 off | the local index, as today |
| origin, R2 on | the local index, plus every bucket record that is not a machine record whose id is in the local index (the local row wins) |
| member | every bucket record |

Each row carries:

| Field | Values | Source |
|---|---|---|
| `storage` | `machine` or `cloud` | the row's origin |
| `kind` | `snapshot` or `live` (the link type, unchanged) | the index opts, the record `opts` |
| `type` | `pdf`, `image`, `video`, `audio`, `folder`, `site`, `markdown`, `archive`, `text`, `other` | the table below |
| `by` | the machine that published it: the origin's own `this_host` for local rows, the import's `by=` for migrated rows, the record's `by` for bucket rows | |
| `access` | the rule or `null` (unchanged) | |

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

Token rule for listings: `state` and `profiles --json` read the bucket only with a token from the Keychain item or the 600 file. A profile whose token source is `api_token_cmd` (it may prompt) or the environment gets `cloud_error: "the menu reads cloud links only with a stored token: <me> api-token"`. `ls` uses the full resolution, as SPEC-007. `cmd_profiles` stops setting `SHARE_STATE_BRIEF` for r2 profiles, so member sections list rows too (one `m/` listing plus one parallel record read per profile per refresh; at Class A and Class B list prices and a 60 s poll, under $1 a month at 500 records).

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

`share [--profile <p>] migrate --to <ssh-target> [--remote-profile <rp>] [--remote-bin <path>] [--yes]`, run on the current origin while it is online. It needs `CLOUDFLARE_API_TOKEN` (Tunnel Edit, DNS Edit, Zone Read on the tenant's zone) and an ssh login on the target as the user who will run share there.

```
 Air (old origin)                                     Mini (new origin), over ssh
 1 preflight: named tunnel profile, this host in      remote: <bin> import --probe -> "share-import 1";
   hosts, no --host row, token resolves               <bin> --profile <rp> state: not_setup, or set up
                                                      for the same hostname
 2 per snapshot row:                                  <bin> --profile <rp> import <id> <expires> <by>
   tar -C pub/<id> -cf - . | ssh ------------------->   <added> <b64 name> <b64 src> <b64 opts>
                                                        (stdin: the tar; validates, stages, publishes)
 3 the switch: the token on ssh stdin --------------> CLOUDFLARE_API_TOKEN from stdin;
                                                      <bin> --profile <rp> setup <host> --force
                                                      (new tunnel share-<host>, CNAME repointed,
                                                       service, live check)
 4 verify each moved link through https://<host>/ (200, or the Access 302 for a gated one)
 5 retire: moved rows -> index.migrated, pub/<id> -> migrated/<id> (nothing deleted),
   then the teardown path: service, tunnel air-share deleted, DNS left alone (it no longer
   points at this tunnel), tokens forgotten
```

- `import` is a new verb (one usage line: `share import ...   used by migrate over ssh`). It refuses: an id that is not 6 lowercase hex, or that exists in the local index, `pub/`, or `access-pending`; a name that is empty, starts with `.`, holds `/` or a control byte; opts other than `noindex`, `access=<uuid>`, `access_rule=<rule>` (a live or `host=` row never arrives); a `by` outside the hostname character set. It extracts the tar into a fresh stage with `tar -xf - -C <stage>` and refuses the whole import when the stage holds anything other than regular files and directories, a dotfile, or a path that left the stage (TASK-1(j) pins the tar flags on bsdtar and GNU tar). It then publishes as `stage_publish` does and appends the row with the original added date and expiry, `by=<by>` added to opts, and `src` set to `<by>:<original src>`. It reloads caddy when the profile is serving and works on a `not_setup` profile (pub and index need no setup). It never creates an Access app; the gated row keeps its `access=<uuid>`, because the app's destinations (`<host>/<id>`) do not change with the machine.
- `refresh` of a row whose `src` starts with `<host>:` for another host dies with `<id> was moved from <host>; re-add it from a source on this machine`.
- Live rows and their ports are listed as `not moved: live link <id> (port <n>); after the move run '<me> add <n>' on the new origin`. `migrate` refuses while a `--host` row exists (`<fqdn> has its own hostname on this tunnel; remove it first: <me> rm <id>`).
- Stop points: a failure in steps 1 and 2 changes nothing on this machine and leaves imported copies on the target, unserved unless its profile serves; a rerun skips ids the target already holds with the same name and added date. A failure in step 3 leaves this machine serving; the DNS record may already point at the new tunnel, and `migrate` then prints the rollback, `<me> setup <host> --force` on this machine (it reuses `air-share` and repoints the CNAME). A failure in step 4 stops before step 5 and names each link that did not answer.
- `--yes` skips the one confirmation (`Move <n> links of <host> to <ssh-target> and retire this machine as its origin? [y/N]`).
- Test seam: `SHARE_MIGRATE_SSH` replaces `ssh -o BatchMode=yes <ssh-target>` with a local command (for example `env HOME=<dir>`), so the suite and the rehearsal run both sides on one machine.

What visitors see: before the run, the Air serves (530 whenever it sleeps, as today). During step 3, between the CNAME change and the Mini's connector coming up, a few seconds of 530 (TASK-1(i) measures it in the rehearsal). After it, the Mini serves every moved link at the same URL. Live links from the Air end at step 5.

### Tokens

SPEC-007's model holds: an admin token from the environment for setup work, never stored; one bucket-scoped publisher token per machine, stored with `share api-token`, with an `expires_on`.

| Role | Scopes | Source |
|---|---|---|
| admin, `setup --r2`, `--no-r2` | SPEC-007's minimal admin set (Workers Scripts Edit on the account, DNS Read and Zone Read on the zone, Workers R2 Storage Edit), plus Workers Routes Edit on the zone (the route), plus Access Apps and Policies Edit and Access Organizations Read (the alias fold's destination edits and the `TEAM` binding) | `op://Toolkit/cf-api-token/credential` when TASK-1(h) shows it holds every scope on the tenant's account; else a run-scoped token minted through `op://Toolkit/cf-tokens-admin` (`POST /user/tokens`, `expires_on` one day) |
| `migrate` switch | Cloudflare Tunnel Edit, DNS Edit, Zone Read on the tenant's zone | `op://Toolkit/cf-api-token/credential` when TASK-1(i) shows it edits tunnels and DNS on the personal account; else a run-scoped token as above |
| origin publisher (Mini, `dfoundation`) | Workers R2 Storage Bucket Item Write on `share-dfoundation` only, plus SPEC-004's Access scopes (gated adds), plus Zone Read | minted once through `cf-tokens-admin`, `expires_on` set, stored with `share --profile dfoundation api-token`; `r2_publisher_check` still refuses an admin or account-wide R2 token |
| member publisher | as SPEC-007 | as SPEC-007 (DEC-007 there: one per teammate) |

No token reaches argv, a file, a Worker binding, or an object. `migrate` sends the switch token over ssh stdin, read on the target by `IFS= read -r` into the environment of the one `setup` process.

## Migration

Both runs follow a rehearsal on throwaway hostnames (`## Test plan`, R1 and R2). Each step names its rollback.

### Dwarves (`s.d.foundation`, R2 on, `files` folded in)

| # | Step | Check | Rollback |
|---|---|---|---|
| D1 | upgrade share on the Mini to the release | `share --profile dfoundation status` unchanged | `brew` pin of the previous version |
| D2 | mint the origin publisher token (table above); `share --profile dfoundation api-token` stores it | `api-token --check` passes the bucket and Access lines | revoke the token |
| D3 | `CLOUDFLARE_API_TOKEN=<admin> share --profile dfoundation setup s.d.foundation --r2 --bucket share-dfoundation --alias f.d.foundation` (storage default `local`) | the setup's live checks; `https://f.d.foundation/ba6377/support-ticket-guide/` answers 301 to `https://s.d.foundation/ba6377/support-ticket-guide/`, which answers 302 to the Access login with `kid` equal to the app's AUD; `a68960` still gated; `share --profile dfoundation ls` shows both rows, `ba6377` as `cloud`, `a68960` as `machine` | below |
| D4 | `share --profile files teardown --yes` (r2 teardown is local: config, token, `r2-own` go; the bucket and every share stay) | `share profiles` lists `default` and `dfoundation`; Share Bar shows one Dwarves section | `share --profile files setup f.d.foundation --backend r2 --bucket share-dfoundation` (join) |
| D5 | move any external monitor of `f.d.foundation/healthz` to `s.d.foundation/healthz` | vps-mon shows the check green | revert the catalog line |
| D6 | after seven days with no rollback: delete the Worker script `share-f-d-foundation` (it has no domain since D3) | `GET workers/scripts/share-f-d-foundation` answers 404 | redeployable from the v0.8.0 `bin/share` |

Rollback of D3, in order, all with the admin token, rehearsed in R1: rebind `f.d.foundation` to `share-f-d-foundation` (`PUT workers/domains`); restore the marker host `f.d.foundation` (`If-Match`); restore the `f.d.foundation/ba6377{,/*}` destinations on its app; `share --profile dfoundation setup s.d.foundation --no-r2` (the route goes; `s.d.foundation` is the plain tunnel again). The old Worker still serves every `v:1` cloud record, and it answers 404 for the `v:2` pointers it cannot pass through, which is correct on `f.d.foundation`. Hits recorded before D3 stay in dataset `share_f_d_foundation`; `share hits` after D3 reads `share_s_d_foundation` only.

### Personal (`s.han.ws`, R2 off, origin moves from the Air to the Mini)

| # | Step | Check | Rollback |
|---|---|---|---|
| P1 | upgrade share on the Air and on the Mini | `share import --probe` on the Mini prints `share-import 1` | `brew` pin |
| P2 | on the Air: `CLOUDFLARE_API_TOKEN=<token> share migrate --to tieubao@<mini> --remote-profile default` | its step 4 (every moved link answers through `https://s.han.ws/`); on the Mini `share ls` shows them with `by=<air>`; `share profiles` on the Mini lists `default · s.han.ws · serving` | `share setup s.han.ws --force` on the Air before step 5 (printed by `migrate`); after step 5 the Air's copies sit in `~/share/migrated/<id>` and its rows in `~/share/index.migrated` |
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
| a request the route Worker passes through re-enters the Worker | TASK-1(a) | the spike blocks the build: the pass-through design changes to (B) before TASK-3 |
| Access does not run before a route Worker | TASK-1(b) | the spike blocks the build; a gated machine link must never reach the origin unauthenticated |
| a forged cloud record over a machine id (a publisher with bucket write) | none; same trust as SPEC-007 DEC-011 | the cloud bytes answer, inside the edge's Access app for that path when one exists; publishers are named teammates |
| an alias rebind leaves `f.d.foundation` without a Worker | step 13's API answer; step 14's 301 check | die naming the rollback; the old Worker stays deployed |
| the gate probe on the added destinations times out | step 10 | the added destinations are removed; nothing else has changed |
| `migrate` loses ssh mid-copy | the pipe's exit code | stop; the target holds the copies already imported, unserved unless its profile serves; a rerun skips them |
| the switch fails after the CNAME moved | the remote setup's exit | `migrate` prints the one rollback command; the Air's tunnel and copies are intact until step 5 |
| a moved link does not answer | step 4 | stop before step 5, naming each link |
| a tar entry escapes the stage, or a symlink arrives | `import`'s stage scan | the import of that id dies; nothing is published for it |
| an old share CLI on the origin while R2 is on | none | it serves and adds local links without pointers; the reconcile on the next upgraded `ls` writes them and names any collision |
| the token source is a command and the menu polls | the listing token rule | local rows plus `cloud_error`; no prompt during a poll |

## Task Breakdown

- [ ] TASK-1: spike on throwaway hostnames and tokens; answers in `docs/implementation-notes/one-host-per-tenant.md`. (a) A route Worker's `fetch(request)` and a `fetch` of `https://<HOST>/healthz` reach the tunnel origin without running the Worker again. (b) Access answers an unauthenticated request to a gated path with its 302 before the route Worker runs, and an admitted request reaches the Worker with `Cf-Access-Jwt-Assertion`. (c) The pass-through of an admitted request reaches the origin (Access does not refuse the subrequest, or admits it on the forwarded cookie). (d) A POST and a WebSocket upgrade pass through to a live dev server. (e) The status codes a pass-through sees when the origin connector is down. (f) Rebinding an existing custom domain to another Worker: in place, or DELETE then PUT, and the gap. (g) `PUT access/apps/<uuid>` with added destinations keeps the AUD. (h) Whether `op://Toolkit/cf-api-token` holds Workers Routes Edit and Access Apps Edit on the Dwarves account. (i) Whether it edits tunnels and DNS on the personal account, and the 530 gap of a CNAME switch. (j) bsdtar and GNU tar flags that refuse absolute and `..` members, and how each reports a symlink. AC: each item answered or the design amended before the task that consumes it; (a) or (b) failing blocks TASK-3.
- [ ] TASK-2: per-link storage on the origin: config keys, `--cloud`, `--local`, the refusals, `rand_id` across both legs, pointer write, delete, and reconcile. Depends on TASK-1(a)(b). AC: rows 2 to 6.
- [ ] TASK-3: Worker v3 (`ALIASES`, `PASS`, two-leg `/healthz`, the offline page, the method rule, `WORKER_RECORD_V` 2) and `tests/worker.mjs`. Depends on TASK-1(a)(b)(c)(d)(e). AC: rows 7 to 10.
- [ ] TASK-4: `setup --r2` and `--no-r2` (steps 1 to 9, 12, 14, 16). Depends on TASK-2, TASK-3, TASK-1(h). AC: rows 11, 12, 13.
- [ ] TASK-5: `--alias` (steps 4, 7, 10, 11, 13, 15). Depends on TASK-4 and TASK-1(f)(g). AC: row 14.
- [ ] TASK-6: one shared list: merged rows, `storage`, `type`, `by`, `r2`, `storage_default`, `cloud_error`, the listing token rule, `profiles --json` rows for r2 profiles. Depends on TASK-2. AC: rows 1, 15, 16, 17.
- [ ] TASK-7: `import` and `migrate`. Depends on TASK-1(i)(j). AC: rows 18 to 21.
- [ ] TASK-8: Share Bar: decode, `RowGlyphs`, row rendering, the `cloud_error` line, the `Storage` popup. Depends on TASK-6. AC: rows 22 to 25; `swift build` passes.
- [ ] TASK-9: `tests/e2e-tenant.sh`, `tests/e2e-migrate.sh`, and their run logs. Depends on TASK-2 to TASK-8. AC: L1 to L10, R1, R2, every cleanup assertion.
- [ ] TASK-10: README, how-it-works, setup (onboarding), ADR-0008, the verification record with the negative controls. Depends on TASK-9. AC: each doc claim matches the code line it describes; each negative control has a red and a green run.
- [ ] TASK-11: production migration D1 to D5 and P1 to P3, each check recorded in the verification record. Depends on TASK-10 and a release. AC: `## After state`. D6 runs seven days later.

## Test plan

Local rows run in `tests/share.sh`: the r2 rows under `SHARE_R2_DRY=1` (SPEC-007's directory-backed bucket and call log), the migration rows with `SHARE_MIGRATE_SSH` pointing at a second `HOME` on the same machine. `tests/worker.mjs` drives the emitted Worker with an in-memory bucket and a stubbed global `fetch` that records each pass-through and answers from a fixture (200, 404, 530, a thrown error). Swift rows run in `swift test --package-path mac`.

### Coverage matrix

| # | Category | Case | Assert |
|---|---|---|---|
| 1 | compat | `origin/main`'s `bin/share` and the branch's, each under its own `HOME` with the same seams: a quick setup and a named dry setup with no `bucket=`, add file, add folder, add live, `--host`, `ls`, `state`, `profiles --json`; then an r2 member profile | every file byte-identical; stdout and stderr identical except the `ls` tag column; `state` equal after deleting the keys `storage`, `type`, `by`, `r2`; the member's `profiles --json` entry gains rows |
| 2 | storage | origin with R2 off: `add f`, `add --local f`, `add --cloud f`; R2 on with default `local`: `add f`, `add --cloud f`, `add 3000`, `add --cloud 3000`, `add --cloud --host x.<zone> f`, `add --cloud --local f`; default `cloud`: `add f`, `add --local f` | local, local, refused with the setup line; local plus pointer, cloud, live plus pointer, refused, refused, refused; cloud, local plus pointer; refusals log no PUT and write no row |
| 3 | member | an r2 member: `add f`, `add --local f`, `add 3000` | cloud; refused naming the origin's `by`; refused |
| 4 | pointer | local add with R2 on; the bucket answers 412 for the first candidate | `GET m/<id>` and the prefix scan precede the pointer PUT; the pointer PUT carries `If-None-Match: *`, `v:2`, `storage:"machine"`, no `access=` and no `host=` in `opts`; the first candidate is skipped; the pointer PUT precedes the `pub/<id>` rename (a watcher on `pub/`); a gated add's pointer PUT precedes `POST app` |
| 5 | pointer | the pointer PUT answers 500 three times | exit 1 naming R2; no `pub/<id>`, no row, no app |
| 6 | reconcile | origin `ls` with: a machine record by this host with no row, aged 11 min; one aged 1 min; a local row with no pointer; a local row whose id holds a cloud record; `rm` and `prune` of local rows with and without a token | the old orphan pointer deleted, the young one kept; a pointer written for the bare row; the shadow line printed, nothing deleted; rm and prune delete the pointer with a token and leave it without one |
| 7 | Worker | `PASS` set: a cloud record; a machine record; no record; the bucket throws; a non-hex first segment; `/`; an expired cloud record; a cloud record whose prefix names another id | R2 bytes, no pass-through; pass-through x5 (machine, none, throw, non-hex, root); 404 with no pass-through x2 |
| 8 | Worker | `PASS` set, pass-through answers: 200 with a body; 404; 530; 502; a thrown fetch; a POST with a body; an `Upgrade: websocket` request | unchanged x2; 503 offline page with `Retry-After` x3; the POST forwarded with its method and body; the upgrade forwarded and its 101 returned unchanged |
| 9 | Worker | `ALIASES=f.test`: GET `https://f.test/ba6377/g/?a=1`, HEAD, POST, `/healthz`; Host `x.test`; `PASS` empty: a miss | 301 to `https://<HOST>/ba6377/g/?a=1`, 301, 405, 301; 404; 404 with no `fetch` call |
| 10 | Worker | `/healthz` with `PASS` set and the origin stub answering `200 ok`, then 530, then a timeout; with `PASS` empty | 200 `X-Share-Tunnel: 1`; 503 `X-Share-Tunnel: 0` x2; SPEC-007's answer with no stub call. Every row 7 to 10 answer carries `no-store` and `noindex`, and SPEC-007's rows 17 to 19 and 28 pass unchanged on the v3 source |
| 11 | setup | dry `setup --r2` on the origin | log order: script GET < bucket reads < marker GET < routes GET < `m/` list < script PUT < subdomain POST < subdomain GET < pointer PUTs < route POST < healthz; config gains the four keys; the tunnel config and Keychain items unchanged |
| 12 | setup | refusals: on a non-origin; on quick mode; a publisher token (403 on the script read); a route on `<host>/*` naming another script; a local id holding a cloud record; a marker naming a third host | each dies before any PUT, POST, or DELETE in the log |
| 13 | rollback | `--no-r2` after row 11 | route DELETE logged; the four keys gone; the next `add` writes no pointer; `rows()` output equal to before row 11 |
| 14 | alias | dry `--alias f.test` with a gated cloud record; the alias domain naming another service; the gate probe failing | order: app GET < script PUT < pointer PUTs < app PUT (destinations added, AUD unchanged) < probes < marker PUT `If-Match` < route POST < domain PUT < healthz < app PUT (alias destinations dropped) < config; the other service: dies before any write; probe failure: the added destinations removed, no marker PUT, no route |
| 15 | list | origin with R2 on: two local rows (one live, one gated), their pointers, two cloud records (one by another machine, one gated), a `v:1` cloud record without `type` named `guide` | `ls` shows six rows with tags `machine`, `live`, `cloud`, `cloud`, their types, and `by=`; no id twice; `state` rows carry `storage`, `type`, `by`; `guide` is `folder` |
| 16 | type | the type table, one fixture per row, plus a folder with `index.html`, a folder without, `Report.PDF`, `a.tar.gz`, no extension on a local file | each `type` as the table; the extension match ignores case |
| 17 | list | `state` with the bucket listing failing; with the token source `api_token_cmd`; `profiles --json` with an r2 member and a tunnel profile | local rows plus `cloud_error` (exit 0); no command run (a sentinel command that touches a file is never run), `cloud_error` names `api-token`; the member entry lists its rows |
| 18 | import | a tar with a regular tree; a symlink; a dotfile; a `../x` member; an absolute member; an id already in the index; opts `live`; opts `host=x`; a name with `/` | the first published with the original dates, `by=`, and `src` `<by>:<src>`; each other refused with no `pub/<id>` and no row |
| 19 | migrate | two `HOME`s (A the old origin, B the target, `SHARE_MIGRATE_SSH`): A holds a snapshot, a folder, a gated snapshot, a live row | B's index holds the three snapshots with A's ids, names, expiries, and `access=`; B's `pub/<id>` trees equal A's byte for byte; the live row is listed as not moved; B's dry setup ran with `--force` and the token from stdin (a `curl` shim shows the token in no argv); A's rows are in `index.migrated`, its trees in `migrated/`; A's teardown path ran and logged no DELETE of an Access app |
| 20 | migrate | a `--host` row on A; B's profile set up for another hostname; the copy failing on the second id; the remote setup failing; a verify probe failing | refused before any copy; refused before any copy; stop with the first id on B and A unchanged; A unchanged and the rollback line printed; stop before retire, the failing link named |
| 21 | migrate | rerun after row 20's copy failure | the first id skipped as already moved; the rest copied |
| 22 | swift | decode `profiles --json` fixtures with and without the new fields; a share with an unknown `type` | `storage`, `type`, `by`, `r2`, `storageDefault`, `cloudError` decoded; absent fields are nil; unknown type maps to `doc` |
| 23 | swift | `RowGlyphs` over every value in the SF Symbols table | the symbol names and words match the table; every symbol resolves with `NSImage(systemSymbolName:)` on the test host |
| 24 | swift | `MenuModel` rows: a gated cloud PDF, a live machine row, an older-CLI row with no `storage` | accessibility titles `<name>, <trailing>, PDF, in the cloud, snapshot, login required`; `..., site, on this tenant's machine, live server`; no storage word for the old row |
| 25 | swift | `PublishForm` on an origin with `r2: true` and `storage_default: cloud`; on a member; on a tunnel profile with `r2: false` | the `Storage` popup preselects `In the cloud` and the argv carries `--cloud`; a disabled `In the cloud` label and no flag; no popup and no flag |

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

### Live legs (`tests/e2e-tenant.sh`, by hand before the release)

Inputs: `SHARE_E2E_TENANT_HOST` and `SHARE_E2E_ALIAS_HOST` (unused names on a zone the admin token edits), `CLOUDFLARE_API_TOKEN` (admin), `SHARE_E2E_R2_PUBLISHER_TOKEN`, `SHARE_E2E_ACCESS_EMAIL`. The bucket is `share-e2e-<6 hex>`, and the script refuses a hostname or bucket without the `share-e2e-` prefix, so `s.d.foundation`, `f.d.foundation`, `s.han.ws`, and every existing bucket are out of reach. Everything runs under mktemp `HOME`s with `SHARE_TEST_PORT_BASE` ports.

| # | Step | Assert |
|---|---|---|
| L1 | origin A: tunnel setup of the tenant host; a local file, a gated local file, a live server on a test port | all answer as today (the gated one 302 with `kid == aud`) |
| L2 | `setup --r2` on A | `/healthz` 200 with `X-Share-Tunnel: 1` and this CLI's pair; pointers exist for L1's ids; `https://<worker>.<sub>.workers.dev/healthz` does not answer 200 |
| L3 | through the Worker | L1's links answer as before; the gated one still 302s unauthenticated and serves with the service token (SPEC-007 TASK-1(l) method); the live server answers a POST and a WebSocket echo |
| L4 | A `add --cloud`; member B joins and adds | both cloud links 200 with `no-store`; `ls` on A and on B show the same five rows with tags |
| L5 | stop A's tunnel (`share stop`) | cloud links 200; machine and live links 503 offline page; `/healthz` 503 with `X-Share-Tunnel: 0`; start A, all back |
| L6 | encoded paths `/x/..%2F<id>/f`, `//<id>/f`, `/%2F<id>/f` on a machine id and a cloud id | 400 each, from the Worker |
| L7 | `--no-r2` | the route is gone; machine links serve straight from the tunnel; cloud links 404 at Caddy |
| L8 | `setup --r2` again | back to L4's state with no new pointer PUT for existing pointers |
| L9 | B's local teardown; A `rm` of each link | A's `ls` empty; every pointer and record gone; the gated apps 404 |
| L10 | admin purge and A teardown | cleanup below |

Rehearsals (each before its production run):

| # | Rehearsal | Assert |
|---|---|---|
| R1 | the Dwarves fold on throwaway names: A is a tunnel origin on `<tenant>`, C an r2 profile on `<alias>` with a gated cloud share; then `setup --r2 --alias <alias>` on A; then the rollback list in `### Dwarves`; then the fold again | after the fold: `https://<alias>/<id>/<name>/` 301 to `https://<tenant>/<id>/<name>/`, which 302s with `kid` equal to the original AUD and serves with the service token; after the rollback: the alias serves the share itself and the tenant is a plain tunnel; after the second fold: as after the first |
| R2 | the personal move on throwaway names: A (stand-in for the Air) sets up `<tenant>` with a snapshot, a folder, a gated snapshot, a live server; `migrate --to` B on the same machine (`SHARE_MIGRATE_SSH`), then once more from the real Air to the Mini over ssh (a second throwaway name) | every snapshot link answers from B (or the Mini) at the same URL; the gated one keeps its 302 and AUD; the live link is reported as not moved; A's tunnel is deleted, its DNS record points at B's tunnel; the measured 530 gap is logged |

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

Not sampled (TASK-1): the route pass-through, Access order against a route Worker, the subrequest under Access, WebSocket pass-through, the down-origin status codes, the custom-domain rebind, the AUD after a destination edit, the Toolkit token's route, Access, and tunnel scopes, tar member handling.

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
- DEC-006: pointer records exist only with R2 on; they make the list shared on every member and the namespace collision-proof. A local add fails closed when R2 is on and the pointer cannot be written.
- DEC-007: cloud records stay `v:1` (plus an optional `type`), pointers are `v:2`, so the old Worker remains a valid rollback for every cloud link.
- DEC-008: `f.d.foundation` becomes an alias the tenant Worker answers with 301; the bucket `share-dfoundation` is adopted in place, so `ba6377` keeps its record, bytes, and Access app AUD.
- DEC-009: `share migrate` moves an origin over ssh with the receiver's `import`, keeping ids, names, dates, expiries, and gates; nothing on the old origin is deleted, only moved aside.
