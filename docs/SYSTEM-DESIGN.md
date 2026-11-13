---
rev: B
decided:
  - "Members serve from their own machines behind the one tenant hostname via Workers VPC bindings."
  - "Removed member's cloud links stay until they expire."
  - "Workers VPC beta accepted behind --members."
  - "First live member is a second machine of the owner's."
  - "The Worker gains one narrow write: delete i/<hash> on redeem."
  - "Cut from v1: member move, edit verb, teardown --cascade, member gated links, member hits."
  - "Spike O1 passed: VPC Service to 127.0.0.1 over a tunnel with no ingress, Free plan, no warp-routing."
  - "Spike O2 passed for user tokens: mint, one-time secret, expiry extended in place, found by name."
---

# share system design

`share` is one bash CLI (`bin/share`, v0.9 line) that publishes a file, folder or local port at `https://<host>/<id>/`. A tenant is one hostname with one origin machine: Caddy serves the origin's links through a named Cloudflare tunnel, and when R2 is on, a tenant Worker on the same hostname serves cloud links from a private R2 bucket and passes everything else to the tunnel. Teammates publish cloud links only, with a bucket-scoped token the admin makes by hand.

Rev A was the backfill of the system as built (`docs/research/2026-11-13-current-state-machines.md`). Rev B is the multi-member design from `docs/briefs/DECISION-BRIEF-multi-member.md` (r2): members serve links from their own machines behind the same hostname, through one Workers VPC binding each, with a member registry in the bucket and tool-minted credentials redeemed once. Nothing in rev B is built.

## Use cases

