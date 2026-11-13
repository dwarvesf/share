---
rev: A
---

# share system design

`share` is one bash CLI (`bin/share`, v0.9 line) that publishes a file, folder or local port at `https://<host>/<id>/`. A tenant is one hostname with one origin machine: Caddy serves the origin's links through a named Cloudflare tunnel, and when R2 is on, a tenant Worker on the same hostname serves cloud links from a private R2 bucket and passes everything else to the tunnel. Teammates publish cloud links only, with a bucket-scoped token the admin makes by hand.

This revision is the backfill: the system as built, read from `docs/research/2026-11-13-current-state-machines.md` (line cites into `bin/share` at 4564c5c). Nothing here is new.

## Use cases

Three human actors and Cloudflare. Blue is the tenant admin (owner of the origin machine and the admin token), green is a publisher member (a cloud-only R5 profile on a teammate's machine), gray is the visitor. Publishing verbs are shared by both; tenant verbs need the admin token.

```uml
id: use-cases
type: usecase
title: Use cases
level: L1
system: share tenant (one hostname)
actors:
  - {id: admin, name: Admin, kind: human, side: left, tone: blue}
  - {id: publisher, name: Publisher, kind: human, side: left, tone: green}
  - {id: visitor, name: Visitor, kind: human, side: right, tone: gray}
  - {id: cloudflare, name: Cloudflare, kind: external, side: right}
cases:
  - {id: setup, name: Set up the tenant, actor: admin, with: [cloudflare], at: [0, 0]}
  - {id: migrate, name: Migrate the origin, actor: admin, with: [cloudflare], at: [0, 1]}
  - {id: teardown, name: Tear down, actor: admin, with: [cloudflare], at: [0, 2]}
  - {id: join, name: Join as publisher, actor: publisher, at: [0, 4]}
  - {id: add, name: Add a link, actor: [admin, publisher], at: [0, 5]}
  - {id: refresh, name: Refresh a link, actor: [admin, publisher], at: [0, 6]}
  - {id: rm, name: Remove a link, actor: [admin, publisher], at: [0, 7]}
  - {id: ls, name: List links, actor: [admin, publisher], at: [0, 8]}
  - {id: prune, name: Prune expired, actor: [admin, publisher], at: [0, 9]}
  - {id: hits, name: Read hits, actor: [admin, publisher], at: [0, 10]}
  - {id: open, name: Open a link, actor: visitor, at: [1, 12]}
  - {id: access, name: Pass the Access gate, extend: open, with: [cloudflare], at: [1, 13]}
bands:
  - {name: tenant, rows: [0, 2]}
  - {name: publishing, rows: [4, 10]}
  - {name: visiting, rows: [12, 13]}
```

## Components

One machine runs the tenant: its CLI, Caddy and cloudflared. Lanes are where a piece runs: blue the origin machine, amber the Cloudflare edge, violet the Cloudflare account services, green a publisher's machine. The Worker reads the bucket for cloud links and passes the rest to the one tunnel.

```uml
id: components
type: component
title: Components (tenant with R2 on)
level: L2
lanes:
  - {id: origin, name: Origin machine (R3), tone: blue}
  - {id: edge, name: Cloudflare edge, tone: amber}
  - {id: account, name: Cloudflare account, tone: violet}
  - {id: pubm, name: Publisher machine (R5), tone: green}
nodes:
  - {id: keychain-o, name: Keychain, note: "tunnel token, publisher token", kind: store, lane: origin, at: [0, 0]}
  - {id: cli-o, name: share CLI, note: "origin profile, bash", lane: origin, at: [1, 0]}
  - {id: index, name: pub/ + index.tsv, note: "bytes and rows", kind: store, lane: origin, at: [0, 1]}
  - {id: caddy, name: Caddy, note: "127.0.0.1:<port>, serves all of pub/", lane: origin, at: [0, 3]}
  - {id: cloudflared, name: cloudflared, note: named tunnel connector, lane: origin, at: [0, 4]}
  - {id: visitor, name: Visitor, kind: ext, at: [2, 1]}
  - {id: dns, name: DNS + route, note: "CNAME to tunnel, route <host>/*", lane: edge, at: [2, 2]}
  - {id: worker, name: Worker share-<host>, note: "v4, PASS=1, BUCKET HITS TEAM SALT", lane: edge, at: [2, 3]}
  - {id: tunnel, name: Tunnel share-<host>, note: "ingress rule 0 to 127.0.0.1", lane: edge, at: [2, 4]}
  - {id: cfapi, name: Cloudflare API, note: "tunnel, DNS, Worker deploy, Access", kind: ext, lane: account, at: [3, 0]}
  - {id: access, name: Access apps, note: "one per gated link", lane: account, at: [3, 3]}
  - {id: r2, name: R2 bucket, note: "share.json, m/<id>, o/<id>.<nonce>/", kind: store, lane: account, at: [3, 2]}
  - {id: hits, name: Analytics HITS, kind: store, lane: account, at: [3, 4]}
  - {id: cli-p, name: share CLI, note: "r2 profile, backend=r2", lane: pubm, at: [4, 1]}
  - {id: keychain-p, name: Keychain, note: publisher token, kind: store, lane: pubm, at: [4, 0]}
  - {id: r2own, name: r2-own + access-pending, kind: store, lane: pubm, at: [4, 2]}
edges:
  - {from: cli-o, to: keychain-o, label: reads}
  - {from: cli-o, to: index, label: rows + bytes}
  - {from: cli-o, to: caddy, label: Caddyfile + reload}
  - {from: cli-o, to: cfapi, label: admin token (env)}
  - {from: cli-o, to: r2, label: "v:2 pointers", via: [[1.5, 1.5], [3, 1.5]]}
  - {from: cloudflared, to: caddy, label: proxies}
  - {from: caddy, to: index, label: file_server}
  - {from: cloudflared, to: tunnel, label: dials out}
  - {from: visitor, to: dns, label: "GET /<id>/"}
  - {from: dns, to: worker}
  - {from: worker, to: r2, label: "GET m/, o/", via: [[2, 2.5], [3, 2.5]]}
  - {from: worker, to: tunnel, label: "pass()"}
  - {from: worker, to: hits, label: cloud hits}
  - {from: worker, to: access, label: JWT certs, dashed: true}
  - {from: cli-p, to: cfapi, label: Access apps, via: [[3.5, 1], [3.5, 0]]}
  - {from: cli-p, to: keychain-p, label: reads}
  - {from: cli-p, to: r2own, label: own adds}
  - {from: cli-p, to: r2, label: "v:1 + bytes", via: [[3.5, 1], [3.5, 2]]}
```

## Data

Everything persisted, one table per shape. The config file and `index.tsv` live per profile per machine; the marker, records, pointers and bytes live in the bucket. A cloud record and a machine pointer share the key `m/<id>`, so one id is either cloud or machine. Admin versus publisher is recorded nowhere.

```uml
id: data
type: erd
title: Config, rows and bucket records
level: L3
tables:
  - name: config
    at: [0, 0]
    cols: [[hostname, PK], [tunnel_id, NULL], [tunnel_name, NULL], [hosts], [port], [zone], [mode, NULL], [backend, NULL], [bucket, NULL], [r2_endpoint, NULL], [storage_default, NULL], [aliases, NULL], [api_token_cmd, NULL], [r2_token_cmd, NULL]]
  - name: index.tsv row
    at: [1, 0]
    cols: [[id, PK], [name], [src], [added], [exp], [opts]]
  - name: "m/<id> pointer v:2"
    at: [2, 0]
    cols: [[id, PK], [v = 2], [storage = machine], [name], [by], [added], [expires], [opts], [type], [own_host, NULL]]
  - name: share.json marker
    at: [1, 1]
    cols: [[host, PK], [v = 1], [aliases, NULL]]
  - name: access-pending line
    at: [2, 1]
    cols: [[id, FK], [app (uuid or -:nonce)], [owner pid], [owner start], [created]]
  - name: "m/<id> cloud record v:1"
    at: [3, 0]
    cols: [[id, PK], [v = 1], [name], [src], [added], [expires], [opts], [prefix, FK], [by], [type], [aud, NULL]]
  - name: "o/<id>.<nonce8>/ bytes"
    at: [4, 0]
    cols: [[prefix, PK], [path], [body]]
  - name: r2-own line
    at: [4, 1]
    cols: [[id, FK], [prefix], [src]]
rels:
  - {from: config, to: index.tsv row, cardinality: "1:N"}
  - {from: index.tsv row, to: "m/<id> pointer v:2", cardinality: "1:0..1", label: R3 only}
  - {from: config, to: share.json marker, cardinality: "1:1", label: hostname = host}
  - {from: index.tsv row, to: access-pending line, cardinality: "1:0..1", label: gated add}
  - {from: "m/<id> pointer v:2", to: "m/<id> cloud record v:1", cardinality: "0..1:0..1", label: same key, one or other}
  - {from: "m/<id> cloud record v:1", to: "o/<id>.<nonce8>/ bytes", cardinality: "1:1", label: prefix}
  - {from: "m/<id> cloud record v:1", to: r2-own line, cardinality: "1:0..1", label: this install added}
```

## Sequences

A local add on an R2-on origin writes the pointer before any byte is served, so the Worker passes the id to the tunnel from the first request. The row append and the Caddy reload come last, under the index lock.

```uml
id: seq-add
type: sequence
title: add on the origin (tunnel, R2 on)
level: L3
participants:
  - {name: Owner, tone: blue}
  - {name: share CLI, tone: blue}
  - Keychain
  - {name: R2 bucket, tone: violet}
  - {name: Caddy, tone: blue}
messages:
  - {from: Owner, to: share CLI, text: share add report.pdf, kind: call}
  - {from: share CLI, to: Keychain, text: r2_token_check, kind: call}
  - {from: Keychain, to: share CLI, text: publisher token, kind: return}
  - {from: share CLI, to: R2 bucket, text: "rand_id: GET m/<id>, LIST o/<id>.", kind: call}
  - {from: R2 bucket, to: share CLI, text: "404, empty", kind: return}
  - {from: share CLI, to: share CLI, text: "stage_copy to .stage.X", kind: call}
  - {from: share CLI, to: R2 bucket, text: "PUT m/<id> v:2, If-None-Match *", kind: call}
  - {from: R2 bucket, to: share CLI, text: "200 (412: new id, 5 tries)", kind: return}
  - {from: share CLI, to: share CLI, text: "stage_publish to pub/<id>", kind: call}
  - {from: share CLI, to: share CLI, text: "index lock, append row", kind: call}
  - {from: share CLI, to: Caddy, text: "Caddyfile, reload", kind: call}
  - {from: share CLI, to: Owner, text: "https://<host>/<id>/", kind: return}
```

The tenant Worker answers every request on the hostname. A cloud record is served from the bucket and fails closed; a v:2 pointer or a non-id path passes to the one tunnel. Passed answers are never counted as hits.

```uml
id: seq-visit
type: sequence
title: Visitor GET through the tenant Worker
level: L3
participants:
  - {name: Visitor, tone: gray}
  - {name: Worker, tone: amber}
  - {name: R2 bucket, tone: violet}
  - {name: Tunnel, tone: amber}
  - {name: Caddy (origin), tone: blue}
messages:
  - {from: Visitor, to: Worker, text: "GET /<id>/file (route <host>/*)", kind: call}
  - {from: Worker, to: Worker, text: "alias 301, host, path guards (400)", kind: call}
  - {from: Worker, to: R2 bucket, text: "get m/<id> (2 s cap)", kind: call}
  - {from: R2 bucket, to: Worker, text: record or absent, kind: return}
  - {from: Worker, to: Worker, text: "v:1: valid, not expired, JWT if gated", kind: call}
  - {from: Worker, to: R2 bucket, text: "v:1: get o/<id>.<nonce>/file", kind: call}
  - {from: R2 bucket, to: Worker, text: bytes, kind: return}
  - {from: Worker, to: Visitor, text: "v:1: 200, no-store, hit counted", kind: return}
  - {from: Worker, to: Tunnel, text: "v:2 or absent: pass() = fetch(request)", kind: call}
  - {from: Tunnel, to: Caddy (origin), text: "cloudflared to 127.0.0.1:<port>", kind: call}
  - {from: Caddy (origin), to: Tunnel, text: "pub/<id>/file", kind: return}
  - {from: Tunnel, to: Worker, text: "200, or 530 when down", kind: return}
  - {from: Worker, to: Visitor, text: "passed answer, or 503 offline page", kind: return}
```

## State machines

A profile is exactly one role, derived from its config at load. R4 lasts only for the admin setup run; its saved config is the same shape as R5. R6 is not a flag, only an R2-shaped config with an empty index and `index.migrated`.

```uml
id: sm-profile
type: state
title: Profile role (R0 to R6)
level: L4
states:
  - {name: R1 quick, at: [1, 0]}
  - {name: R0 none, initial: true, at: [1, 1]}
  - {name: R2 origin R2 off, at: [2, 1]}
  - {name: R3 origin R2 on, at: [3, 1]}
  - {name: R6 migrated away, final: true, at: [2, 2]}
  - {name: R4 r2 admin, at: [0, 3]}
  - {name: R5 r2 publisher, at: [1, 3]}
transitions:
  - {from: R0 none, to: R1 quick, event: setup --quick}
  - {from: R1 quick, to: R0 none, event: teardown}
  - {from: R0 none, to: R2 origin R2 off, event: "setup <host>"}
  - {from: R2 origin R2 off, to: R0 none, event: teardown}
  - {from: R2 origin R2 off, to: R3 origin R2 on, event: setup --r2 --bucket B}
  - {from: R3 origin R2 on, to: R2 origin R2 off, event: setup --no-r2, guard: no alias}
  - {from: R3 origin R2 on, to: R0 none, event: teardown, guard: tenant objects stay}
  - {from: R2 origin R2 off, to: R6 migrated away, event: migrate --to T, guard: no --host rows}
  - {from: R0 none, to: R4 r2 admin, event: setup --backend r2, guard: settings 200/404, via: [[1, 1.5], [0, 1.5]]}
  - {from: R0 none, to: R5 r2 publisher, event: setup --backend r2, guard: settings 401/403 (join)}
  - {from: R4 r2 admin, to: R5 r2 publisher, event: config written}
  - {from: R5 r2 publisher, to: R0 none, event: teardown, guard: bucket and Worker stay}
```

A machine link is reachable once its bytes sit under `pub/`, before its row exists, because Caddy serves the whole tree. The pointer exists only on an R2-on origin.

```uml
id: sm-machine-link
type: state
title: Machine link lifecycle
level: L4
states:
  - {name: STAGED, initial: true, at: [0, 0]}
  - {name: POINTER, at: [1, 0]}
  - {name: REAPED, final: true, at: [2, 0]}
  - {name: PUBLISHED unlisted, at: [1, 1]}
  - {name: LISTED, at: [1, 2]}
  - {name: EXPIRED, at: [2, 2]}
  - {name: MIGRATED, final: true, at: [0, 3]}
  - {name: TRASHED, final: true, at: [2, 3]}
transitions:
  - {from: STAGED, to: POINTER, event: "PUT m/<id> v:2", guard: R3}
  - {from: STAGED, to: PUBLISHED unlisted, event: stage_publish, guard: R2 off}
  - {from: POINTER, to: PUBLISHED unlisted, event: stage_publish}
  - {from: POINTER, to: REAPED, event: die, guard: reconcile after 10 min}
  - {from: PUBLISHED unlisted, to: LISTED, event: row appended}
  - {from: LISTED, to: EXPIRED, event: exp passes}
  - {from: EXPIRED, to: TRASHED, event: prune}
  - {from: LISTED, to: TRASHED, event: rm}
  - {from: LISTED, to: MIGRATED, event: migrate --to T}
```

A cloud link is published by one conditional PUT of its record. Bytes go to a fresh prefix first; a die before the record leaves a prefix that the trap or the 24 h orphan sweep removes.

```uml
id: sm-cloud-link
type: state
title: Cloud link lifecycle
level: L4
states:
  - {name: STAGED, initial: true, at: [0, 0]}
  - {name: UPLOADED, at: [1, 0]}
  - {name: PUBLISHED, at: [3, 0]}
  - {name: EXPIRED, at: [4, 0]}
  - {name: APP PENDING, at: [1, 1]}
  - {name: ENFORCED, at: [2, 1]}
  - {name: DELETED, final: true, at: [4, 1]}
  - {name: SWEPT, final: true, at: [1, 2]}
transitions:
  - {from: STAGED, to: UPLOADED, event: "PUT o/<id>.<nonce>/*"}
  - {from: UPLOADED, to: PUBLISHED, event: "PUT m/<id> v:1", guard: ungated}
  - {from: UPLOADED, to: APP PENDING, event: access_create, guard: gated}
  - {from: APP PENDING, to: ENFORCED, event: gate 3 rounds}
  - {from: ENFORCED, to: PUBLISHED, event: "PUT m/<id> v:1 with aud"}
  - {from: UPLOADED, to: SWEPT, event: "die or 412", guard: trap or 24 h sweep, via: [[1, 0.5], [0.5, 0.5], [0.5, 2]]}
  - {from: APP PENDING, to: SWEPT, event: gate fails}
  - {from: PUBLISHED, to: EXPIRED, event: expires passes (Worker 404)}
  - {from: EXPIRED, to: DELETED, event: publisher ls or prune}
  - {from: PUBLISHED, to: DELETED, event: rm (any publisher)}
```

The origin's reconcile runs inside an interactive `ls` or `prune` with a token, never in the hourly loop. It assumes one origin per tenant: every valid v:2 pointer is this machine's. Drawn as decisions: amber boxes are tests, the other boxes are the action taken for one id.

```uml
id: sm-reconcile
type: state
title: Origin reconcile decision
level: L4
caption: "Decision drawn as states. Amber boxes are tests, rose deletes, green writes, gray changes nothing; one pass per id."
states:
  - {name: read m/ and index, initial: true, at: [1, 0], tone: amber}
  - {name: skip (prune owns it), at: [3, 0], tone: gray}
  - {name: no local row, at: [0, 1], tone: amber}
  - {name: unexpired row, at: [2, 1], tone: amber}
  - {name: delete orphan pointer, at: [0, 2], tone: rose}
  - {name: skip (add may be writing), at: [1, 2], tone: gray}
  - {name: keep, at: [2, 2], tone: gray}
  - {name: write missing pointer, at: [3, 2], tone: green}
  - {name: report shadowed, at: [2, 3], tone: gray}
transitions:
  - {from: read m/ and index, to: no local row, event: "v:2 pointer, no row", via: [[1, 0.5], [0, 0.5]]}
  - {from: read m/ and index, to: unexpired row, event: row exists, via: [[1, 0.5], [2, 0.5]]}
  - {from: read m/ and index, to: skip (prune owns it), event: row expired}
  - {from: no local row, to: delete orphan pointer, event: older than 10 min, guard: no pending line, no add lock}
  - {from: no local row, to: skip (add may be writing), event: younger than 10 min}
  - {from: unexpired row, to: keep, event: valid v:2}
  - {from: unexpired row, to: write missing pointer, event: key absent}
  - {from: unexpired row, to: report shadowed, event: "v:1, corrupt or v>2", via: [[1.5, 1], [1.5, 3]]}
  - {from: write missing pointer, to: report shadowed, event: 412}
```

## Cross-cutting concepts

- One origin per tenant. Every v:2 pointer is the origin's own, and its reconcile reaps any pointer with no local row after 10 minutes.
- Conditional writes in R2 (`If-None-Match: *`, `If-Match`) are the only cross-machine concurrency control. Local symlink locks (`index`, `host`, `add-<id>`) hold within one profile on one machine.
- Publishing is the record PUT. Bytes always go to a fresh prefix `o/<id>.<nonce8>/`; nothing overwrites bytes in place, and a refresh swaps the record with `If-Match`.
- Refuse before the first write. Every multi-step setup checks all guards first, and a rerun converges, skipping each step already in place.
- The Worker fails closed for cloud ids (any doubt is 404) and passes v:2 pointers and non-id paths to the origin unchanged.
- The admin token lives in the environment only and is never stored; a publisher token is bucket-scoped and lives in the Keychain.

## Risks and technical debt

- Caddy serves the whole `pub/` tree. Bites when an add dies between `stage_publish` and the row append: the bytes stay reachable with no row, and no sweep removes them. No mitigation.
- `by` is an unauthenticated `uname -n`, and any publisher may rm any cloud link. Bites if a publisher token leaks or a teammate errs. Mitigated only by ADR-0007's named-teammates rule.
- The hourly prune runs with no token. Bites as orphan pointers and expired cloud records that wait for someone's interactive `ls` or `prune`. Machine-link expiry is enforced only by the origin's prune, never by the Worker.
- One origin machine holds the tunnel token and is the only place the Worker redeploys from. Bites when that machine is lost: links go offline and the admin cannot redeploy from elsewhere.
- A record of an unknown version blocks the orphan sweep of every CLI that cannot read it. Bites on the first new record version. `WORKER_RECORD_V` is dead code.
- `teardown` on an R2-on origin removes the tunnel and DNS but leaves the route, Worker, pointers and marker. Bites as a half-torn tenant; cleaned only by hand or `--purge` from an r2 admin profile.
