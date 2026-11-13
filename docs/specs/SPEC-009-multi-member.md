# Spec: multi-member tenants
Generated: 2026-11-13
Status: DRAFT
Lane: full
Depth: research (outside: whether a Workers VPC tunnel binding reaches a plain-HTTP loopback Caddy from a Free-plan Worker, and whether an API token can mint account-owned R2 bucket-scoped tokens and extend their expiry) + blind-spot (failure: a multi-step admin verb that dies mid-way leaves an orphan tunnel, VPC Service, binding or token that no rerun finds)
References: `docs/briefs/DECISION-BRIEF-multi-member.md` (r2, the design this spec builds); `docs/research/2026-11-13-current-state-machines.md` (state map with line cites; imitate its step tables for every new verb); `docs/research/2026-11-13-multi-member-review-1.md` (33 findings, each folded below); `docs/research/2026-11-13-multi-member-outside.md` and `docs/research/2026-11-13-multi-member-spikes.md` (Cloudflare facts); `docs/SYSTEM-DESIGN.md` rev B (diagram ids cited in `## Design`); ADR-0007, ADR-0008, ADR-0009; `bin/share` `cmd_setup_r2` steps 0 to 14 (imitate: every refusal before the first write, every step skipped when in place), `r2_reconcile` (imitate: a 10-minute age test before deleting anything another writer may be finishing), `r2_dry` and `r2_api_dry` (extend these seams, never a new test transport).

## Problem

A tenant is one hostname (`s.console.so`) with one origin machine. Teammates can publish only cloud links (R2), and only after the admin hand-makes a bucket-scoped Cloudflare token for each in the dashboard. The owner wants four things that the code cannot do today:

| Want | Today (cite: current-state map) |
|---|---|
| A teammate shares a file that stays on their own machine, under the same hostname | One tunnel, one connector, one ingress rule; the Worker's pass-through is a plain `fetch(request)` to that one origin (L2646, L2707) |
| No new subdomain per member | `--host` and a second tunnel both need a new hostname |
| The member never opens the Cloudflare dashboard | Every publisher needs a hand-made token (ADR-0007 tokens) |
| Add, pause, rotate and remove a member and every link they own, with no half states | No registry; admin vs member is not persisted (current-state 0.2); `by` is an unauthenticated `uname -n` (L2828) |

## Terms

Delta only; TASK-4c writes each line into the repo glossary `CONTEXT.md` (created on first use).