Rev B adds the machine member (violet, shown as Member) and the admin's member verbs. A member reaches the system only through a code, `join`, its publishing verbs and `leave`; every member verb is the admin's. Blue is the admin, green a cloud-only publisher (today's R5), violet a machine member, gray the visitor.

```uml
id: use-cases
type: usecase
title: Use cases
level: L1
system: share tenant (one hostname)
review:
  - Should a cloud-only publisher (R5 today) be forced through `member adopt`, or keep working unregistered behind `min_cli`?
  - "`leave --local` makes no bucket call. Is a member allowed to run it while still ACTIVE, leaving its record for the admin to rm?"
actors:
  - {id: admin, name: Admin, kind: human, side: left, tone: blue}
  - {id: publisher, name: Publisher, kind: human, side: right, tone: green}
  - {id: member, name: Member, kind: human, side: right, tone: violet}
  - {id: visitor, name: Visitor, kind: human, side: right, tone: gray}
  - {id: cloudflare, name: Cloudflare, kind: external, side: right}
cases:
  - {id: setup, name: Set up the tenant, actor: admin, with: [cloudflare], at: [1, 3]}
  - {id: migrate, name: Migrate the origin, actor: admin, with: [cloudflare], at: [1, 4]}
  - {id: teardown, name: Tear down, actor: admin, with: [cloudflare], at: [1, 5]}
  - {id: member-add, name: member add, actor: admin, at: [0, 14]}
  - {id: member-invite, name: member invite, actor: admin, at: [0, 15]}
  - {id: member-pause, name: member pause, actor: admin, at: [0, 16]}
  - {id: member-resume, name: member resume, actor: admin, at: [0, 17]}
  - {id: member-rotate, name: member rotate, actor: admin, at: [0, 18]}
  - {id: member-rm, name: member rm, actor: admin, at: [0, 19]}
  - {id: member-purge, name: member purge, actor: admin, at: [0, 20]}
  - {id: member-adopt, name: member adopt, actor: admin, at: [0, 21]}
  - {id: member-ls, name: member ls, actor: admin, at: [0, 22]}
  - {id: member-sync, name: member sync, actor: admin, at: [0, 23]}
  - {id: join, name: Join with a code, actor: [publisher, member], at: [1, 25]}
  - {id: leave, name: leave, actor: [publisher, member], at: [1, 26]}
  - {id: leave-local, name: leave --local, actor: [publisher, member], at: [1, 27]}
  - {id: add, name: Add a link, actor: [admin, publisher, member], at: [1, 7]}
  - {id: refresh, name: Refresh a link, actor: [admin, publisher, member], at: [1, 8]}
  - {id: rm, name: Remove a link, actor: [admin, publisher, member], at: [1, 9]}
  - {id: ls, name: List links, actor: [admin, publisher, member], at: [1, 10]}
  - {id: prune, name: Prune expired, actor: [admin, publisher, member], at: [1, 11]}
  - {id: hits, name: Read hits, actor: [admin, publisher], at: [1, 12]}
  - {id: open, name: Open a link, actor: visitor, at: [1, 0]}
  - {id: access, name: Pass the Access gate, extend: open, with: [cloudflare], at: [1, 1]}
bands:
  - {name: visiting, rows: [0, 1]}
  - {name: tenant, rows: [3, 5]}
  - {name: publishing, rows: [7, 12]}
  - {name: member admin, rows: [14, 23]}
  - {name: member side, rows: [25, 27]}
```

## Components

Rev B adds a member machine (violet lane, bottom left) that runs its own Caddy and cloudflared on a tunnel with no hostname. The Worker reaches it through a Workers VPC Service bound as `M_<8hex>`, so the hostname stays one. Lanes are where a piece runs: blue the origin, amber the Cloudflare edge, gray the Cloudflare account, green a cloud-only publisher, violet a machine member. Admin verbs need only the admin token and the hostname, so they run from any machine.

```uml
id: components
type: component
title: Components (tenant with R2 on)
level: L2
review:
  - Is one VPC Service plus one Worker binding per machine member acceptable, given every member verb redeploys the whole Worker?
  - The minter token sits beside the admin token in 1Password. Should it live on a different vault or machine?
lanes:
  - {id: origin, name: Origin machine (R3), tone: blue}
  - {id: edge, name: Cloudflare edge, tone: amber}
  - {id: account, name: Cloudflare account, tone: gray}
  - {id: pubm, name: Cloud member (R5), tone: green}
  - {id: member, name: Member machine (machine member), tone: violet}
nodes:
  - {id: keychain-o, name: Keychain, note: "tunnel token, publisher token", kind: store, lane: origin, at: [0, 0]}
  - {id: cli-o, name: share CLI, note: "origin profile; admin verbs from any machine", lane: origin, at: [1, 0]}
  - {id: index, name: pub/ + index.tsv, note: "bytes and rows", kind: store, lane: origin, at: [0, 1]}
  - {id: vault, name: 1Password, note: "admin token, minter token", kind: ext, lane: origin, at: [1, 1]}
  - {id: caddy, name: Caddy, note: "127.0.0.1:<port>, one handle per listed row", lane: origin, at: [0, 3]}
  - {id: cloudflared, name: cloudflared, note: named tunnel connector, lane: origin, at: [0, 4]}
  - {id: visitor, name: Visitor, kind: ext, at: [2, 1]}
  - {id: dns, name: DNS + route, note: "CNAME to tunnel, route <host>/*", lane: edge, at: [2, 2]}
  - {id: worker, name: Worker share-<host>, note: "v5: PASS, PAUSED, M_<8hex> bindings, /_share/redeem", lane: edge, at: [2, 3]}
  - {id: tunnel, name: Tunnel share-<host>, note: "ingress rule 0 to 127.0.0.1", lane: edge, at: [2, 4]}
  - {id: vpc, name: VPC Service, note: "share-<host>-<8hex>: tunnel + 127.0.0.1:<port>", lane: edge, at: [3, 4]}
  - {id: mtunnel, name: Member tunnel, note: "share-<host>-<8hex>, no hostname, no ingress", lane: edge, at: [3, 6]}
  - {id: cfapi, name: Cloudflare API, note: "tunnels, DNS, Worker deploy, Access, VPC Services, minted tokens", kind: ext, lane: account, at: [4, 0]}
  - {id: access, name: Access apps, note: "one per gated link", lane: account, at: [4, 1]}
  - {id: r2, name: R2 bucket, note: "share.json, m/, o/, u/, i/, t/, lock/admin", kind: store, lane: account, at: [4, 2]}
  - {id: hits, name: Analytics HITS, kind: store, lane: account, at: [4, 3]}
  - {id: keychain-p, name: Keychain, note: publisher token, kind: store, lane: pubm, at: [5, 0]}
  - {id: cli-p, name: share CLI, note: "r2 profile, backend=r2", lane: pubm, at: [5, 1]}
  - {id: r2own, name: r2-own + access-pending, kind: store, lane: pubm, at: [5, 2]}
  - {id: caddy-m, name: Caddy, note: "127.0.0.1:<port>, listed rows only", lane: member, at: [0, 6]}
  - {id: cloudflared-m, name: cloudflared, note: member connector, lane: member, at: [1, 6]}
  - {id: pub-m, name: pub/ + index.tsv, note: own rows only, kind: store, lane: member, at: [0, 7]}
  - {id: cli-m, name: share CLI, note: "role=member, hourly reconcile", lane: member, at: [1, 7]}
  - {id: keychain-m, name: Keychain, note: "publisher + connector token", kind: store, lane: member, at: [1, 8]}
edges:
  - {from: cli-o, to: keychain-o, label: reads}
  - {from: cli-o, to: index, label: rows + bytes}
  - {from: cli-o, to: caddy, label: Caddyfile + reload, via: [[1.5, 0], [1.5, 3]]}
  - {from: cli-o, to: cfapi, label: admin token (env)}
  - {from: cli-o, to: vault, label: op read}
  - {from: cli-o, to: r2, label: "v:2 pointers", via: [[1.5, 1.5], [4, 1.5]]}
  - {from: cloudflared, to: caddy, label: proxies}
  - {from: caddy, to: index, label: file_server}
  - {from: cloudflared, to: tunnel, label: dials out}
  - {from: visitor, to: dns, label: "GET /<id>/"}
  - {from: dns, to: worker}
  - {from: worker, to: r2, label: "GET m/, o/", via: [[2, 2.5], [4, 2.5]]}
  - {from: worker, to: tunnel, label: "pass()"}
  - {from: worker, to: hits, label: cloud hits}
  - {from: worker, to: access, label: JWT certs, dashed: true, via: [[2.5, 3], [2.5, 1]]}
  - {from: worker, to: vpc, label: "env.M_<8hex>.fetch()", via: [[2, 3.5], [3, 3.5]]}
  - {from: vpc, to: mtunnel, label: "127.0.0.1:<port>"}
  - {from: cloudflared-m, to: mtunnel, label: dials out}
  - {from: cloudflared-m, to: caddy-m, label: proxies}
  - {from: caddy-m, to: pub-m, label: listed rows}
  - {from: cli-m, to: pub-m, label: rows + bytes}
  - {from: cli-m, to: keychain-m, label: reads}
  - {from: cli-m, to: r2, label: "v:3 pointers, u/ status, t/", via: [[1.5, 7], [1.5, 5.5], [3.5, 5.5], [3.5, 2]]}
  - {from: cli-p, to: cfapi, label: Access apps, via: [[4.5, 1], [4.5, 0]]}
  - {from: cli-p, to: keychain-p, label: reads}
  - {from: cli-p, to: r2own, label: own adds}
  - {from: cli-p, to: r2, label: "v:1 + bytes", via: [[4.5, 1], [4.5, 2]]}
```

## Data

Rev B adds the member registry `u/`, the v:3 pointer that names its origin, the tombstone `t/`, the sealed invite `i/` and the admin lease, all in the bucket. The marker gains `members` and `min_cli`; config gains `members=on` on the origin and `role`, `member_id` on a member (its `mode=` key then names machine or cloud, a third value beside quick). Index rows gain the `revoked` opts token. One key `m/<id>` still holds exactly one of v:1, v:2 or v:3.

```uml
id: data
type: erd
title: Config, rows and bucket records
level: L3
review:
  - "`u/` records are writable by any publisher token. Is reporting drift in `member ls` and repairing it with `member sync` enough, given routing reads only the deploy?"
  - Should the sealed invite also carry the member's port and mode, or must `join` read them from `u/`?
tables:
  - name: config
    at: [0, 0]
    cols: [[hostname, PK], [tunnel_id, NULL], [tunnel_name, NULL], [hosts], [port], [zone], [mode, NULL], [backend, NULL], [bucket, NULL], [r2_endpoint, NULL], [storage_default, NULL], [aliases, NULL], [api_token_cmd, NULL], [r2_token_cmd, NULL], [members, NULL], [role, NULL], [member_id, NULL]]
  - name: index.tsv row
    at: [1, 0]
    cols: [[id, PK], [name], [src], [added], [exp], [opts]]
  - name: "m/<id> pointer v:2"
    at: [2, 0]
    cols: [[id, PK], [v = 2], [storage = machine], [name], [by], [added], [expires], [opts], [type], [own_host, NULL]]
  - name: "m/<id> cloud record v:1"
    at: [3, 0]
    cols: [[id, PK], [v = 1], [name], [src], [added], [expires], [opts], [prefix, FK], [by], [type], [aud, NULL], [origin, NULL]]
  - name: "o/<id>.<nonce8>/ bytes"
    at: [4, 0]
    cols: [[prefix, PK], [path], [body]]
  - name: share.json marker
    at: [1, 1]
    cols: [[host, PK], [v = 1], [aliases, NULL], [members, NULL], [min_cli, NULL]]
  - name: access-pending line
    at: [2, 1]
    cols: [[id, FK], [app (uuid or -:nonce)], [owner pid], [owner start], [created]]
  - name: lock/admin lease
    at: [3, 1]
    cols: [[holder], [expires]]
  - name: r2-own line
    at: [4, 1]
    cols: [[id, FK], [prefix], [src]]
  - name: "u/<member_id> record"
    at: [0, 2]
    cols: [[member_id, PK], [name], [mode], [status], [tunnel_id, NULL], [vpc_service_id, NULL], [token_ids], [token_expires], [port, NULL], [joined, NULL], [updated]]
  - name: "m/<id> pointer v:3"
    at: [1, 2]
    cols: [[id, PK], [v = 3], [storage = machine], [origin, FK], [name], [by], [added], [expires], [opts], [type]]
  - name: "t/<id> tombstone"
    at: [2, 2]
    cols: [[id, PK], [origin, FK], [by], [LastModified]]
  - name: "i/<sha256(code)> invite"
    at: [0, 3]
    cols: [[hash, PK], [member_id, FK], [sealed tokens], [expires]]
rels:
  - {from: config, to: index.tsv row, cardinality: "1:N"}
  - {from: index.tsv row, to: "m/<id> pointer v:2", cardinality: "1:0..1", label: R3 only}
  - {from: config, to: share.json marker, cardinality: "1:1", label: hostname = host}
  - {from: index.tsv row, to: access-pending line, cardinality: "1:0..1", label: gated add}
  - {from: "m/<id> pointer v:2", to: "m/<id> cloud record v:1", cardinality: "0..1:0..1", label: same key, one or other}
  - {from: "m/<id> cloud record v:1", to: "o/<id>.<nonce8>/ bytes", cardinality: "1:1", label: prefix}
  - {from: "m/<id> cloud record v:1", to: r2-own line, cardinality: "1:0..1", label: this install added}
  - {from: "u/<member_id> record", to: "m/<id> pointer v:3", cardinality: "1:N", label: origin}
  - {from: "m/<id> pointer v:3", to: "t/<id> tombstone", cardinality: "0..1:0..1", label: revoked}
  - {from: "u/<member_id> record", to: "i/<sha256(code)> invite", cardinality: "1:0..1", label: one live code}
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

`member add` runs under the admin lease and in the one write order: the record says `adding` first, then every Cloudflare object, then the record says `invited`. A die anywhere leaves `adding`, and the rerun on the same name resumes, finding the token by name. Blue is the admin side, gray Cloudflare, violet the bucket.

```uml
id: seq-member-add
type: sequence
title: member add (admin, machine mode)
level: L3
review:
  - "If the token was minted but its secret never sealed (die between steps 4 and 11), the rerun deletes and re-mints it. Is that safe while an older code could still be redeemed?"
  - Should the lease expiry be fixed (for example 10 minutes) or set per verb?
participants:
  - {name: Admin, tone: blue}
  - {name: share CLI, tone: blue}
  - {name: R2 bucket, tone: violet}
  - {name: Cloudflare API, tone: gray}
  - {name: Worker, tone: amber}
messages:
  - {from: Admin, to: share CLI, text: "member add an --machine", kind: call}
  - {from: share CLI, to: R2 bucket, text: "PUT lock/admin, If-None-Match *", kind: call}
  - {from: share CLI, to: R2 bucket, text: "PUT u/<id> status=adding, If-None-Match *", kind: call}
  - {from: share CLI, to: Cloudflare API, text: "minter: token share <host> <member_id>", kind: call}
  - {from: share CLI, to: Cloudflare API, text: "create tunnel (no ingress), get connector token", kind: call}
  - {from: share CLI, to: Cloudflare API, text: "create VPC Service (tunnel, 127.0.0.1:<port>)", kind: call}
  - {from: share CLI, to: Cloudflare API, text: "deploy Worker from registry + M_<8hex>", kind: call}
  - {from: Cloudflare API, to: share CLI, text: deployed, kind: return}
  - {from: share CLI, to: Worker, text: "GET /healthz (VERSION SHA pair)", kind: call}
  - {from: share CLI, to: R2 bucket, text: "PUT i/<sha256(code)> sealed, expires", kind: call}
  - {from: share CLI, to: R2 bucket, text: "PUT u/<id> status=invited, If-Match", kind: call}
  - {from: share CLI, to: R2 bucket, text: DELETE lock/admin, kind: call}
  - {from: share CLI, to: Admin, text: "code, shown once", kind: return}
```

`join <code>` redeems through the Worker, which checks the expiry on its own clock and deletes the sealed invite: this is the Worker's one write. The record moves to `joining` before anything local exists, so a concurrent admin verb fails the join early.

```uml
id: seq-join
type: sequence
title: join with a code (redeem once)
level: L3
review:
  - "Redeem deletes `i/<hash>` before the member writes `joining`. If the join dies after redeem, the code is spent: is `member invite` the right recovery?"
  - Is a probe link fetched 3x200 through the Worker enough proof that the VPC binding reaches this machine?
participants:
  - {name: Member, tone: violet}
  - {name: share CLI, tone: violet}
  - {name: Worker, tone: amber}
  - {name: R2 bucket, tone: violet}
  - {name: Caddy + cloudflared, tone: violet}
messages:
  - {from: Member, to: share CLI, text: share join <code>, kind: call}
  - {from: share CLI, to: share CLI, text: "CLI >= min_cli, port free", kind: call}
  - {from: share CLI, to: Worker, text: "POST /_share/redeem (sha256(code))", kind: call}
  - {from: Worker, to: R2 bucket, text: "get i/<hash>, expiry by server time", kind: call}
  - {from: Worker, to: R2 bucket, text: "delete i/<hash>", kind: call}
  - {from: Worker, to: share CLI, text: sealed bytes, kind: return}
  - {from: share CLI, to: share CLI, text: "unseal: publisher + connector token", kind: call}
  - {from: share CLI, to: R2 bucket, text: "PUT u/<id> status=joining, If-Match", kind: call}
  - {from: share CLI, to: share CLI, text: "config role=member, tokens to Keychain", kind: call}
  - {from: share CLI, to: Caddy + cloudflared, text: start service, kind: call}
  - {from: share CLI, to: Worker, text: "probe link, GET 3x200", kind: call}
  - {from: share CLI, to: R2 bucket, text: "PUT u/<id> status=active, joined", kind: call}
  - {from: share CLI, to: Member, text: "joined as m-an-3f9a1c2d", kind: return}
```

`member rm` cuts routing first: the redeploy without `M_<8hex>` makes every machine link of that member 404 at once, before any object is deleted. Each of its v:3 links becomes a tombstone, so the bytes on its machine are never touched from outside. Cloud links stay until they expire.

```uml
id: seq-member-rm
type: sequence
title: member rm (admin)
level: L3
review:
  - The tombstones of a removed member are swept after 30 days by LastModified. Is 30 days right when the machine may never come back?
  - Should `member rm` refuse while the member is ONLINE and has links, or always proceed?
participants:
  - {name: Admin, tone: blue}
  - {name: share CLI, tone: blue}
  - {name: R2 bucket, tone: violet}
  - {name: Cloudflare API, tone: gray}
messages:
  - {from: Admin, to: share CLI, text: member rm an, kind: call}
  - {from: share CLI, to: R2 bucket, text: "PUT lock/admin, If-None-Match *", kind: call}
  - {from: share CLI, to: R2 bucket, text: "PUT u/<id> status=removing, If-Match", kind: call}
  - {from: share CLI, to: Cloudflare API, text: "deploy without M_<8hex>, id off PAUSED", kind: call}
  - {from: share CLI, to: Cloudflare API, text: delete VPC Service, kind: call}
  - {from: share CLI, to: Cloudflare API, text: "delete connections, then tunnel", kind: call}
  - {from: share CLI, to: Cloudflare API, text: delete publisher token, kind: call}
  - {from: share CLI, to: R2 bucket, text: "each v:3 of origin: PUT t/<id>, DELETE m/<id>", kind: call}
  - {from: share CLI, to: R2 bucket, text: "cloud links: keep until expiry", kind: call}
  - {from: share CLI, to: R2 bucket, text: "PUT u/<id> status=removed", kind: call}
  - {from: share CLI, to: R2 bucket, text: DELETE lock/admin, kind: call}
  - {from: share CLI, to: Admin, text: removed, kind: return}
```

A member link reaches its machine through the VPC binding, never through the tenant's tunnel. Worker v5 checks expiry on every pointer, answers 503 for a paused member, and 404 when the binding is gone. Spike O1 showed request headers pass through a binding unchanged, so the Worker strips Access headers itself; the Host stays the tenant hostname, streaming works, and the hop adds 150 to 350 ms.

```uml
id: seq-visit-member
type: sequence
title: Visitor GET of a member link
level: L3
review:
  - The offline page stays generic (no member name). Is that enough for a visitor, or should `member ls` be the only place that says which member is down?
  - Should a paused member's link answer 503 (paused) or 404, given 503 tells a visitor the link exists?
participants:
  - {name: Visitor, tone: gray}
  - {name: Worker, tone: amber}
  - {name: R2 bucket, tone: violet}
  - {name: VPC Service, tone: amber}
  - {name: Member Caddy, tone: violet}
messages:
  - {from: Visitor, to: Worker, text: "GET /<id>/file", kind: call}
  - {from: Worker, to: R2 bucket, text: "get m/<id>", kind: call}
  - {from: R2 bucket, to: Worker, text: "v:3 {origin: m-an-3f9a1c2d}", kind: return}
  - {from: Worker, to: Worker, text: "past expires: 404", kind: call}
  - {from: Worker, to: Worker, text: "origin in PAUSED: 503 paused", kind: call}
  - {from: Worker, to: Worker, text: "no binding M_3f9a1c2d: 404", kind: call}
  - {from: Worker, to: Worker, text: "rewrite to http://<HOST><path>, strip Access headers", kind: call}
  - {from: Worker, to: VPC Service, text: "env.M_3f9a1c2d.fetch()", kind: call}
  - {from: VPC Service, to: Member Caddy, text: "member tunnel, 127.0.0.1:<port>", kind: call}
  - {from: Member Caddy, to: VPC Service, text: "handle /<id>/*: listed row only", kind: return}
  - {from: VPC Service, to: Worker, text: "200, or down", kind: return}
  - {from: Worker, to: Visitor, text: "200 (hit counted), or generic 503", kind: return}
```

When the admin removes a member's link, the admin cannot reach the member's disk. It writes a tombstone and deletes the pointer, so the link 404s at once. The owner's next hourly reconcile flags the row revoked, drops its Caddy handle and deletes the tombstone; the bytes wait for the owner's own `rm` or the row's expiry.

```uml
id: seq-revoke
type: sequence
title: Admin rm of a member link, then the owner's reconcile
level: L3
review:
  - A forged tombstone with no matching pointer delete is ignored (the pointer proves the link is wanted). Should the owner's reconcile also alert the admin when it sees one?
  - Is one hour from revoke to the handle drop acceptable, given the link already 404s at the Worker?
participants:
  - {name: Admin, tone: blue}
  - {name: share CLI (admin), tone: blue}
  - {name: R2 bucket, tone: violet}
  - {name: share CLI (owner), tone: violet}
  - {name: Owner Caddy, tone: violet}
messages:
  - {from: Admin, to: share CLI (admin), text: "share rm <id>", kind: call}
  - {from: share CLI (admin), to: R2 bucket, text: "GET m/<id>: v:3, other origin", kind: call}
  - {from: share CLI (admin), to: R2 bucket, text: "PUT t/<id>, If-None-Match *", kind: call}
  - {from: share CLI (admin), to: R2 bucket, text: "DELETE m/<id>, GET proves 404", kind: call}
  - {from: share CLI (admin), to: Admin, text: "revoked; bytes stay on the owner", kind: return}
  - {from: share CLI (owner), to: R2 bucket, text: "hourly reconcile: LIST m/, t/", kind: call}
  - {from: R2 bucket, to: share CLI (owner), text: "t/<id> present, m/<id> absent", kind: return}
  - {from: share CLI (owner), to: share CLI (owner), text: flag row revoked, kind: call}
  - {from: share CLI (owner), to: Owner Caddy, text: "drop handle, reload", kind: call}
  - {from: share CLI (owner), to: R2 bucket, text: "DELETE t/<id>", kind: call}
  - {from: share CLI (owner), to: share CLI (owner), text: "ls: removed by <who>", kind: call}
```

## State machines

A profile is exactly one role, derived from its config at load. R4 lasts only for the admin setup run; its saved config is the same shape as R5. R6 is not a flag, only an R2-shaped config with an empty index and `index.migrated`. Rev B adds R7: a member profile, written only by `join <code>` and removed by `leave` or `leave --local`.

```uml
id: sm-profile
type: state
title: Profile role (R0 to R7)
level: L4
review:
  - Is a member profile its own role R7, or an R5 profile plus `member_id`? Every `r2on` site (28) needs a member behavior either way.
states:
  - {name: R1 quick, at: [1, 0]}
  - {name: R0 none, initial: true, at: [1, 1]}
  - {name: R2 origin R2 off, at: [2, 1]}
  - {name: R3 origin R2 on, at: [3, 1]}
  - {name: R6 migrated away, final: true, at: [2, 2]}
  - {name: R4 r2 admin, at: [0, 3]}
  - {name: R5 r2 publisher, at: [1, 3]}
  - {name: R7 member, at: [0, 0], tone: violet}
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
  - {from: R0 none, to: R7 member, event: "join <code>", tone: violet, via: [[1, 0.5], [0, 0.5]]}
  - {from: R7 member, to: R0 none, event: "leave, leave --local", tone: violet, via: [[0, 0.5], [1, 0.5]]}
```

New in rev B. The tenant is a state of its own: T2 turns members on. While any member record exists, every verb that could drop a binding is refused, because the deploy is the only routing table. T0 and T1 are today's R2 and R3 origin.

```uml
id: sm-tenant
type: state
title: Tenant (T0 to T2)
level: L4
caption: "The filled dot is the start. Gray holds the refusals: the tenant stays T2."
review:
  - T1 to T2 asks the owner to confirm every publisher runs `min_cli`. Should the CLI check the publishers it can see instead of asking?
  - Is refusing `teardown` while member records exist right, given `teardown --cascade` is cut from v1?
states:
  - {name: T0 tunnel R2 off, initial: true, at: [0, 0]}
  - {name: T1 R2 on, at: [1, 0]}
  - {name: T2 members on, at: [2, 0], tone: violet}
  - {name: refused (stays T2), at: [2, 1], tone: gray}
transitions:
  - {from: T0 tunnel R2 off, to: T1 R2 on, event: setup --r2}
  - {from: T1 R2 on, to: T0 tunnel R2 off, event: setup --no-r2}
  - {from: T1 R2 on, to: T2 members on, event: setup --r2 --members, guard: "scopes probed, VPC answers, min_cli confirmed"}
  - {from: T2 members on, to: T1 R2 on, event: setup --no-members, guard: every record REMOVED}
  - {from: T2 members on, to: refused (stays T2), event: "teardown, migrate, --no-r2, older CLI --force", tone: gray}
```

New in rev B. A member's lifecycle lives in its `u/` record, written in the one order intent, Cloudflare, final. `member rm` works from every state but REMOVED. `rotate` sends ACTIVE or PAUSED back to INVITED with `prev_status` kept and drops the connectors; the member's join with the new code restores `prev_status`, so a paused member comes back paused. The full table, with every `...ing` intent, is in SPEC-009, section "Member status transitions". OFFLINE is runtime only, never stored. Violet is stored status, gray is runtime.

```uml
id: sm-member
type: state
title: Member lifecycle
level: L4
review:
  - "LEFT keeps the record until `member rm`. Should `leave` go straight to REMOVED when the member's own links are all gone?"
  - Is EXPIRED worth a stored status, or only a read of INVITED plus the invite's expiry?
states:
  - {name: none, initial: true, at: [0, 1], tone: gray}
  - {name: EXPIRED, at: [1, 0], tone: violet}
  - {name: INVITED, at: [1, 1], tone: violet}
  - {name: OFFLINE (runtime), at: [2, 0], tone: gray}
  - {name: ACTIVE, at: [2, 1], tone: violet}
  - {name: PAUSED, at: [3, 1], tone: violet}
  - {name: LEFT, at: [2, 2], tone: violet}
  - {name: REMOVING, at: [2, 4], tone: violet}
  - {name: REMOVED, at: [2, 5], tone: violet}
  - {name: purged, final: true, at: [3, 5], tone: gray}
transitions:
  - {from: none, to: INVITED, event: member add}
  - {from: none, to: ACTIVE, event: member adopt (cloud), via: [[0, 0.5], [1.5, 0.5], [1.5, 1]]}
  - {from: INVITED, to: ACTIVE, event: "join <code>", guard: no prev_status or prev_status active}
  - {from: INVITED, to: PAUSED, event: "join <code>", guard: prev_status paused, via: [[1, 0.5], [3, 0.5]]}
  - {from: ACTIVE, to: INVITED, event: member rotate, guard: prev_status = active, via: [[2, 1.5], [1, 1.5]]}
  - {from: PAUSED, to: INVITED, event: member rotate, guard: prev_status = paused, via: [[3, 1.7], [1.2, 1.7]]}
  - {from: INVITED, to: EXPIRED, event: invite expires, guard: Worker clock}
  - {from: EXPIRED, to: INVITED, event: member invite}
  - {from: ACTIVE, to: PAUSED, event: member pause}
  - {from: PAUSED, to: ACTIVE, event: member resume}
  - {from: ACTIVE, to: OFFLINE (runtime), event: machine down, tone: gray}
  - {from: OFFLINE (runtime), to: ACTIVE, event: machine up, tone: gray}
  - {from: ACTIVE, to: LEFT, event: leave}
  - {from: INVITED, to: REMOVING, event: member rm, via: [[1, 4]]}
  - {from: EXPIRED, to: REMOVING, event: member rm, via: [[0.5, 0], [0.5, 4.2]]}
  - {from: ACTIVE, to: REMOVING, event: member rm, via: [[2.5, 1], [2.5, 4]]}
  - {from: PAUSED, to: REMOVING, event: member rm, via: [[3, 4]]}
  - {from: LEFT, to: REMOVING, event: member rm}
  - {from: REMOVING, to: REMOVED, event: "status=removed"}
  - {from: REMOVED, to: purged, event: member purge, guard: id kept in u/purged}
```

A machine link is reachable once its bytes sit under `pub/`, before its row exists, because Caddy serves the whole tree. The pointer exists only on an R2-on origin. Rev B: Caddy serves listed rows only, so PUBLISHED unlisted is no longer reachable; a member writes a v:3 pointer; the Worker enforces expiry; and a link removed by someone else becomes REVOKED, never deleted from outside.

```uml
id: sm-machine-link
type: state
title: Machine link lifecycle
level: L4
review:
  - REVOKED bytes wait for the owner's `rm` or the row's expiry. Is a row with no expiry allowed to sit REVOKED forever?
  - Should a PAUSED link count toward its row's expiry clock, or pause it too?
states:
  - {name: STAGED, initial: true, at: [0, 0]}
  - {name: POINTER, at: [1, 0]}
  - {name: REAPED, final: true, at: [2, 0]}
  - {name: PUBLISHED unlisted, at: [1, 1]}
  - {name: LISTED, at: [1, 2]}
  - {name: EXPIRED, at: [2, 2]}
  - {name: PAUSED (503), at: [0, 2], tone: gray}
  - {name: MIGRATED, final: true, at: [0, 3]}
  - {name: REVOKED, at: [1, 3], tone: rose}
  - {name: TRASHED, final: true, at: [2, 3]}
transitions:
  - {from: STAGED, to: POINTER, event: "PUT m/<id> v:2", guard: "R3 v:2, member v:3"}
  - {from: STAGED, to: PUBLISHED unlisted, event: stage_publish, guard: R2 off}
  - {from: POINTER, to: PUBLISHED unlisted, event: stage_publish}
  - {from: POINTER, to: REAPED, event: die, guard: own reconcile after 10 min}
  - {from: PUBLISHED unlisted, to: LISTED, event: row appended}
  - {from: LISTED, to: EXPIRED, event: exp passes, guard: Worker 404}
  - {from: EXPIRED, to: TRASHED, event: prune}
  - {from: LISTED, to: TRASHED, event: rm, via: [[1.5, 2], [1.5, 3]]}
  - {from: LISTED, to: MIGRATED, event: migrate --to T, via: [[1, 2.5], [0, 2.5]]}
  - {from: LISTED, to: PAUSED (503), event: member paused, tone: gray}
  - {from: PAUSED (503), to: LISTED, event: resume, tone: gray}
  - {from: LISTED, to: REVOKED, event: "rm by admin, or member rm", guard: "t/<id> + pointer deleted", tone: rose}
  - {from: REVOKED, to: TRASHED, event: "owner rm or row expiry", tone: rose}
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

The reconcile now runs on every install, origin and member, and acts on its own origin's pointers only; on a member it runs unattended in the hourly loop with the Keychain token. Two rules change: an orphan test now needs "own pointer", and tombstones `t/<id>` feed a new revoke branch. Drawn as decisions: amber boxes are tests, the other boxes are the action taken for one id.

```uml
id: sm-reconcile
type: state
title: Reconcile decision (every install, own origin)
level: L4
caption: "Decision drawn as states. Amber boxes are tests, rose deletes, green writes, violet revokes, gray changes nothing; one pass per id."
review:
  - "An own pointer with a tombstone deletes the tombstone and reports it. Is the pointer enough proof that the link is wanted?"
  - "An id reissued after a removal (other record plus a tombstone) revokes the row. Can a forged tombstone plus a forged v:1 record revoke a live link this way?"
states:
  - {name: read m/ and index, initial: true, at: [2, 0], tone: amber}
  - {name: skip (prune owns it), at: [4, 0], tone: gray}
  - {name: no local row, at: [0, 1], tone: amber}
  - {name: unexpired row, at: [3, 1], tone: amber}
  - {name: skip revoked row, at: [5, 1], tone: gray}
  - {name: delete orphan pointer, at: [0, 2], tone: rose}
  - {name: skip (add may be writing), at: [1, 2], tone: gray}
  - {name: keep, at: [2, 2], tone: gray}
  - {name: report shadowed, at: [3, 2], tone: gray}
  - {name: write missing pointer, at: [4, 2], tone: green}
  - {name: ignore other origin, at: [0, 3], tone: gray}
  - {name: delete stale tombstone, at: [2, 3], tone: rose}
  - {name: flag row revoked, at: [4, 3], tone: violet}
transitions:
  - {from: read m/ and index, to: no local row, event: "own pointer, no row", via: [[2, 0.5], [0, 0.5]]}
  - {from: read m/ and index, to: unexpired row, event: row exists, via: [[2, 0.5], [3, 0.5]]}
  - {from: read m/ and index, to: skip (prune owns it), event: row expired}
  - {from: read m/ and index, to: skip revoked row, event: row revoked, via: [[2, 0.5], [5, 0.5]]}
  - {from: read m/ and index, to: ignore other origin, event: "other origin's pointer", via: [[2, 0.5], [-0.5, 0.5], [-0.5, 3]]}
  - {from: no local row, to: delete orphan pointer, event: older than 10 min, guard: no pending line, no add lock}
  - {from: no local row, to: skip (add may be writing), event: younger than 10 min}
  - {from: unexpired row, to: keep, event: "own pointer, no t/", via: [[2.5, 1], [2.5, 2]]}
  - {from: unexpired row, to: delete stale tombstone, event: "own pointer + t/", via: [[2.5, 1], [2.5, 3]]}
  - {from: unexpired row, to: write missing pointer, event: key absent, guard: t/ absent, via: [[4, 1]]}
  - {from: unexpired row, to: flag row revoked, event: "key absent + t/", via: [[3.5, 1], [3.5, 2.5], [4, 2.5]]}
  - {from: unexpired row, to: report shadowed, event: "v:1, corrupt or v>2", guard: t/ absent}
  - {from: report shadowed, to: flag row revoked, event: "t/ present: id reissued", via: [[3, 3]]}
  - {from: write missing pointer, to: report shadowed, event: 412}
```

## Cross-cutting concepts

- One origin per tenant becomes one origin per pointer. A v:2 pointer is the tenant origin's; a v:3 pointer names its member origin. Every reconcile acts on its own origin's pointers only.
- The deploy is authoritative; the registry is a journal. Routing lives in the Worker deploy (one `M_<8hex>` binding per machine member, the `PAUSED` var). Every deploy body is rebuilt from the registry plus the marker, so no path drops a binding. Admin status flows deploy to record only; `member ls` reports drift and `member sync` repairs it.
- One write order for every member status change: record intent (`status=<verb>ing`, If-Match), then the Cloudflare change, then the record final. A die leaves an `...ing` status that the rerun resumes.
- Every admin verb takes the admin lease `lock/admin` (`If-None-Match: *`, holder and expiry inside; a stale lease is taken over with `If-Match`). Two admin shells cannot lose a binding.
- Tombstones never delete bytes. Removing someone else's link writes `t/<id>` and deletes the pointer; only the owner's own `rm` or the row's expiry deletes bytes.
- Caddy serves listed rows only: one `handle /<id>/*` per live, non-revoked row, on the origin and on members. Unlisted or revoked bytes are unreachable.
- Conditional writes in R2 (`If-None-Match: *`, `If-Match`) stay the only cross-machine concurrency control. Local symlink locks (`index`, `host`, `add-<id>`) hold within one profile on one machine.
- Publishing is the record PUT. Bytes always go to a fresh prefix `o/<id>.<nonce8>/`; nothing overwrites bytes in place, and a refresh swaps the record with `If-Match`.
- Refuse before the first write. Every multi-step setup checks all guards first, and a rerun converges, skipping each step already in place.
- The Worker fails closed for cloud ids (any doubt is 404), enforces `expires` on every pointer, and passes v:2 pointers and non-id paths to the origin unchanged.
- The admin token and the minter token live in 1Password and the environment only, never stored by share. Member tokens are minted by the tool, sealed into a one-time invite, and kept in the member's Keychain.

## Risks and technical debt

- Workers VPC is beta. Bites if Cloudflare changes the binding API, its pricing, or loopback routing to a tunnel. Mitigated by shipping members behind `--members` only, with cloud-only members as the fallback. Spike O1 passed live on a Free-plan account (VPC Service to 127.0.0.1 over a tunnel with only the 404 catch-all, no warp-routing, 150 to 350 ms).
- Every member serves under one origin. Bites if one member's page reads another member's link or cookies through same-origin script. Mitigated by stripping Access headers and cookies before a binding fetch; not by isolation.
- The bucket token cannot tell members apart. Bites if a member token leaks or a teammate errs: it can write any `u/`, `m/` or `t/` key. Mitigated by making the worst case visible and recoverable: a forged tombstone revokes a link the owner can see and re-add, a forged pointer cannot serve an unlisted or revoked row, a forged record cannot change routing. Worker-mediated writes are the upgrade before anyone outside the team publishes.
- Member tokens are user-owned (spike O2): the minter token (API Tokens Read and Write) mints them, the secret comes back once, and `expires_on` extends in place. Bites if the minting user leaves the account: every member token dies with it. Mitigated later by account-owned tokens, once a token with Account API Tokens Write exists (none does today).
- A member's connector token never expires. Bites if it leaks: another machine can join that tunnel and take a share of the requests. Mitigated by `rotate` (connections dropped first) and the "extra connector" flag in `member ls`.
- `by` is an unauthenticated `uname -n`, and any publisher may rm any cloud link. Bites if a publisher token leaks or a teammate errs. Mitigated only by ADR-0007's named-teammates rule.
- The origin's hourly prune still runs with no token. Bites as orphan pointers and expired cloud records that wait for an interactive `ls` or `prune` on the origin. Members run their reconcile unattended; the origin does not.
- A record of an unknown version blocks the orphan sweep of every CLI that cannot read it. Bites on the first new record version. Mitigated in the groundwork: records with `storage:"machine"` of any version no longer block the sweep, and `min_cli` names the floor.
- `teardown` on an R2-on origin removes the tunnel and DNS but leaves the route, Worker, pointers and marker. Bites as a half-torn tenant; refused on T2 while member records exist.