- `member`: a person registered in the tenant's bucket registry with a `u/` record; either a machine member or a cloud member.
- `machine member`: a member whose links stay on their own machine; served by their own Caddy and cloudflared, reached by the tenant Worker through one Workers VPC Service binding.
- `cloud member`: a member who publishes cloud links only (today's R5 publisher, now registered).
- `member_id`: `m-<name>-<8 hex>`; the stable identity of a member across rotate, pause and resume; never reissued.
- `origin` (of a pointer): the field of a v:3 pointer naming the member_id whose machine serves it. A v:2 pointer's origin is the tenant origin.
- `pointer v:3`: `m/<id>` record `{v:3, storage:"machine", origin, ...}`; routes through the binding `M_<8hex>`.
- `tombstone`: `t/<id>`, written when someone other than the owner removes a machine link; tells the owner to stop serving it; never deletes bytes.
- `sealed invite`: `i/<sha256("share-invite-id:" + code)>`, an envelope holding the member's tokens encrypted under a key derived from the invite code; redeemed once through the Worker.
- `invite code`: 20 base32 characters (100 bits) shown once to the admin; the invite line is `share join <host> <code>`.
- `admin lease`: `lock/admin`, the bucket object every admin verb holds while it changes Cloudflare state.
- `minter token`: a Cloudflare user token with API Tokens Read and Write only, read from `SHARE_MINTER_TOKEN`; mints, extends and deletes member publisher tokens.
- `T0`, `T1`, `T2`: tenant states; tunnel only, R2 on, members on.
- `R7`: the member profile role, detected by config `role=member`.
- `carry-forward`: every Worker deploy reads the deployed settings and re-sends every `vpc_service` binding and `PAUSED`, then applies only the running verb's change.
- `deploy nonce`: the `DEPLOY` plain-text binding, new on every deploy, echoed by `/healthz` as `X-Share-Deploy`.

## Solution

### Approaches considered

| # | Approach | Main tradeoff |
|---|---|---|
| A | One tunnel, many connectors (each member runs a connector of the tenant tunnel) | Zero new objects, but Cloudflare spreads requests across connectors, so links fail at random (brief, Rejected) |
| B | A hidden origin hostname per member behind an Access service token | Documented and GA, but a real DNS name per member and a secret with an expiry; the owner asked for no new subdomain |
| C | One Workers VPC Service per member tunnel, bound to the tenant Worker as `M_<8hex>`; v:3 pointers name the member | One hostname, no DNS, no ingress; costs a Worker redeploy per member change and rides a beta product |
| D | A routing table the Worker reads from the bucket per request | No redeploys, but one more R2 GET per request and the bucket is member-writable, so routing would be forgeable |

### Chosen approach + why

C. Spike O1 proved it live on a Free-plan account: a Worker reached a plain-HTTP server on `127.0.0.1` through a VPC Service on a tunnel whose config holds only the 404 catch-all, with no `warp-routing`, with streaming and 151 to 354 ms of added latency (spikes O1). A trades correctness away; B trades the no-subdomain want; D trades routing integrity, because every publisher token can write every bucket key (ADR-0007). The deploy is the only routing table, and only the admin token can change it.

The credential half rides spike O2: the tool mints user-owned publisher tokens with a separate minter token, extends `expires_on` in place, and finds a half-made token by name. Account-owned tokens are the upgrade once a token with Account API Tokens Write exists (spikes O2: 403 today).

If Workers VPC regresses before GA, the fallback is the credential half alone: tool-minted tokens and redeem-once invites for cloud members, which needs no VPC object (`member add --cloud`).

### Extensibility & boundaries

- Load-bearing dimension: the number of machine members per tenant. Each adds one tunnel, one VPC Service and one binding; every member verb redeploys the whole Worker. VPC Services cap at 1,000 per account (outside 1); bindings per Worker are undocumented, so the CLI caps machine members at 20 until TASK-1a measures 25. Deploy time grows with the binding list only (one multipart PUT).
- A second dimension: links per member. Caddy renders one handle per listed row; a member with thousands of rows grows its Caddyfile linearly, the same cost the origin pays today.
- Units, each testable alone:
  - registry (`u/` read, validate, status write with If-Match);
  - lease (take, renew, release, takeover);
  - Cloudflare objects (tunnel, VPC Service, token: create, find by name, delete), each idempotent;
  - deploy builder (deployed settings plus one delta to one metadata body);
  - invite (seal, unseal, redeem contract);
  - member role (R7 detector and the 28 `r2on` sites);
  - reconcile (one decision per id, own origin only);
  - Worker v5 (routing, expiry, redeem).

### Architecture

See `## Design`.

## Picture

```
 visitor ── https://s.console.so/<id>/<file>
              │
              ▼
 Worker share-s-console-so  (route s.console.so/*, WORKER_VERSION 5)
   POST /_share/redeem  body=<64 hex> ─ claim i/<h> (onlyIf etag) ─ delete ─► 200 envelope │ 404 │ 410
   GET m/<id>
     v:1 cloud record ──────────────────────────────────────────────────────► R2 bytes (unchanged)
     v:2 pointer, unexpired ── pass() ──► tunnel CNAME ─► origin cloudflared ─► origin Caddy (listed rows)
     v:3 pointer {origin:"m-an-3f9a1c2d"}, unexpired
        origin in PAUSED ─────────────────────────────────────────────────────► 503 paused
        no binding M_3f9a1c2d ────────────────────────────────────────────────► 404
        GET/HEAD only; rewrite to http://s.console.so<path>; strip Access headers + CF_Authorization
          env.M_3f9a1c2d.fetch() ─► VPC Service ─► An's tunnel ─► An's cloudflared ─► An's Caddy 127.0.0.1:<port>
          answer without X-Share-Served, or a throw ─► 503 offline (generic)
          text/html answer ─► + Content-Security-Policy: sandbox ...
     any pointer past expires ─────────────────────────────────────────────────► 404 (new)

 admin (any machine; CLOUDFLARE_API_TOKEN, SHARE_MINTER_TOKEN)
   share member add|ls|sync|rm|purge|pause|resume|invite|rotate|renew|adopt
     │ holds lock/admin; record intent ─► Cloudflare change ─► record final
     ├─► Cloudflare API: tunnel, VPC Service, Worker deploy (carry-forward + delta), user tokens
     └─► bucket: u/, i/, t/, lock/admin, share.json

 member machine (R7, role=member)
   share join <host> <code> ─► redeem ─► Keychain (publisher + connector token) ─► Caddy + cloudflared
   share add <file> ─► m/<id> v:3 ─► pub/<id> ─► row ─► Caddy handle /<id>
   hourly loop: prune + reconcile (own origin, Keychain token) ─► revoked rows lose their handle

 bucket: share.json {members, min_cli} │ u/<member_id>.json │ u/purged.json │ i/<h> │ t/<id> │ lock/admin │ m/<id> v:1|v:2|v:3 │ o/...
```

## Design

Ordering: data models and the Worker contract first (they harden fastest), then the admin verb write orders, then the member CLI, then docs.

### Approaches considered + chosen

See `## Solution`. No new tradeoff surfaced in the design view, with one refinement recorded in the Decision Log (DEC-15): the deploy body is carried forward from the deployed settings, not rebuilt from the member-writable registry.

### Diagram

The worktree's `docs/SYSTEM-DESIGN.md` rev B carries the design as UML; this spec cites its ids and lists the deltas TASK-4c folds back in.

| Diagram id | What it shows | Delta this spec makes (fold into rev C) |
|---|---|---|
| `use-cases` | member verbs, join, leave, leave --local | `hits` stays admin and publisher only (member hits cut) |
| `components` | member lane, VPC Service, `M_<8hex>` binding | none |
| `data` | `u/`, v:3, `t/`, `i/`, `lock/admin`, marker keys | config key `member_mode`, not `mode` (DEC-11); `u/purged.json`; `i/` envelope fields (`expires`, `sealed`, `mac`); record `invite`, `rotation` fields |
| `seq-member-add` | add write order under the lease | the record notes the invite hash before the `i/` PUT (DEC-23) |
| `seq-join` | redeem, record `joining`, service, probe | tokens and config are written locally before the record write; redeem claims then deletes (DEC-21, DEC-22) |
| `seq-member-rm` | rm order | none |
| `seq-visit-member` | v:3 visitor path | no hit counted for v:3 (cut); `X-Share-Served` check; CSP sandbox on HTML |
| `seq-revoke` | admin rm of a member link and the owner's reconcile | the owner deletes a tombstone that has its own pointer only when it is older than 10 minutes |
| `sm-tenant` | T0 to T2 | none |
| `sm-member` | member lifecycle | EXPIRED is derived, never stored (DEC-19); rotate replaces the tunnel (DEC-10) |
| `sm-machine-link` | link lifecycle with REVOKED | none |
| `sm-reconcile` | reconcile decision | two new rows: young tombstone skipped; own-origin tombstone with no row deleted |
| Risks list | O2 open | O2 passed for user tokens; the risk line becomes "member tokens die if the minting user leaves the account" |

### ADR link(s)

`docs/decisions/ADR-0009-members.md` (written with this spec, Status proposed): members serve through Workers VPC behind the one hostname; the deploy is authoritative and the registry a journal; tombstones never delete bytes; the trust limit; the narrow Worker write; user-owned minted tokens; same-origin risk; Workers VPC beta behind `--members`.

### Boundaries & failure modes

Out of bounds: members never get an Access scope, a DNS record, an ingress rule or the admin token; nothing a member writes in the bucket changes routing; nothing written by anyone but the owner deletes bytes on the owner's machine. Systemic failure classes are in `## Failure modes`.

## Technical Design

### Interfaces (I/O contract)

Inputs / consumes:
- The deployed Worker settings, `GET /accounts/<a>/workers/scripts/<w>/settings`: `.result.bindings[]`, read on every deploy path to carry `vpc_service` bindings and `PAUSED` forward (shape of the `vpc_service` entry: TASK-1a(b)).
- The bucket through the S3 API (unchanged transport, ADR-0007): `share.json`, `u/`, `i/`, `t/`, `lock/admin`, `m/`, `o/`.
- The Cloudflare API with the admin token: tunnels, tunnel configurations, tunnel connections, tunnel token, Connectivity Directory services, Worker scripts. With the minter token: `/user/tokens` (list, create, update, delete, permission_groups).
- Local: config, `index.tsv`, Keychain items `share-api[.<p>]:<host>` (publisher token) and `share-tunnel[.<p>]:<host>` (connector token), the existing services.

Outputs / produces:
- The Worker v5 HTTP contract (below), relied on by `join`.
- `share state` JSON gains per-row `origin` (member name or empty) and per-profile `role`, `member_id`, `member_status`; Share Bar reads them (TASK-4b).
- `share member ls --json`: one object per member with `member_id`, `name`, `mode`, `status`, `deploy` (`bound`, `paused`), `account` (`tunnel`, `connectors`, `services`), `token_expires`, `invite_expires`, `drift[]`.

Invariants:
1. Routing changes only through a Worker deploy made with the admin token; no bucket object changes routing.
2. Every deploy body equals the deployed bindings plus exactly the running verb's delta.
3. Bytes on a machine are deleted only by that machine's own `rm`, prune of an expired row, `leave`, or `leave --local`.
4. A machine serves only rows present, unexpired and not revoked in its own `index.tsv`.
5. Every multi-step admin verb holds `lock/admin`, writes `status=<verb>ing` before its first Cloudflare change, and converges on rerun.
6. A redeemed or expired invite yields no sealed bytes again; at most one of two concurrent redeems yields them.
7. No token, code or key reaches an argv, a file outside the Keychain, or output (extends ADR-0007's rule to the minter, connector token and code).

### Data model changes

Bucket keys (all JSON; every reader validates every field before use, as `r2_take` does today):

| Key | Shape | Written by | Read by |
|---|---|---|---|
| `share.json` | `{v:1, host, aliases?, members:true, min_cli:"0.10.0"}` | `setup --r2 --members` (If-Match) | every CLI (min_cli gate, TASK-4a); join |
| `u/<member_id>.json` | `{v:1, member_id, name, mode:"machine"\|"cloud", status, prev_status?, rotation:0, tunnel_id?, tunnel_name?, vpc_service_id?, port?, token:{id, name, expires_on}, invite:{hash, expires}?, added, joined?, updated, by}`; never a secret | admin verbs (If-None-Match, then If-Match); member: `joining`, `active` (from `invited`/`joining`), `left` | admin verbs, `member ls`, join, member `status` |
| `u/purged.json` | `{v:1, ids:["m-..."]}` | `member purge` (If-Match) | member_id generation |
| `i/<64 hex>` | `{v:1, member_id, expires:<epoch>, sealed:"<base64>", mac:"<64 hex>"}` | `member add`, `invite`, `rotate` | Worker redeem only |
| `lock/admin` | `{v:1, holder:"<host>:<pid>:<nonce8>", verb, taken}`; age judged by `LastModified` | every admin verb | every admin verb |
| `m/<id>` v:3 | `{v:3, id, storage:"machine", origin, name, by, added, expires, opts, type}`; `opts` tokens `noindex` (and `live` only if TASK-3f passes) | machine member `add` (If-None-Match), own reconcile | Worker, every reader |
| `t/<id>` | `{v:1, id, origin, by, at}`; `at` display only, age by `LastModified` | admin revoke, `member rm` | owner reconcile, `member sync` sweep, `rand_id` |

Status values: stored `adding`, `invited`, `joining`, `active`, `pausing`, `paused`, `resuming`, `inviting`, `rotating`, `renewing`, `removing`, `removed`, `left`. Derived, never stored: `EXPIRED` (`invited` and `invite.expires` past), `ONLINE`/`OFFLINE` (connector count from the tunnel API).

Sealed bundle (plaintext inside `sealed`): `{v:1, host, bucket, r2_endpoint, member_id, name, mode, port?, tunnel_id?, publisher_token, connector_token?, token_expires_on}`.

Invite crypto (DEC-14; roundtrip sampled in `## Grounding`): `code` = 20 chars from the RFC 4648 base32 alphabet, from `/dev/urandom`; object id `h = sha256("share-invite-id:" + code)`; `sealed = base64(openssl enc -aes-256-cbc -pbkdf2 -iter 200000 -md sha256 -salt)` with the passphrase passed as `-pass fd:3`, never argv; `mac = HMAC-SHA256(key = sha256("share-invite-mac:" + code), sealed)`. Unseal verifies `mac` first.

Local config keys:

| Key | Profile | Meaning |
|---|---|---|
| `members=on` | origin | T2; refuses teardown, migrate, `--no-r2` |
| `role=member` | member | the R7 detector |
| `member_id` | member | own identity; the v:3 `origin` |
| `member_mode` | member | `machine` or `cloud` (`mode` already means the quick tunnel, L77) |
| `tunnel_id` | machine member | own tunnel, for `status` |

`index.tsv` rows gain the opts token `revoked` (and `revoked_by=<by>`, display only); `rows_in` accepts both, and `write_caddyfile` skips a revoked row.

### API changes

Worker v5 (`WORKER_VERSION=5`, new `WORKER_SHA`; bindings `BUCKET`, `HITS`, `HOST`, `TEAM`, `VERSION`, `SHA`, `PASS`, `ALIASES`, `PAUSED` (JSON array of member_ids, `[]` by default), `DEPLOY` (nonce), `M_<8hex>` (one `vpc_service` per machine member), secret `SALT`). Decision order (new rows marked):

| # | Condition | Answer |
|---|---|---|
| 1, 2 | alias 301; wrong Host 404 | unchanged |
| 3 (new) | path `/_share/redeem` | POST only (else 405); body exactly 64 hex (else 400); `get i/<h>`: absent 404; envelope invalid 404; `expires` past: delete, 410; `expires` more than 30 days ahead: 404 (forged); claim with `put(i/<h>, claimed, {onlyIf:{etagMatches}})`: null 404; delete; delete throws 503 (sealed bytes not returned); else 200 envelope JSON, `no-store` |
| 3b (new) | any other `/_share/*` | 404 |
| 4 | method rule, path guards | unchanged |
| 5 | `/healthz` | unchanged plus `X-Share-Deploy: <DEPLOY>` |
| 6, 7 | non-hex segment, bucket miss | PASS (unchanged) |
| 8 (new) | v:2 pointer past `expires` (`expires > 0`, server clock) | 404, no pass |
| 9 | v:2 pointer | PASS (unchanged) |
| 10 (new) | v:3: `id` matches, `origin` matches `^m-[a-z0-9-]{2,24}-[0-9a-f]{8}$`, `expires` a number; else 404 | |
| 11 (new) | v:3 past `expires` | 404 |
| 12 (new) | v:3 origin in `PAUSED` | 503, body `this link is paused by the tenant admin`, `no-store` |
| 13 (new) | v:3 binding `env["M_" + last 8 hex]` absent or not fetchable | 404 |
| 14 (new) | v:3 method not GET/HEAD | 405 |
| 15 (new) | v:3 fetch: `new Request("http://" + HOST + path + query)`, headers copied minus `cf-access-jwt-assertion`, `cf-access-authenticated-user-email`, and the `CF_Authorization` cookie; `redirect: "manual"` | throw, or no `X-Share-Served` header: 503 offline page (unchanged text, no member name); else rewrap with `no-store`, `X-Robots-Tag`, `X-Share-Served` removed, and for `text/html` or `image/svg+xml` answers `Content-Security-Policy: sandbox allow-scripts allow-forms allow-popups allow-downloads`; never counted as a hit |
| 16 | other records, cloud serving, hits | unchanged |

Cloudflare API calls added (admin token unless marked minter): tunnels `POST /accounts/<a>/cfd_tunnel` (`config_src: cloudflare`), `PUT .../cfd_tunnel/<t>/configurations` (only the `http_status:404` catch-all), `GET .../cfd_tunnel/<t>/token`, `GET .../cfd_tunnel/<t>/connections`, `DELETE .../cfd_tunnel/<t>/connections`, `DELETE .../cfd_tunnel/<t>`, `GET .../cfd_tunnel?name=<n>&is_deleted=false`; VPC Services `POST|GET|PUT|DELETE /accounts/<a>/connectivity/directory/services[/<id>]`; Worker deploy (existing multipart PUT, metadata gains `{type:"vpc_service", name:"M_<8hex>", service_id}` entries, `PAUSED`, `DEPLOY`); minter: `GET /user/tokens`, `POST /user/tokens`, `PUT /user/tokens/<id>`, `DELETE /user/tokens/<id>`, `GET /user/tokens/permission_groups`.

### UI changes

CLI verbs (admin verbs need `CLOUDFLARE_API_TOKEN` proven as admin by a settings GET 200, and take the tenant from `--tenant <host>` or the profile's `hostname`; token verbs also need `SHARE_MINTER_TOKEN`):

| Verb | Actor | Notes |
|---|---|---|
| `share version` | anyone | prints `SHARE_VERSION` |
| `share setup <h> --r2 --bucket B --members [--yes]` / `--no-members` | admin, on the origin | T1 to T2 and back |
| `share member add <name> [--machine\|--cloud] [--port P] [--invite-ttl 7d] [--token-ttl 90d]` | admin | prints the invite line once |
| `share member ls [--json]` | admin | report only; never writes |
| `share member sync [--rebind]` | admin | record repair from the deploy; expired invites and old tombstones swept |
| `share member rm <name> [--cloud-links keep\|delete]` | admin | default keep (DEC-1) |
| `share member purge <name>` | admin | REMOVED only |
| `share member pause <name>` / `resume <name>` | admin | machine links only |
| `share member invite <name> [--port P] [--invite-ttl 7d]` | admin | new code; old token and invite gone |
| `share member rotate <name>` | admin | new tunnel, service, tokens; same id and links |
| `share member renew <name> [--token-ttl 90d]` | admin | extends `expires_on` in place |
| `share member adopt <name> --token-id <id>` | admin | registers an R5 publisher as a cloud member |
| `share [--profile p] join <host> <code>`; `share join` | member | redeem; the bare form resumes a died join |
| `share leave [--local]` | member | `--local` makes no bucket call |
| `share status` (on R7) | member | record status, token expiry, Worker pair, removal detection |

Refusal lines name the next command, as today. Share Bar: rows show the member name for v:3 rows; a member profile shows its status (TASK-4b).

### Infrastructure changes

Per machine member on the tenant's Cloudflare account: tunnel `share-<host-dashes>-<8hex>[-r<n>]` (remote-managed, config = only the catch-all, no DNS), VPC Service of the same name (`type: http`, `host.ipv4: 127.0.0.1`, `host.network.tunnel_id`, `http_port: <port>`, no `https_port`), Worker binding `M_<8hex>`. Per member: user token `share <host> <member_id>` (Workers R2 Storage Bucket Item Write on `com.cloudflare.edge.r2.bucket.<acct>_default_<bucket>`, Zone Read on the zone, `expires_on`). Admin token scopes grow by Cloudflare Tunnel Edit (already used by setup) and Connectivity Directory Admin (permission-group name: TASK-1a(a)). The minter token is new (API Tokens Read and Write), a separate 1Password item.

### The 28 `r2on` sites on a machine member (review-1 finding 9)

A machine member has `backend` unset and `bucket=` set, so `r2on=1` as on the origin; the R7 detector adds `member=1` right after L79. Every site keeps its origin behavior unless the row says otherwise.

| Line | Site | Machine member behavior |
|---|---|---|
| 78, 79 | `r2on` detector | unchanged; R7 detector follows |
| 172 | `rand_id` bucket check | also refuses an id whose `t/<id>` exists (origin too) |
| 480, 484, 485 | storage choice | default storage `local`; `--cloud` allowed; `storage_default` ignored |
| 534 | `r2_token_check` | Keychain publisher token |
| 547 | `r2_pointer_put` | writes v:3 with `origin=<member_id>` |
| 574 | add lock release | unchanged |
| 589, 592 | `ls` empty and listing | unchanged |
| 638 | refresh dispatch | unchanged (cloud refresh only from the install that added it) |
| 660 | rm dispatch | no local row: cloud row by today's rule; v:3 of another origin and every v:2 refused before any call |
| 703 | interactive prune | cloud expiry, own v:3 pointer expiry, own-origin reconcile, orphan sweep on bare prune |
| 732 | hits dispatch | own machine row: its `access.log` (unchanged path); cloud row: refused naming Account Analytics Read |
| 783 | import | refused (unchanged text) |
| 960 | migrate | refused: "a member machine moves by leave and a new join" |
| 1478 | `profiles --json` | adds `role`, `member_id`, `member_status` |
| 1861 | dry log | unchanged |
| 2396 | access sweep side | skipped (members hold no Access apps) |
| 2448, 2463, 2476, 2493 | `api-token` | publisher checks kept; the "Access scopes stay required" branches skip for R7 |
| 2909 | `list_rows` bucket rows | unchanged; v:3 rows of other origins show `origin=<name>` |
| 3000 | `r2_pointer_drop` | deletes only a v:3 whose `origin` is this member_id |
| 3520 | `r2_creds` | unchanged |
| 3849 | `setup --r2` sets `r2on` | `setup` refused on R7: "this machine is a member of <host>; share leave first" |

Non-`r2on` sites that change on R7: `r2_reconcile` (own-origin filter), `cmd_serve` (hourly loop runs `prune --loop`, TASK-2c), `cmd_teardown` (refused: "use share leave"), `cmd_setup` (refused), `cmd_status` (member variant), `write_caddyfile` (main site answers `http://<host>:<port>` and loopback, as named mode does today, L1091).

### Admin verb write orders

Every admin verb: refusals and scope probes first; lease; record intent (If-Match); each Cloudflare step skipped when in place; record final; lease release. Each step below names how a rerun finds what an earlier run made.

`member add <name> --machine` (`seq-member-add`):

| # | Step | Found on rerun by |
|---|---|---|
| 0 | refuse: name `[a-z0-9-]{2,24}`; T2; cap 20; admin token scopes; minter scopes; a non-REMOVED record of this name that is not `adding`/`invited` | nothing written |
| 1 | lease | holder (same host, dead pid: immediate takeover) |
| 2 | `u/<id>.json` status=adding (If-None-Match); an `adding`/`invited` record of this name resumes with its member_id | name |
| 3 | token `share <host> <member_id>`: any found is deleted and re-minted (its secret was never sealed for a printed code) | name, via `GET /user/tokens` |
| 4 | tunnel create, config PUT (catch-all only); record `tunnel_id` | name |
| 5 | VPC Service create (`127.0.0.1`, `http_port`); record `vpc_service_id` | name |
| 6 | deploy: carry-forward plus `M_<8hex>`; wait for `X-Share-Deploy` = this nonce 3x | binding present with the same `service_id`: skip |
| 7 | record `invite: {hash, expires}` (If-Match), then delete a previous `i/` named in the record | record |
| 8 | `i/<h>` PUT (If-None-Match) | hash in record |
| 9 | record status=invited, lease release, print `share join <host> <code>` once | |

`--cloud` skips steps 4 to 6. A rerun of an `invited` record re-mints and re-invites (the code may never have been seen), so it equals `member invite`.

`join <host> <code>` (`seq-join`), on the member:

| # | Step | Die here leaves | Recovery |
|---|---|---|---|
| 0 | refuse: profile not R0; CLI below marker `min_cli`; machine: invite port busy here | nothing | |
| 1 | `POST /_share/redeem` with `h` | code spent, nothing local | admin `member invite` |
| 2 | verify `mac`, unseal; store both tokens in the Keychain; write config (`role`, `member_id`, `member_mode`, host keys) | local config, no record change | `share join` (bare) resumes |
| 3 | GET record: status `invited`, same member_id; PUT status=joining (If-Match). 412: remove local config and tokens, die "the admin changed this member during the join" | | |
| 4 | machine: write Caddyfile, install and start the service | running service | resume |
| 5 | probe: add a probe file (v:3), GET it through `https://<host>/` 3x200, rm it | probe row | resume retries; failure names `member ls` for the admin |
| 6 | record status=active, `joined` | | |

`member rm <name>` (`seq-member-rm`): lease; status=removing; deploy without `M_<8hex>` and without the id in `PAUSED`, nonce 3x; delete VPC Service (404 = done); delete tunnel connections, then the tunnel (404 = done); delete the token (404 = done); for each v:3 with this `origin`: `t/<id>` (If-None-Match; 412 = present), DELETE `m/<id>`; cloud links with `origin` this member per `--cloud-links`; delete the record's `i/`; status=removed; lease release.

`member pause` / `resume`: lease; status=pausing|resuming; deploy with the id added to or dropped from `PAUSED` (carry-forward otherwise); status=paused|active.

`member invite`: lease; status=inviting (prev kept); delete token, re-mint; machine: delete tunnel connections; `--port` updates the VPC Service (`PUT`); record invite hash; delete old `i/`; new `i/`; status=invited.

`member rotate` (DEC-10): lease; status=rotating, `prev_status` kept; `rotation+1`; new tunnel `...-r<n>` and new VPC Service of that name; deploy rebinding `M_<8hex>` to the new service (same binding name, so links and PAUSED stay); delete old connections, old service, old tunnel; delete and re-mint the token; new invite; status=`prev_status`. The member is offline until it runs `share join <host> <code>` again (join on an R7 profile with the same member_id replaces tokens in place).

`member renew`: lease; status=renewing; `PUT /user/tokens/<id>` with the same policies and the new `expires_on`; record `token.expires_on`; status back.

`member adopt <name> --token-id <id>`: refuse unless the id is in the minter's `GET /user/tokens` (made by the same user, so `rm` can revoke it) and its policy names only this bucket plus Zone Read; list the v:1 records whose `by` the admin names for confirmation (records keep `by`; `origin` is not rewritten); write `u/` status=active mode=cloud.

`member sync [--rebind]`: lease; per record, deploy wins for admin-set state: id in `PAUSED` makes the record `paused`; bound and not paused turns `paused`/`pausing` into `active`; `removing`/`removed`/`left` with a binding are reported, never changed. `--rebind`: for each VPC Service on the account named `share-<host-dashes>-<8hex>[-r<n>]` whose record is not `removing`/`removed`, re-add its binding (the account objects are admin-only, so they are a trusted source), and restore `PAUSED` from records marked paused after printing the list. Also deletes `i/` objects past expiry and tombstones of REMOVED or purged origins older than 30 days by `LastModified`.

### Reconcile (every install, own origin only)

Own pointer: on the origin, a valid v:2; on a member, a valid v:3 whose `origin` is its member_id. Rows run in this order; first match wins.

| # | Local row | `m/<id>` | `t/<id>` | Action |
|---|---|---|---|---|
| 1 | expired | any | any | skip (prune owns it) |
| 2 | revoked | any | any | nothing |
| 3 | none | own pointer, older than 10 min, no live add lock, no pending line | any | DELETE pointer |
| 4 | none | own pointer, younger | any | skip |
| 5 | none | absent | own origin | DELETE tombstone |
| 6 | none | other origin's pointer | any | nothing |
| 7 | live | own pointer | absent | nothing |
| 8 | live | own pointer | present, older than 10 min | DELETE tombstone; report "a removal of <id> by <who> did not finish or was forged" |
| 9 | live | own pointer | present, younger | skip (a revoke is in flight) |
| 10 | live | absent | present | flag row `revoked revoked_by=<by>`, re-render Caddy, DELETE tombstone, report "removed by <who>" |
| 11 | live | absent | absent | write pointer (If-None-Match); 412 goes to row 12 |
| 12 | live | other record | absent | report "shadowed; rm one of them" |
| 13 | live | other record | present | flag row revoked (the id was reissued after a removal) |

On the origin the tombstone rows (5, 8, 9, 10, 13) never fire in v1: tombstones exist only for v:3 links, and the origin ignores `t/` for its own v:2 rows (DEC-17).

## Task Breakdown

Each task lands with its tests on the existing seams. Edge-case ids name the rows each task must turn green; tests are labeled `mm <id>: ...` in `tests/share.sh` and `v5 <id>: ...` in `tests/worker.mjs`.

### Phase 0: Groundwork (helps with no members; one release, Worker v5)

Phase 0 ships before TASK-1a's samples on purpose: a T1 tenant holds no v:3 pointer, `vpc_service` binding or `i/` object, so the new Worker branches are inert until the first T2 tenant, and TASK-1a runs before that. A sample that disagrees with the documented shape lands as a Worker v6 fix in Phase 1.

- [ ] TASK-0a: CLI version constant. `SHARE_VERSION=0.9.0` near the top of `bin/share`, `share version`, and `bin/release` rewrites the constant in the release commit. AC: `share version` prints `X.Y.Z`; a suite check finds it equal to the newest `## [vX.Y.Z]` heading in `CHANGELOG.md`; OT-19.
- [ ] TASK-0b: Caddy serves listed rows only. `write_caddyfile` renders, per live non-revoked snapshot row, a matcher on `/<id>` and `/<id>/*` with `root * "$pub"` and the existing `file_server`; the catch-all `handle` answers 404; every response carries `X-Share-Served: caddy`; `rows_in` accepts `revoked` and `revoked_by=`. AC: SV-01 to SV-05; SPEC-008 compat row 1 updated to expect the new Caddyfile and nothing else.
- [ ] TASK-0c: readers. `r2_record_raw` treats any `storage:"machine"` record with no `prefix` and `v >= 2` as readable (the sweep no longer blocks); `r2_take` validates v:3 into the display rows with `origin`; the origin's reap list stays v:2; `rand_id` refuses an id with a `t/<id>`; `state` rows gain `origin`. AC: SV-06 to SV-09, OC-01, RC-14.
- [ ] TASK-0d: Worker v5, every row of `### API changes`, one version bump. `tests/worker.mjs` gains a fake `vpc_service` binding (records each request, answers from a fixture or throws) and an R2 fake honoring `onlyIf.etagMatches`. AC: SV-10 to SV-24; existing rows pass unchanged on the v5 source.
- [ ] TASK-0e: deploy carry-forward. `r2_deploy_meta` takes the deployed bindings (from the settings GET every deploy path already makes) and re-sends each `vpc_service` and `PAUSED`, plus a fresh `DEPLOY`; the deploy compare adds the binding set and `PAUSED`; `setup --force` that would lower `WORKER_VERSION` is refused while the settings carry a `vpc_service` binding or a non-empty `PAUSED`; the dry seam keeps these bindings in `script.json`; deploy waits for `X-Share-Deploy` 3x. AC: DY-01 to DY-05.

### Phase 1: Tenant, lease, registry, add, join, ls, sync

- [ ] TASK-1a: residual live samples on Console Labs, throwaway `share-e2e-*` names, cleanup asserted by name. (a) VPC Service create, get, list, update, delete over REST with an API token, and the token permission-group names that allow it; (b) a multipart deploy with a `vpc_service` binding entry, the settings GET shape of that binding, and that a deploy without it drops it; (c) the minter mints a token with Workers R2 Storage Bucket Item Write on one `share-e2e-*` bucket plus Zone Read, its S3 pair does `PUT If-None-Match`, `PUT /user/tokens/<id>` moves `expires_on`, `DELETE` revokes it; (d) the binding fetch with the member's cloudflared stopped, with Caddy stopped, and with a non-Caddy listener on the port: throw or status, and how long; (e) a deploy with 25 `vpc_service` bindings; (f) `GET .../connections` with one cloudflared: connector count vs `conns`; delete connections, then the tunnel; (g) a fresh remote-managed tunnel with only the catch-all over REST, and `GET .../token`; (h) R2 binding `put` with `onlyIf.etagMatches` on a stale etag returns null. AC: each answered in `docs/implementation-notes/multi-member.md` with the masked excerpt; (a), (b) or (c) failing stops Phase 1 and amends `## Design`; (e) failing lowers the cap to the measured value.
- [ ] TASK-1b: dry seams. `r2_api_dry` answers tunnels, configurations, connections, token, Connectivity Directory services and `/user/tokens` from state files under `.cf/`, each call one `API <METHOD> <path>` line in `r2-calls.log`, all failable through `SHARE_R2_DRY_FAIL` and `SHARE_R2_DRY_FAIL_TIMES`; `SHARE_TEST_MEMBER_IDS` and `SHARE_TEST_CODE` make ids and codes deterministic (as `SHARE_TEST_IDS`, L160); `SHARE_R2_DRY_WORKER` names a command (the suite sets `node tests/worker.mjs --dir <dry> --host <h>`) that answers dry redeem and probe requests, and `tests/worker.mjs` integration mode gains `--post <path> <body>` and `--bind M_<hex>=127.0.0.1:<port>`. AC: seam self-checks in a new `=== members: dry seams ===` section; every seam refuses outside `SHARE_TUNNEL=0` and a `.test` host, as `r2_api_dry` does (L3612).
- [ ] TASK-1c: admin context and lease. `cmd_member` dispatcher; tenant from `--tenant` or profile; admin proven by settings GET 200; bucket name from the `BUCKET` binding; marker check; minter from `SHARE_MINTER_TOKEN` only; scope probes before the first write (each missing scope named); `lease_take`, `lease_renew` before each Cloudflare step, `lease_release`, takeover rules. AC: CC-01, CC-09, CC-10, CK-01, FG-10, WM-03, MB-04, OT-16.
- [ ] TASK-1d: tenant T1 to T2 and back. `setup <h> --r2 --bucket B --members [--yes]`, `--no-members`, and the T2 refusals in teardown, migrate, `--no-r2`. AC: TN-01 to TN-09.
- [ ] TASK-1e: registry. `u/` reader and validator (a record failing validation is reported, never trusted), member_id generation unique against records, `u/purged.json`, live bindings and account services; `reg_status` (If-Match, re-read once on 412 and continue only if the new status is still valid for the verb). AC: MB-03, FG-05 to FG-07, FG-13.
- [ ] TASK-1f: `member add` (both modes), the invite seal, the step table above. AC: MB-01, MB-02, MB-05, DP-add-1 to DP-add-9, Q-SEC-6 grep of argv and logs.
- [ ] TASK-1g: R7. Detector, `member_mode`, every row of the `r2on` table, the v:3 pointer writer, member add/rm/refresh of own machine links, refusals. AC: LK-01 to LK-07, LK-16 to LK-18, WM-01, WM-02, OT-05.
- [ ] TASK-1h: `join` and its bare resume. AC: MB-06, MB-07, DP-join-1 to DP-join-6, CC-11, OT-04, OT-06.
- [ ] TASK-1i: `member ls` and `member sync` (with `--rebind`, expired-invite delete). AC: MB-08, MB-20, MB-22, MB-23, OC-03, FG-05, FG-06.

### Phase 2: rm, leave, purge, tombstones, the member reconcile loop

- [ ] TASK-2a: admin revoke. `rm <id>` on a v:3 of another origin with the admin token proven: `t/<id>` (If-None-Match), DELETE pointer, proof GET 404, message "revoked; the bytes stay on <name>'s machine"; without the admin token refused; v:2 from a non-origin refused. AC: LK-08 to LK-10, LK-19, WM-04.
- [ ] TASK-2b: reconcile, every row of the table above, and the tombstone sweep in `member sync`. AC: RC-01 to RC-14, CC-06 to CC-08, FG-01 to FG-04, FG-11, FG-14, OC-02.
- [ ] TASK-2c: member serve loop. On R7, `cmd_serve` keeps `SHARE_API_TOKEN_OFF=1` for Access and runs `share prune --loop` hourly, which resolves the publisher token from the Keychain only and runs local expiry, own pointer expiry and reconcile; a locked Keychain logs one line and skips. AC: LK-11, LK-12, OT-02, Q-OPS-1.
- [ ] TASK-2d: `member rm` and `member purge`. AC: MB-13, MB-16, DP-rm-1 to DP-rm-8, LK-15, Q-SEC-5 (dry listing of every object kind empty for the member).
- [ ] TASK-2e: `leave`, `leave --local`, member `status` removal detection. AC: MB-14, MB-15, MB-21, DP-leave-1 to DP-leave-3, OT-03.

### Phase 3: pause, resume, rotate, invite, renew, adopt

- [ ] TASK-3a: `pause`, `resume`. AC: MB-10, MB-11, LK-14, CC-02, DP-pause-1, DP-pause-2.
- [ ] TASK-3b: `member invite`. AC: MB-09, DP-invite-1 to DP-invite-3.
- [ ] TASK-3c: `rotate`. AC: MB-12, DP-rotate-1 to DP-rotate-4, CC-03, OT-14.
- [ ] TASK-3d: `renew` and expiry warnings. AC: MB-18, MB-19, CK-04.
- [ ] TASK-3e: `adopt`. AC: MB-17, OC-07.
- [ ] TASK-3f: WebSocket and streaming through the binding (live, Console Labs). Pass: member `add <port>` renders `handle_path /<id>/*` to the port, the Worker forwards an `Upgrade` request for a v:3 `live` pointer and returns the 101 untouched, and `live` joins the v:3 opts; fail: the refusal stays and the result is recorded. AC: LK-02 in the branch taken; the live result in the implementation notes.

### Phase 4: min_cli, Share Bar, docs, live acceptance

- [ ] TASK-4a: `min_cli` enforcement. Every bucket write on a v0.10+ CLI reads the marker once per process; below `min_cli` it refuses writes ("upgrade share to <min_cli>; <host> requires it") and allows reads. AC: OC-04, FG-09.
- [ ] TASK-4b: Share Bar. Decode `origin`, `role`, `member_id`, `member_status`; rows show the member name; a member profile shows its status. AC: `swift test --package-path mac` rows for each field present and absent; `swift build` passes.
- [ ] TASK-4c: docs. README, `docs/how-it-works.md`, `docs/setup.md` (member onboarding: one pasted line), `docs/SYSTEM-DESIGN.md` rev C as built (the delta table in `## Design`), ADR-0009 accepted, glossary `CONTEXT.md`, `docs/QUALITY.md` with the Q- entries. AC: the existing docs grep (`tests/share.sh` "tenant docs" section) extended to every member verb, flag and config key named here.
- [ ] TASK-4d: `tests/e2e-members.sh`, the live legs in `## Verification`, refusing any hostname, bucket, tunnel, service or token name without the `share-e2e-` prefix, with an EXIT trap that deletes by name and prints each leftover. AC: ML-1 to ML-12 green twice in a row.
- [ ] TASK-4e: STOP for Han, then the live acceptance on `s.console.so` with the owner's second machine as the first member (DEC-3), and `docs/verification/multi-member.md` with each negative control's red and green run. AC: every `## After state` item checked.

Task count: Phase 0: 5; Phase 1: 9; Phase 2: 5; Phase 3: 6; Phase 4: 5 (30).

## After state

- [ ] `share member add an --machine` on a T2 tenant prints one `share join s.console.so <code>` line; nobody opens the Cloudflare dashboard. (Today: the admin hand-makes a token in the dashboard.)
- [ ] On the member machine, `share join s.console.so <code>` ends with `joined as m-an-<8hex>`, and `share add f.pdf` prints `https://s.console.so/<id>/f.pdf`, which answers 200 while the file never leaves that machine. (Today: a member can publish cloud links only.)
- [ ] A second `share join` with the same code answers "this invite was already used or never existed". (Today: no invites.)
- [ ] `share member pause an` makes An's machine links answer 503 within the verb; `resume` restores 200.
- [ ] `share member rm an` leaves no tunnel, VPC Service, `M_<8hex>` binding, token, `i/` object or v:3 pointer of An, checked by `tests/e2e-members.sh` listings by name. (Today: no member objects exist.)
- [ ] An origin with R2 off or on and no members serves exactly as before, except that `curl http://127.0.0.1:<port>/<unlisted id>/x` answers 404. (Today: 200, the whole `pub/` tree is served, L1127.)
- [ ] A v0.9 `share` on a T2 tenant lists, adds and removes cloud links, and never deletes or mis-serves a member link.
- [ ] `node tests/worker.mjs` and `bash tests/share.sh` pass on Linux and macOS CI with every `mm` and `v5` row.

## Quality requirements

No `docs/QUALITY.md` exists in the worktree; TASK-4c creates it with these entries (full text in `QUALITY-additions.md`). All are new.

- Q-SEC-1 (new): forged bucket writes never delete bytes on another machine. Tested by: RC-08, RC-10, FG-01, FG-02; negative control NC-1.
- Q-SEC-2 (new): forged bucket writes never serve an unlisted or revoked row and never change routing. Tested by: SV-01, FG-03 to FG-07; NC-2, NC-9.
- Q-SEC-3 (new): an invite yields its sealed bytes at most once. Tested by: SV-14 to SV-18, CC-11; NC-5.
- Q-SEC-4 (new): Access credentials never reach a member machine. Tested by: SV-21; ML-7; NC-4.
- Q-SEC-5 (new): `member rm` leaves zero objects of the member. Tested by: MB-13, ML-11; NC-10.
- Q-SEC-6 (new): no token, key or code in argv, files or output. Tested by: TASK-1f argv and log grep; existing "live transport, retries, secrets" section extended.
- Q-REL-1 (new): every multi-step admin verb converges after a die at any step with zero orphans. Tested by: every DP- row.
- Q-REL-2 (new): concurrent admin verbs lose no binding and no pause. Tested by: CC-01, CC-02; NC-7.
- Q-REL-3 (new): every deploy path keeps every member binding and `PAUSED`. Tested by: DY-01 to DY-04; NC-6.
- Q-AVAIL-1 (new): a member link adds at most 400 ms p50 and 800 ms p95 over 20 GETs. Tested by: ML-6.
- Q-AVAIL-2 (new): a routing change is live when the verb exits. Tested by: DY-05, ML-8.
- Q-AVAIL-3 (new): a member machine down leaves origin and cloud links unaffected. Tested by: OT-01, ML-9.
- Q-COMPAT-1 (new): a tenant with no members behaves as before except unlisted bytes. Tested by: SV-01 to SV-05, SPEC-008 compat row 1.
- Q-COMPAT-2 (new): an older CLI or Worker fails closed on member records. Tested by: OC-01 to OC-06.
- Q-COST-1 (new): one bucket read per visitor request for a v:3 link and no new read for v:1 or v:2. Tested by: SV-24.
- Q-SCALE-1 (new): 20 machine members per tenant deploy and route. Tested by: TASK-1a(e), DY-04.
- Q-OPS-1 (new): a revoked link 404s at once and loses its Caddy handle within one hourly loop. Tested by: LK-11, ML-10.

## Acceptance Criteria

- [ ] All 30 tasks pass their individual acceptance criteria.
- [ ] Every row of the brief's state tables (tenant, member, link, reconcile, who may) has a named passing test (Edge Cases TN, MB, LK, RC, WM).
- [ ] Every die point has a convergence test (DP rows) that asserts no orphan tunnel, VPC Service, binding, token, invite or pointer.
- [ ] Every negative control in `## Grounding` has a recorded red run and green run in `docs/verification/multi-member.md`.
- [ ] Live acceptance passes on `s.console.so` with two machines; a member reaches ACTIVE from a code alone.
- [ ] No regression: every existing `tests/share.sh` and `tests/worker.mjs` row passes, SPEC-008 compat row 1 changed only for the Caddyfile.

## Verification

```sh
shellcheck bin/share install.sh tests/share.sh tests/e2e.sh tests/e2e-r2.sh tests/e2e-tenant.sh tests/e2e-members.sh demo/render.sh mac/*.sh
/bin/bash -n bin/share
bash tests/share.sh            # every section, including the new `=== members: ... ===` sections and node tests/worker.mjs
node tests/worker.mjs          # the v5 rows on their own
swift test --package-path mac
bash mac/build.sh 0.0.0
```

CI runs `bash tests/share.sh` on `ubuntu-latest` and `macos-latest` (`.github/workflows/ci.yml`); macOS `/bin/bash` 3.2 must parse `bin/share` (CLAUDE.md).

By hand, with Console Labs credentials from 1Password (never in argv): `tests/e2e-members.sh`, then TASK-4e on `s.console.so`. Live legs:

| # | Step | Assert |
|---|---|---|
| ML-1 | throwaway T1 tenant `share-e2e-*` on origin A; `setup --r2 --members` | marker `members:true`, `min_cli`; Worker v5 pair; `PAUSED` `[]` |
| ML-2 | `member add m1 --machine` | one invite line; tunnel, service, binding, token exist by name |
| ML-3 | member HOME B (second machine, or a second HOME on A with its own cloudflared): `join` | ACTIVE; probe 3x200 |
| ML-4 | B `add` a PDF, an HTML file, a folder | 200 each through the Worker; HTML carries the CSP sandbox, the PDF does not and renders |
| ML-5 | B `refresh`, `rm`; A `ls` | shared list shows B's rows with `origin=m1`; rm 404 at once |
| ML-6 | 20 GETs of a B link and of an A link | p50 and p95 of the difference within Q-AVAIL-1 |
| ML-7 | gated link on A (admin), then GET a B link with the Access cookie and a forged `cf-access-jwt-assertion` header | B's Caddy access log holds neither |
| ML-8 | `pause m1`, `resume m1` | 503 at verb exit, 200 at verb exit |
| ML-9 | stop B's cloudflared | B links 503 offline page; A and cloud links 200; `member ls` connectors 0 |
| ML-10 | A admin `rm` of a B link | 404 at once; B's handle dropped at its next loop (forced with `share prune --loop`) |
| ML-11 | `member rm m1`, then B `status`, `leave --local` | listings by name empty; B reports removed; B's service gone |
| ML-12 | `--no-members`, admin purge, teardown | no `share-e2e-*` object of any kind remains |

## Edge Cases

A full scenario pass. Test file: `tests/share.sh` unless marked `worker.mjs` or live (`e2e-members`).

### Tenant (brief tenant table)

| # | Scenario | Expected |
|---|---|---|
| TN-01 | T1 `setup --r2 --bucket B --members --yes` | log order: settings GET < scope probes < services list probe < lease PUT < deploy (v5, `PAUSED` `[]`) < healthz nonce 3x < marker PUT If-Match < config `members=on` < lease DELETE |
| TN-02 | each guard fails: a missing scope (each named), services list 403, a local row without its pointer, marker names another host, no TTY and no `--yes` for the min_cli confirmation | dies before any PUT, POST or DELETE |
| TN-03 | rerun on T2 | no marker PUT, deploy skipped when equal, exit 0 |
| TN-04 | `--no-members` with a record not REMOVED | refused naming the member |
| TN-05 | `--no-members` with every record REMOVED or purged | marker keys dropped (If-Match); deploy without `PAUSED` and with no binding; config key dropped |
| TN-06 | `--no-r2` on T2 | refused "--no-members first" |
| TN-07 | `teardown` on a T2 origin with records; `migrate` | refused before any change |
| TN-08 | `setup --r2` rerun and `--alias` on T2 | bindings and `PAUSED` carried (DY-01) |
| TN-09 | die after the deploy, after the marker, before config | rerun converges; a dead same-host lease is taken over at once |

### Member (brief member table)

| # | Scenario | Expected |
|---|---|---|
| MB-01 | `member add an --machine` | DP-add steps in order; record `invited` with `tunnel_id`, `vpc_service_id`, `token.id`, `invite.hash`; one invite line |
| MB-02 | `member add bo --cloud` | no tunnel, service or deploy calls; record `invited` mode cloud |
| MB-03 | name `A_n`, a 25-char name, a name held by an active record | refused before any write; an `adding` or `invited` record of the same name resumes with its member_id |
| MB-04 | `SHARE_MINTER_TOKEN` unset; minter lacking API Tokens Write; admin lacking Connectivity Directory Admin | refused before the lease |
| MB-05 | 21st machine member | refused naming the cap |
| MB-06 | `join s.console.so <code>` | DP-join steps; record `active` with `joined`; config `role=member` |
| MB-07 | join refusals: CLI below `min_cli`; redeem 404; redeem 410; record not `invited` or member_id differs; port busy; profile not R0; `mac` mismatch | each dies; nothing local remains except after a 200 redeem with a later refusal, which removes its own config and tokens |
| MB-08 | INVITED past `invite.expires` | `member ls` shows EXPIRED; `member sync` deletes the `i/` object |
| MB-09 | `member invite an` from INVITED and from EXPIRED, with `--port 8801` | old token deleted, connections deleted, new token, service port updated, old `i/` deleted, new `i/`, new code |
| MB-10 | `member pause an` | record `paused`; `PAUSED` holds an; v:3 503; an's cloud links 200; an's CLI refuses `add` |
| MB-11 | `member resume an` | record `active`; `PAUSED` without an; v:3 200 |
| MB-12 | `member rotate an` from ACTIVE and from PAUSED | new tunnel and service `-r1`; binding `M_<8hex>` names the new service; old ones deleted; record back to its status; a PAUSED member stays paused |
| MB-13 | `member rm` from INVITED, EXPIRED, ACTIVE, PAUSED, LEFT, and from each `...ing` | REMOVED; v:3 pointers tombstoned; cloud links kept (or deleted with `--cloud-links delete`); no object left |
| MB-14 | `leave` on ACTIVE | own links rm'd (pointer, then bytes); service uninstalled; record `left` (If-Match); tokens forgotten; config dropped |
| MB-15 | `leave --local` | `r2-calls.log` has no line; service gone; tokens forgotten; rows and `pub/` moved to trash |
| MB-16 | `member purge` on REMOVED; on ACTIVE | record deleted and id in `u/purged.json`; refused |
| MB-17 | `adopt bo --token-id <id>`: own user's bucket-scoped token; another user's token; an account-wide token | ACTIVE cloud; refused; refused |
| MB-18 | `renew an --token-ttl 90d` | `PUT /user/tokens/<id>` with the same policies; token id unchanged; the member keeps working |
| MB-19 | token expiry 14 days away | `status` on the member and `member ls` warn |
| MB-20 | two connectors on a member tunnel | `member ls` flags "extra connector: rotate now" |
| MB-21 | member removed while asleep, then `status` | verify 401 or record `removed`: "this machine was removed from <host>; share leave --local" |
| MB-22 | record `active` while `PAUSED` holds the id; record `removed` while bound | `member ls` prints two drift lines, writes nothing |
| MB-23 | `member sync` on MB-22's state | record becomes `paused`; the removed-but-bound case is reported, not changed |

### Link (brief link table)

| # | Scenario | Expected |
|---|---|---|
| LK-01 | machine member `add f` | `PUT m/<id>` v:3 If-None-Match under the `add-<id>` lock, before `pub/<id>`; row; Caddy handle |
| LK-02 | member `add 3000` | v1: refused before any write; TASK-3f pass: live row, Worker forwards GET and the upgrade |
| LK-03 | member `add --cloud f` | v:1 with `origin` |
| LK-04 | member `add --access ...` | refused "gated links are added by the admin" |
| LK-05 | member `add --host ...` | refused |
| LK-06 | member `refresh` own row | re-copy, no S3 write |
| LK-07 | member `rm` own row | own v:3 DELETE, proof GET 404, bytes and row trashed |
| LK-08 | admin `rm` of a v:3 | `PUT t/<id>` If-None-Match, then `DELETE m/<id>`, proof GET 404 |
| LK-09 | member `rm` of another member's v:3 | refused before any call |
| LK-10 | any publisher `rm` of a cloud link | today's path |
| LK-11 | owner loop after LK-08 | row `revoked`, handle gone, `t/` deleted, `ls` shows "removed by <who>" |
| LK-12 | link past `expires` | Worker 404 at once; owner's loop trashes the row |
| LK-13 | member machine down | generic 503 offline page |
| LK-14 | member paused, then resumed | 503 paused, then 200 |
| LK-15 | `member rm` while the machine never returns | every v:3 tombstoned; bytes wait for `leave --local` |
| LK-16 | add dies after the pointer PUT | own reconcile deletes the pointer after 10 minutes |
| LK-17 | pointer PUT 412 | new id, up to 5 tries |
| LK-18 | an id with a `t/<id>` | never picked |
| LK-19 | admin `rm` of a v:2 from a machine that is not the origin | refused "served by the tenant's origin; remove it there" |

### Reconcile

RC-01 to RC-13 are rows 1 to 13 of the reconcile table, one test each, run on a member HOME with fixtures aged by the suite's `aged` helper. RC-14: on the origin, a v:3 pointer of any age, with or without a local row of the same id, is never deleted (the origin's reap list stays v:2).

### Who may

| # | Scenario | Expected |
|---|---|---|
| WM-01 | paused, left or removed member `add` | refused before any write |
| WM-02 | member `member add` (no admin token) | refused "needs the tenant admin token" |
| WM-03 | origin without the admin token runs a member verb | settings GET 403: refused |
| WM-04 | origin without the admin token `rm` of a v:3 | refused, naming the admin |

### Die points (kill or fail injection after each step, then rerun)

Kill: `SHARE_R2_DRY_PAUSE="<METHOD> <key>"` holds the call, the test sends `kill -9`, then reruns. Fail: `SHARE_R2_DRY_FAIL` on the next call. After each rerun the test asserts the end state of the happy row and an empty orphan listing.

| # | Die after | Rerun |
|---|---|---|
| DP-add-1 | lease PUT | same-host dead holder taken over |
| DP-add-2 | record `adding` | resumes with the same member_id |
| DP-add-3 | token mint, before the record notes it | found by name, deleted, re-minted (one token remains) |
| DP-add-4 | tunnel create | found by name; one tunnel |
| DP-add-5 | service create | found by name; one service |
| DP-add-6 | deploy | binding present: skipped |
| DP-add-7 | record notes the invite hash | old `i/` (none) skipped; new `i/` |
| DP-add-8 | `i/` PUT, before `invited` | old `i/` deleted by hash; one `i/` remains |
| DP-add-9 | `invited`, before the code prints | re-mint and re-invite; the first code's `i/` is gone |
| DP-join-1 | redeem 200, before the Keychain | code spent; `member invite` path tested end to end |
| DP-join-2 | tokens and config | bare `share join` resumes |
| DP-join-3 | record `joining` 412 | local config and tokens removed |
| DP-join-4 | service start | resume probes |
| DP-join-5 | probe fails | record stays `joining`; message names `member ls` |
| DP-join-6 | record `active` write fails | resume writes it |
| DP-rm-1 to DP-rm-8 | lease, `removing`, deploy, service delete, connections, tunnel delete, token delete, tombstones | each rerun skips done steps (404 = done) and ends REMOVED |
| DP-pause-1, -2 | `pausing`; deploy | rerun completes; record equals deploy |
| DP-invite-1 to -3 | token delete; connections; `i/` PUT | one token, one `i/` |
| DP-rotate-1 to -4 | new tunnel; new service; deploy; old deletes | one tunnel, one service, binding on the new service |
| DP-leave-1 to -3 | half the links rm'd; service uninstall; record `left` | rerun finishes local cleanup |

### Concurrency

| # | Scenario | Expected |
|---|---|---|
| CC-01 | `member add an` held at `PUT i/<h>`; `member add bo` starts | bo waits up to 60 s, then refuses "lease held by <holder>"; after an finishes, bo succeeds; both bindings deployed |
| CC-02 | pause and resume from two shells | serialized by the lease; record equals deploy |
| CC-03 | join while `rotate` runs | one If-Match loses; a losing join rolls back; a losing rotate re-reads once |
| CC-04 | join while `member rm` runs | rm wins from any state; the member's probe fails; `status` reports removed |
| CC-05 | two machines add the same id | If-None-Match: one gets 412 and a new id |
| CC-06 | admin revoke racing the owner's reconcile | reconcile row 9 skips the young tombstone; no resurrection |
| CC-07 | owner `rm` racing admin revoke | the leftover tombstone is deleted by row 5 |
| CC-08 | the member loop racing the member's own add | add lock and the 10-minute rule keep the pointer |
| CC-09 | lease holder killed on another host | takeover after `LastModified` + 900 s |
| CC-10 | two takers of one stale lease | If-Match: one wins |
| CC-11 | two redeems of one code at once (`worker.mjs`, interleaved `get`) | exactly one 200 |
| CC-12 | admin verbs for two different members, sequential | independent; both bindings |

### Clock skew

| # | Scenario | Expected |
|---|---|---|
| CK-01 | lease holder clock 2 h ahead | staleness by `LastModified`, holder content ignored |
| CK-02 | remover clock 40 days fast | tombstone age by `LastModified`; never swept early |
| CK-03 | admin clock fast by 1 day at invite | expiry shifts by the skew only; an envelope more than 30 days ahead is refused by the Worker |
| CK-04 | member clock wrong | token expiry from the server's `expires_on`; warning text only |
| CK-05 | owner clock skew vs Worker | link expires at the owner's intended moment plus the skew; owner prune uses the same clock |
| CK-06 | 10-minute tests | local clock vs `LastModified`, as today (L2969) |

### Old CLIs and Workers

| # | Scenario | Expected |
|---|---|---|
| OC-01 | a v0.9 CLI on a bucket with v:3 pointers | hidden from its `ls`; never reaped (`r2_take` keeps `v == 2`, L3265); its `rm <id>` says no share; its orphan sweep is skipped with a warning (known, named in the T1 to T2 confirmation) |
| OC-02 | a v0.9 publisher draws a tombstoned id for a cloud link | owner reconcile row 13 revokes the row; bytes stay |
| OC-03 | a v0.9 admin `setup --r2 --force` on T2 | Worker v4: v:3 answers 404 (fail closed); `member sync --rebind` restores bindings |
| OC-04 | a v0.10 CLI below a later `min_cli` | writes refused, reads allowed |
| OC-05 | Worker v4 with a v:3 pointer | 404 (T2 requires v5) |
| OC-06 | an older Share Bar reads the new state JSON | extra keys ignored |
| OC-07 | a v0.9 teammate joins a T2 tenant with `setup --backend r2` | works as an unregistered cloud publisher; `adopt` optional |

### Forged records

| # | Scenario | Expected |
|---|---|---|
| FG-01 | forged `t/` on a live v:3 with its pointer | after 10 minutes the owner deletes it and reports; the link serves throughout |
| FG-02 | forged `t/` plus pointer delete | revoked, 404; bytes kept; owner sees "removed by <who>" |
| FG-03 | forged v:3 for an unlisted or revoked row | that member's Caddy 404s |
| FG-04 | forged v:3 naming member B for an id B never added | B's Caddy 404s; the real owner's reconcile reports "shadowed" |
| FG-05 | forged `u/` status `active` for a paused member | `PAUSED` unchanged by any later verb; drift reported |
| FG-06 | forged `u/` status `removed` for an active member | binding stays; drift reported |
| FG-07 | forged `u/` for a member that never existed | no binding (no VPC Service exists); `member ls` reports it |
| FG-08 | forged `i/` envelope | `mac` fails; join dies "invite tampered" |
| FG-09 | forged marker `min_cli: 99.0.0` | writes refused; admin repairs with `setup --members` rerun |
| FG-10 | forged `lock/admin` with a far `expires` | ignored; age by `LastModified` |
| FG-11 | forged v:3 with `expires: 0` for an expired row | the owner's prune already trashed the row; 404 |
| FG-12 | forged v:3 `origin` `m-x-../` or a non-hex suffix (`worker.mjs`) | 404 |
| FG-13 | forged `u/purged.json` drops an id | new ids also checked against bindings and services |
| FG-14 | forged `t/` for an origin v:2 link | the origin ignores it; a deleted pointer is rewritten by the origin's reconcile; the Worker passes the miss to the origin meanwhile |

### Serving and Worker

| # | Scenario | Expected |
|---|---|---|
| SV-01 | `pub/<id>` with no row | 404 |
| SV-02 | listed snapshot `/<id>/`, `/<id>`, `/<id>/f` | 200, the folder redirect, 200 |
| SV-03 | revoked row | 404 |
| SV-04 | live row and `--host` row | unchanged |
| SV-05 | every Caddy answer | carries `X-Share-Served: caddy` |
| SV-06 | sweep with a v:3 present | not blocked |
| SV-07 | `ls` and `state` with v:3 rows | `origin` shown |
| SV-08 | malformed v:3 (bad origin, tab in name) | skipped as a forged row |
| SV-09 | `rand_id` with `t/<id>` | id skipped |
| SV-10 (worker.mjs) | expired v:2 | 404, no pass |
| SV-11 | v:3 bound, unexpired | request reaches the fake binding as `http://HOST/path?q` |
| SV-12 | v:3 origin in `PAUSED` | 503 paused, no binding call |
| SV-13 | v:3 with no binding | 404 |
| SV-14 | redeem fresh | 200 envelope; object gone |
| SV-15 | redeem twice | second 404 |
| SV-16 | redeem expired | 410; object gone |
| SV-17 | redeem with the claim put returning null | 404 |
| SV-18 | redeem with delete throwing | 503; envelope not returned; object still claimed |
| SV-19 | redeem GET, bad body, other `/_share/x` | 405, 400, 404 |
| SV-20 | v:3 POST | 405 |
| SV-21 | v:3 with `cf-access-jwt-assertion`, `cf-access-authenticated-user-email`, cookie `a=1; CF_Authorization=x` | binding sees none of the three, sees `a=1` |
| SV-22 | binding answer without `X-Share-Served`; binding throws | 503 offline page each |
| SV-23 | binding answers `text/html`; `application/pdf` | CSP sandbox on the first only; `X-Share-Served` removed |
| SV-24 | count `BUCKET.get` per request for v:1, v:2, v:3 | 2, 1, 1 (unchanged for v:1 and v:2) |

### Deploy

| # | Scenario | Expected |
|---|---|---|
| DY-01 | `setup --r2` rerun after a CLI bump with two bindings and `PAUSED` `["m-an-..."]` deployed | new `script.json` holds both bindings and the same `PAUSED` |
| DY-02 | `--alias` fold on T2 | same |
| DY-03 | `setup --force` lowering the version with a binding present | refused |
| DY-04 | 20 bindings in the dry deploy | one metadata body, every binding present |
| DY-05 | deploy returns 200 but healthz shows the old nonce | the verb waits; after `SHARE_R2_WAIT` it dies naming the rerun |

### Other

| # | Scenario | Expected |
|---|---|---|
| OT-01 | member machine sleeps | v:3 503; origin and cloud links unaffected; `member ls` connectors 0 |
| OT-02 | member Keychain locked under launchd | the loop logs one line and skips; serving continues |
| OT-03 | member removed while offline, comes back | cloudflared fails to connect (tunnel gone); `status` says removed; `leave --local` cleans |
| OT-04 | invite port busy on the member | refused with "ask the admin: share member invite <name> --port <free port>" |
| OT-05 | member profile beside another tenant's origin profile | named profile; ports checked across profiles |
| OT-06 | the owner's second machine joins its own tenant | works; admin verbs run from it with the env token |
| OT-07 | bucket read of `m/` fails in the Worker | pass to the origin (unchanged); member ids 404 there |
| OT-08 | `member add` while the Worker deploy hits a Cloudflare 5xx | `r2_api_retry` 3 tries, then die; rerun converges |
| OT-09 | two tenants on one account | names carry the host; no collision |
| OT-10 | minting user leaves the account | members get 401; `rotate` with a new minter recovers each |
| OT-11 | `member rm` of a member with no links | completes; no tombstone |
| OT-12 | a member with 500 rows | Caddyfile renders 500 handles; reload succeeds |
| OT-13 | `X-Share-Served` on an origin pass | removed by the Worker |
| OT-14 | leaked connector token runs a replica | `member ls` flags extra connector; `rotate` deletes the tunnel, so the replica stops |
| OT-15 | admin verb without `--tenant` on a machine with no profile | refused naming `--tenant` |
| OT-16 | admin token lacks Connectivity Directory Admin | refused before any write |
| OT-17 | member's cloud links after `rm` (DEC-1) | keep serving until `expires`; `--cloud-links delete` removes them |
| OT-18 | redeem by a scanner with random hashes | 404 each, one R2 read each |
| OT-19 | `share version` | equals the newest CHANGELOG heading |

## Failure modes

| Failure class | Detection signal | Mitigation / recovery |
|---|---|---|
| Workers VPC beta changes its API or loopback routing | `member add` deploy or VPC call fails; ML legs red | Members ship behind `--members` only; `--no-members` rollback; cloud members (the credential half) need no VPC object |
| Cloudflare API outage mid-verb | non-2xx after `r2_api_retry` | Die with the record in `...ing`; rerun resumes |
| R2 outage | S3 5xx | Admin verbs refuse before Cloudflare changes (lease needs R2); Worker passes misses to the origin |
| Deploy propagation lag | `X-Share-Deploy` not seen 3x | Verb waits up to `SHARE_R2_WAIT`, then names the rerun |
| A publisher token forges bucket objects | reconcile reports, `member ls` drift | No forged write changes routing or deletes bytes (invariants 1, 3); revoked links are visible and re-addable |
| Leaked invite code | second redeem 404 | One-time redeem; `member invite` re-issues |
| Leaked connector token | connectors above 1 | `rotate` replaces the tunnel |
| Leaked member publisher token | unexpected writes in `ls` | `member rm` or `rotate` deletes it; the trust limit holds until Worker-mediated writes (ADR-0009) |
| Minting user leaves the account | 401 on every member token | `rotate` each member with a new minter; account-owned tokens are the upgrade |
| A member's HTML reads another link | n/a (browser-side) | CSP sandbox on member HTML; named teammates only (ADR-0009) |
| A v0.9 admin downgrades the Worker with `--force` | v:3 links 404 | `member sync --rebind` from account services |
| Bindings-per-Worker limit lower than 20 | deploy 4xx in TASK-1a(e) | Cap lowered to the measured value |
| Member Keychain locked | loop log line | Reconcile waits for the next unlocked loop; Worker already 404s revoked links |

## Out of Scope

- `member move` (rm and re-add, or rotate on the new machine, covers it), an `edit` verb, `teardown --cascade`, gated links added by members, member `hits` and Worker hit counting for v:3, a public per-member health leg (DEC-5).
- Live port shares by members, unless TASK-3f proves WebSocket through the binding (DEC-8).
- `--host` for members (needs DNS and ingress).
- Account-owned member tokens (no token with Account API Tokens Write today; spikes O2).
- Worker-mediated publisher writes with tool keys (plan B), the upgrade before anyone outside the team publishes (ADR-0009).
- Revoking an origin v:2 link from a non-origin machine (DEC-17).
- Moving an R2-on or T2 origin between machines (ADR-0008 already refuses R3).

## Decision Log

- DEC-1: A removed member's cloud links stay until they expire (`member rm --cloud-links keep` is the default; `delete` exists). Owner decision. Rejected: delete by default (a removal would break links people already hold).
- DEC-2: Workers VPC beta is accepted behind `--members`. Owner decision. Rejected: wait for GA (no date); plan B now (a write path in the Worker).
- DEC-3: The first live member is a second machine of the owner's. Owner decision. Rejected: a teammate's server first (a failure would land on someone else).
- DEC-4: The Worker gains one narrow write on redeem: only keys `i/<64 hex>`; a conditional claim (`put` with `onlyIf.etagMatches`) then a delete. Owner decision (delete on redeem); the claim refines it so two concurrent redeems cannot both succeed (CC-11). Rejected: an invite blob sent over 1Password (stays valid forever; the connector token never expires).
- DEC-5: Cut from v1: member move, edit verb, teardown --cascade, member gated links, member hits. Owner decision.
- DEC-6: Spike O1 passed: VPC Service to `127.0.0.1`, tunnel config only the catch-all, no `warp-routing`, Free plan; the binding forwards request headers, so the Worker strips Access headers itself. Rejected: `cf1:network` with private hostname routes (undocumented for loopback).
- DEC-7: Spike O2 passed for user tokens: v1 mints user-owned tokens with a separate minter token (API Tokens Read and Write, env `SHARE_MINTER_TOKEN`, never stored). Account-owned later. Rejected: granting API Tokens Write to the admin token (it would mint any token its user holds; review-1 finding 15).
- DEC-8: WebSocket through the binding is untested, so member live port shares stay out of v1 unless TASK-3f proves them.
- DEC-9: Spikes are done; TASK-1a samples only the shapes the spikes did not reach (REST VPC calls with an API token, the REST binding entry, a bucket-scoped mint, down behavior, binding count, connections shape, the claim).
- DEC-10: `rotate` replaces the tunnel and VPC Service and rebinds the same `M_<8hex>`, because no documented API rotates a tunnel token (outside 4: dashboard only). Rejected: `PATCH tunnel_secret` (undocumented).
- DEC-11: The member config key is `member_mode`, because `mode` already means the quick tunnel (L77).
- DEC-12: `SHARE_VERSION` is new; `min_cli` binds v0.10 and later only; v0.9 publishers are covered by the owner's confirmation at T1 to T2.
- DEC-13: Member HTML and SVG answers carry `Content-Security-Policy: sandbox allow-scripts allow-forms allow-popups allow-downloads` (no `allow-same-origin`), so a member's page cannot read other links with the visitor's cookies; PDFs and other types are untouched (a sandboxed PDF viewer may refuse to load). Rejected: per-member subdomains (the owner wants one hostname); no mitigation (review-1 finding 17).
- DEC-14: Invite crypto: 100-bit code, domain-separated sha256 for the object id and the MAC key, AES-256-CBC with PBKDF2-SHA256 200,000 iterations, encrypt then MAC; passphrase on a file descriptor. Rejected: `openssl enc` AEAD modes (unsupported by `enc`).
- DEC-15: The deploy is authoritative and the registry a journal: every deploy carries the deployed bindings and `PAUSED` forward and applies one delta; the registry is cross-checked only. After a wipe, account VPC Services (admin-only objects) are the rebuild source. Rejected: deploy built from records (a member could unpause itself; review-1 finding 5).
- DEC-16: Pause means machine links answer 503; a paused member's cloud links keep serving and its own CLI refuses new adds (cooperative). Rejected: stamping cloud records (more writes for a rare case).
- DEC-17: In v1 tombstones exist only for v:3 links; an admin revokes an origin link on the origin. Rejected: a `t/` read in the Worker's miss branch (one more read for every legacy miss).
- DEC-18: Down detection for v:3 uses the Caddy header `X-Share-Served`, because a binding answer carries no `cf-cache-status`. Rejected: status codes alone (a foreign listener on the port would be served).
- DEC-19: EXPIRED and ONLINE/OFFLINE are derived, never stored; `member ls` reads connectors from the tunnel API, no probe link.
- DEC-20: The lease is 600 s, renewed before each Cloudflare step, stale at `LastModified` + 900 s; same-host dead holders are taken over at once.
- DEC-21: Join writes tokens and config locally before the record write and the record before the service, so a die after redeem resumes with a bare `share join`.
- DEC-22: Redeem sends `h`, not the code; the code never leaves the member's machine.
- DEC-23: `member add` records the invite hash before the `i/` PUT, so a rerun can delete a half-made invite.
- DEC-24: Unregistered R5 publishers keep working on T2; `member adopt` is optional.
- DEC-25: Admin verbs need only the admin token and the hostname; the bucket name comes from the deployed `BUCKET` binding.
- DEC-26: Member links answer GET and HEAD only in v1.
- DEC-27: Machine members are capped at 20 until TASK-1a(e) measures the binding limit.
- DEC-28: The tombstone young-skip (10 minutes) closes the revoke race where the owner deletes a fresh tombstone before the admin deletes the pointer.

## Open questions

Each is a fact the code cannot settle; the named task closes it before the task that depends on it.

| # | Question | Closes in |
|---|---|---|
| OQ-1 | The API-token permission-group name that allows Connectivity Directory service create and delete (spike O1 used wrangler OAuth as Super Admin) | TASK-1a(a), before TASK-1c's scope probe |
| OQ-2 | The REST multipart `vpc_service` binding entry and its settings GET shape (spike O1 deployed with wrangler) | TASK-1a(b), before TASK-0e is exercised live and TASK-1f |
| OQ-3 | Whether the minter can mint a token scoped to one R2 bucket (spike O2 minted Zone Read only; Console Labs had no share bucket) | TASK-1a(c), before TASK-1f |
| OQ-4 | What a binding fetch returns when the member's cloudflared or Caddy is down | TASK-1a(d), before the SV-22 fixture is final |
| OQ-5 | The binding count one Worker accepts | TASK-1a(e) |
| OQ-6 | WebSocket and upgrade through a binding | TASK-3f |
| OQ-7 | That an R2 binding `put` with `onlyIf.etagMatches` on a stale etag returns null (documented, not sampled); the redeem claim relies on it | TASK-1a(h), before the first T2 tenant exists (a T1 tenant holds no `i/` object, so Worker v5 is inert until then) |

## Grounding

### Cloudflare data shapes this spec asserts

| Claim | Live sample | Excerpt |
|---|---|---|
| A Worker reaches a plain-HTTP loopback server through a VPC Service on a tunnel with no public hostname | spikes O1, rows Origin, Tunnel, GET `/hello?x=1` | origin on `127.0.0.1:18765`; tunnel config "only the `http_status:404` catch-all (no public hostname, no DNS record)"; GET `200` |
| The VPC Service shape: http, ipv4 `127.0.0.1`, tunnel id, `http_port` | spikes O1, row VPC Service | `wrangler vpc service create share-spike-vpc --type http --tunnel-id <id> --ipv4 127.0.0.1 --http-port 18765` |
| The REST create body (`type`, `name`, `host.ipv4`, `host.network.tunnel_id`, `http_port`) | not sampled live; documented (outside 1) | TASK-1a(a) |
| The binding is a `vpc_service` keyed by `service_id` | spikes O1, row Worker | `vpc_services = [{binding = "MEMBER", service_id, remote = true}]` (wrangler); REST `{type:"vpc_service", name, service_id}` documented (outside 1), TASK-1a(b) |
| The Host the origin sees is the fetch URL's host; path and query pass | spikes O1, GET row | "origin saw `Host: s.console.so`, path and query intact" |
| Request headers pass unchanged, Access headers included (so the Worker strips them) | spikes O1, GET row | "every request header passed through unchanged (including a test `cf-access-jwt-assertion`)" |
| Bodies stream through the binding | spikes O1, row GET `/stream` | "first byte 0.49 s, total 3.0 s" |
| Added latency (Q-AVAIL-1 budget) | spikes O1, row Latency | "151, 354, 328, 155, 197 ms" |
| `warp-routing` is not needed | spikes O1, row `warp-routing` | "disabled in a second run: still `200`" |
| One cloudflared registers several connections, so "extra connector" counts connectors, not `conns` | spikes O1, row Tunnel | "4 connections registered"; shape of `GET .../connections` documented (outside 4), TASK-1a(f) |
| The tool mints user tokens; the secret is only in the mint response | spikes O2, rows User tokens, Secret | "mint `200`"; "returned only in the mint response; a later GET does not include it" |
| `expires_on` moves in place, secret unchanged | spikes O2, row Extend | "`PUT /user/tokens/<id>` with the same policies and a new `expires_on`: `200`, expiry moved +1 day, secret unchanged" |
| A half-made token is found by name | spikes O2, row Find by name | "the list shows `share-spike-mint`" |
| Account-owned tokens are unavailable today | spikes O2, row Account-owned | "403 with every stored token" |
| The bucket-scoped permission group exists | spikes O2, row Bucket scope | "Workers R2 Storage Bucket Item Write exists with scope `com.cloudflare.edge.r2.bucket`; a bucket-scoped grant was not minted" (TASK-1a(c)) |
| No API rotates a tunnel token | not sampleable; documented (outside 4) | "Dashboard only"; drives DEC-10 |
| The tunnel config API needs at least one ingress rule | spikes O1 used the catch-all; documented (outside 3) | keep the catch-all |
| S3 conditional writes (If-None-Match, If-Match) hold on R2 | ADR-0007 Context (measured) | "the S3 endpoint accepts the same token ... and honors both headers" |
| The invite seal and MAC work with the system and Homebrew openssl | sampled 2026-11-13 on the Mac (output masked to a boolean) | `/usr/bin/openssl` (LibreSSL 3.3.6) and `/opt/homebrew/bin/openssl` (OpenSSL 4.1.0): `enc -aes-256-cbc -pbkdf2 -iter 200000 -md sha256 -salt -a -A` roundtrip `roundtrip-ok`; `dgst -sha256 -hmac` ok. Linux CI openssl not sampled; TASK-1f runs on both CI runners |

Code facts the spec leans on (bin/share at the worktree, byte-identical to 4564c5c): `keep_bindings` holds only `secret_text` (L3766), so every deploy replaces the binding list; Caddy serves the whole `pub/` tree (`handle { root * "$pub"; file_server }`, L1127 to L1132); `r2_take` keeps only `v == 2` for the reap list (L3265); `r2_record_raw` errors on any other shape, blocking the sweep (L3283 to L3287); the hourly loop runs with `SHARE_API_TOKEN_OFF=1` (L1181); `rows_in` drops a row with an unknown token shape only for `host=`, `access=`, `access_rule=`, `prefix=`, `by=` (L90 to L135), so `revoked` needs no reader change beyond acceptance; there is no CLI version constant today (TASK-0a).

### Negative controls (dry traces)

Seams: `SHARE_TUNNEL=0`; `SHARE_R2_DRY=1` with `SHARE_R2_DRY_DIR` (a directory bucket, `r2_dry`, L3553); `r2-calls.log` (one `METHOD key` or `API METHOD path` line per call, L3561, L3636); `SHARE_R2_DRY_FAIL`, `SHARE_R2_DRY_FAIL_TIMES`, `SHARE_R2_DRY_PAUSE` (L3556 to L3566, L3638); the stub `security`, `launchctl`, `systemctl` with `STUBSEC_LOG` (tests/share.sh L23 to L58); the `tn` and `tm` HOME helpers, `trow`, `aged`, `mdel` (tests/share.sh L2861, L2956, L2868, L2322, L2962); `tests/worker.mjs` with its in-memory `Bucket` and `--dir` integration mode. New seams from TASK-1b: `SHARE_TEST_MEMBER_IDS`, `SHARE_TEST_CODE`, `SHARE_R2_DRY_WORKER`, `--bind`.

| # | Mutation | Fixture read | Code path | Test that goes red |
|---|---|---|---|---|
| NC-1 | reconcile row 10 also trashes `pub/<id>` | member HOME: row `aa0001`, `pub/aa0001/f.txt`; dry bucket: `t/aa0001` (origin = this member_id, aged 660 s), no `m/aa0001` | `share prune --loop` on R7, `r2_reconcile` row 10 | `mm RC-10: a tombstone revokes, never deletes bytes` (asserts `pub/aa0001/f.txt` exists and the row carries `revoked`) |
| NC-2 | restore the whole-tree `handle { root * "$pub"; file_server }` | `pub/bb0001/x.txt` with no row; Caddy started on the suite port | `write_caddyfile`, then `curl 127.0.0.1:<port>/bb0001/x.txt` | `mm SV-01: unlisted bytes answer 404` (gets 200) |
| NC-3 | drop the v:2 `expires` check in the Worker | `worker.mjs` bucket: `m/cc0001` v:2 `expires` 1000 | Worker row 8 | `v5 SV-10: an expired v:2 pointer answers 404 without a pass` (the stub fetch records a call) |
| NC-4 | skip the header strip before the binding fetch | `worker.mjs`: v:3 `dd0001` bound to a fake that records headers; request with the three Access credentials | Worker row 15 | `v5 SV-21: no Access credential reaches a binding` |
| NC-5 | skip the claim and the delete in redeem | `worker.mjs`: `i/<h>` envelope, `expires` now + 3600 | Worker row 3, two POSTs | `v5 SV-15: a second redeem answers 404` (gets 200) |
| NC-6 | `r2_deploy_meta` ignores the carried bindings | dry `.cf/script.json` with `M_aaaaaaa1`, `M_bbbbbbb2`, `PAUSED` `["m-an-aaaaaaa1"]`; `WORKER_SHA` bumped in a temp copy | `setup <h> --r2 --bucket B` rerun on the origin | `mm DY-01: a setup rerun keeps every member binding and PAUSED` |
| NC-7 | `lease_take` returns 0 without the PUT | `SHARE_TEST_MEMBER_IDS="m-an-aaaaaaa1 m-bo-bbbbbbb2"`; first `member add an` held by `SHARE_R2_DRY_PAUSE="PUT i/<h of SHARE_TEST_CODE>"` | second `member add bo` runs to the end, then the first resumes and deploys without `M_bbbbbbb2` | `mm CC-01: two admin adds at once keep both bindings` |
| NC-8 | the member reconcile drops the origin filter | member HOME (member_id `m-an-aaaaaaa1`); dry `m/ee0001` v:3 `origin` `m-bo-bbbbbbb2` aged 660 s, no local row | `r2_reconcile` row 6 | `mm RC-06: a member never touches another origin's pointer` (`mdel ee0001` = 1) |
| NC-9 | the deploy builder reads `PAUSED` from `u/` records | dry deploy `PAUSED` `["m-an-aaaaaaa1"]`; `u/m-an-aaaaaaa1.json` forged to `active` | `member pause bo` (any verb that deploys) | `mm FG-05: a forged record never unpauses a member` |
| NC-10 | `member rm` skips the service delete | dry `.cf/services/<id>.json` for an | `member rm an` | `mm MB-13: no object of a removed member remains` (lists `.cf/services/`) |
| NC-11 | join installs the service before its record write | `SHARE_R2_DRY_FAIL="PUT u/m-an-aaaaaaa1.json"` | `cmd_join` step 3 | `mm DP-join-3: a join that loses the record race leaves no service` (stub `launchctl` log shows a bootstrap) |
| NC-12 | `r2_record_raw` treats v:3 as unreadable | dry `m/ff0001` v:3; `o/9e0001.00000001/x` aged 25 h with no record | bare `share prune` on the origin | `mm SV-06: a v:3 pointer never blocks the orphan sweep` (the old upload stays; the warning prints) |
| NC-13 | the Worker ignores `PAUSED` | `worker.mjs`: `PAUSED` `["m-an-aaaaaaa1"]`, v:3 `ab0001` of that origin | Worker row 12 | `v5 SV-12: a paused member's link answers 503` |
| NC-14 | reconcile row 9 removed (no young-skip) | member HOME row `ac0001`, own pointer, `t/ac0001` aged 60 s | `r2_reconcile`; then the admin's pending DELETE lands; then a second reconcile | `mm CC-06: an admin revoke in flight is never undone` (the second reconcile rewrote the pointer) |
| NC-15 | the Worker serves a binding answer without `X-Share-Served` | `worker.mjs` fake binding answers 200 with no header | Worker row 15 | `v5 SV-22: a foreign listener is never served` |
| NC-16 | `rand_id` skips the `t/` check | dry `t/ad0001`; `SHARE_TEST_IDS="ad0001 ad0002"` | member `add` | `mm SV-09: a tombstoned id is never picked` (the add lands on `ad0001`) |
