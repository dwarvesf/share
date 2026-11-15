# Spec: multi-member tenants
Generated: 2026-11-13
Status: VALIDATED
Lane: full
Depth: research (outside: whether a Workers VPC tunnel binding reaches a plain-HTTP loopback Caddy from a Free-plan Worker, and whether an API token can mint account-owned R2 bucket-scoped tokens and extend their expiry) + blind-spot (failure: a multi-step admin verb that dies mid-way leaves an orphan tunnel, VPC Service, binding or token that no rerun finds)
References: `docs/briefs/DECISION-BRIEF-multi-member.md` (r2, the design this spec builds); `docs/research/2026-11-13-current-state-machines.md` (state map with line cites; imitate its step tables for every new verb); `docs/research/2026-11-13-multi-member-review-1.md` (33 findings, each folded below); `docs/research/2026-11-13-multi-member-outside.md` and `docs/research/2026-11-13-multi-member-spikes.md` (Cloudflare facts); `docs/SYSTEM-DESIGN.md` rev B (diagram ids cited in `## Design`); ADR-0007, ADR-0008, ADR-0009; `bin/share` `cmd_setup_tenant` steps 1 to 16 (imitate: every refusal before the first write, every step skipped when in place), `r2_reconcile` (imitate: a 10-minute age test before deleting anything another writer may be finishing), `r2_dry` and `r2_api_dry` (extend these seams, never a new test transport); `docs/research/2026-11-13-implicit-state-machines.md` (the state machine audit: decisions D1 to D9, amendments A1 to A12 folded below, each with a Decision Log entry).
Depends on: SPEC-010 (`docs/specs/SPEC-010-state-groundwork.md`). The per-task table `### SPEC-010 tasks each task needs` under `## Task Breakdown` is the gate (DEC-68). In short: Phase 1 requires SPEC-010's Phase 1 shipped (G1, G1b, G2a to G2c, G3, G4, G5, G13: codes and `die_code`, the step journal, `profile_role`, `config_put`, the skill reading `share state`, the admin key command). Phase 0 may land first, except TASK-0f, which needs G4, and TASK-0c's `link_state` values, which need G7. TASK-1i, TASK-2e and TASK-3d need G10 or land the `.health` key they write themselves. Phase 4's Share Bar tasks also need SPEC-010 G6, G7, G9, G10, G11a to G11c and G14.

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
- `minter token`: a Cloudflare user token with API Tokens Read and Write only, read from `SHARE_MINTER_TOKEN`, else from the output of the config key `minter_token_cmd` (SPEC-010 G13, DEC-80); mints, extends and deletes member publisher tokens.
- `T0`, `T1`, `T2`: tenant states; tunnel only, R2 on, members on.
- `R7`: the member profile role, detected by config `role=member`.
- `carry-forward`: every Worker deploy reads the deployed settings and re-sends every `vpc_service` binding, `MEMBERS` and `PAUSED`, then applies only the running verb's change.
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
        suffix in PAUSED ─────────────────────────────────────────────────────► 503 paused
        no binding M_3f9a1c2d ────────────────────────────────────────────────► 404
        GET/HEAD only; rewrite to http://s.console.so<path>; strip Access headers + CF_Authorization
          env.M_3f9a1c2d.fetch() ─► VPC Service ─► An's tunnel ─► An's cloudflared ─► An's Caddy 127.0.0.1:<port>
          answer without X-Share-Served, or a throw ─► 503 offline (generic)
          text/html answer ─► + Content-Security-Policy: sandbox ...
     any pointer past expires ─────────────────────────────────────────────────► 404 (new)

 admin (any machine; CLOUDFLARE_API_TOKEN or admin_token_cmd; SHARE_MINTER_TOKEN or minter_token_cmd)
   share member add|ls|sync|rm|purge|pause|resume|invite|rotate|renew|adopt
     │ holds lock/admin; record intent ─► Cloudflare change ─► record final
     ├─► Cloudflare API: tunnel, VPC Service, Worker deploy (carry-forward + delta), user tokens
     └─► bucket: u/, i/, t/, lock/admin, share.json

 member machine (R7, role=member)
   share join <host> <code> ─► redeem ─► Keychain (publisher + connector token) ─► Caddy + cloudflared
   share add <file> ─► m/<id> v:3 ─► pub/<id> ─► row ─► Caddy handle /<id>
   hourly loop: prune + reconcile (own origin, Keychain token) ─► revoked rows lose their handle

 bucket: share.json {members, min_cli} │ u/<member_id>.json │ u/purged.json │ i/<h> │ t/<id> │ lock/admin │ m/<id> v:1|v:2|v:3 │ o/...

 Share Bar (mac/, revision 8: docs/design/share-bar-redesign.html)
   reads share profiles --json, share state, share member ls --json ─► PopoverState ─► popover, Settings, All links
   runs share <verb> with argv only (SHARE_PROGRESS=1, SHARE_ERROR_JSON=1) ─► the CLI above
   tests: mac/shots.sh drives the built app against the fake CLI; mac/compat-check.sh decodes with v0.9.0's sources
```

## Design

Ordering: data models and the Worker contract first (they harden fastest), then the admin verb write orders, then the member CLI, then docs.

### Approaches considered + chosen

Chosen: C, one Workers VPC Service per member tunnel, bound to the tenant Worker (`## Solution` has the table). No new tradeoff surfaced in the design view, with one refinement recorded in the Decision Log (DEC-15): the deploy body is carried forward from the deployed settings, not rebuilt from the member-writable registry.

### Diagram

ASCII flow: `## Picture`. The worktree's `docs/SYSTEM-DESIGN.md` rev B carries the design as UML; this spec cites its ids and lists the deltas TASK-4c folds back in.

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
| `sm-member` | member lifecycle | EXPIRED is derived, never stored (DEC-19); rotate replaces the tunnel (DEC-10); rotate ends in INVITED with `prev_status` kept, and join's final write restores it (DEC-30); the full transition table is `### Member status transitions` |
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
- The deployed Worker settings, `GET /accounts/<a>/workers/scripts/<w>/settings`: `.result.bindings[]`, read on every deploy path to carry `vpc_service` bindings, `MEMBERS` and `PAUSED` forward (shape of the `vpc_service` entry: TASK-1a(b)).
- The bucket through the S3 API (unchanged transport, ADR-0007): `share.json`, `u/`, `i/`, `t/`, `lock/admin`, `m/`, `o/`.
- The Cloudflare API with the admin token: tunnels, tunnel configurations, tunnel connections, tunnel token, Connectivity Directory services, Worker scripts. With the minter token: `/user/tokens` (list, create, update, delete, permission_groups).
- Local: config, `index.tsv`, Keychain items `share-api[.<p>]:<host>` (publisher token) and `share-tunnel[.<p>]:<host>` (connector token), the existing services.

Outputs / produces:
- The Worker v5 HTTP contract (below), relied on by `join`.
- `share state` JSON stays `schema: 1` and never gains a `state.state` value (DEC-32). It gains, additively: per row `origin` (member name or empty) and `link_state` with the SPEC-009 values `revoked`, `paused` and `offline` beside SPEC-010's `live`, `expired`, `shadowed`, `gate_missing`, plus `reason`; per profile `role` (SPEC-010 G3; `member` on R7), and on R7 `member = {id, name, mode, status, step, token_expires}` (the earlier draft's flat `member_id`/`member_status` became `member.id`/`member.status`) and `token = {source, status, expires_on}` (DEC-39). Share Bar reads them (TASK-4b1).
- `share member ls --json`: one object per member with `member_id`, `name`, `mode`, `status`, `step`, `step_name`, `lease` (`holder`, `verb`, `step`, `live`), `deploy` (`bound`, `paused`), `account` (`tunnel`, `connectors`, `services`), `token_expires`, `invite_expires`, `can[]` (the verbs `member_can <status> <verb> admin` allows from the record's status, plus `finish` for an `...ing` whose lease is stale; the Share Bar's row menu lists exactly these, DEC-53), `drift[]`; each `drift[]` entry is a stable code from SPEC-010's `code_text` (`config_drift`, `deploy_paused_record_active`, `deploy_bound_record_removed`, `deploy_unpaused_record_paused`, `deploy_unbound_record_live`, `extra_connector`, `record_invalid`, `token_unreachable` with the token's `expires_on`), never free text (DEC-35, DEC-62, DEC-78). `member ls` writes nothing to the bucket or Cloudflare; the one local write it makes is the top-level key `members` of the profile's `.health` file (`{at, list:[{member_id, suffix, status, paused, connectors}]}`), through SPEC-010 G10's per-key `jq` writer.
- The members cache (DEC-71): `state` sets a v:3 row's `link_state` from `.health`'s `members` key, matching the last 8 hex of the row's `origin` to `suffix`: `paused` when the member is paused, `offline` when its connectors are 0, else `live`; with no cache, or a cache older than 24 h, the row reads `live`. On R7 the member's own status comes from its `.health` cache (TASK-2e). `state` still makes no network call.
- Every refusal a SPEC-009 verb adds (member verbs, join, `min_cli`) goes through SPEC-010's `die_code <code> <message> [next]`: the human line is unchanged in shape, `SHARE_ERROR_JSON=1` adds the JSON line (DEC-35).

Invariants:
1. Routing changes only through a Worker deploy made with the admin token; no bucket object changes routing.
2. Every deploy body equals the deployed bindings plus exactly the running verb's delta.
3. Bytes on a machine are deleted only by that machine's own `rm`, prune of an expired row, `leave`, or `leave --local`.
4. A machine serves only rows present, unexpired and not revoked in its own `index.tsv`.
5. Every multi-step admin verb holds `lock/admin`, writes `status=<verb>ing` before its first Cloudflare change, and converges on rerun.
6. A redeemed or expired invite yields no sealed bytes again; at most one of two concurrent redeems yields them.
7. No token, code or key reaches an argv, a file outside the Keychain, or output (extends ADR-0007's rule to the minter, connector token and code). Named exceptions: the invite code is printed once by `member add`, `invite` and `rotate`, and is the argument of `share join` by design.
8. Every admin verb finds its tunnel, VPC Service and token by deterministic name through the admin-only account APIs (tunnels, services) or the minter's `GET /user/tokens`. An id in a `u/` record is a hint only: it is used after a GET by that id returns the expected name, else the name lookup wins (DEC-58).

### Data model changes

Bucket keys (all JSON; every reader validates every field before use, as `r2_take` does today):

| Key | Shape | Written by | Read by |
|---|---|---|---|
| `share.json` | `{v:1, host, aliases?, members:true, min_cli:"0.10.0"}` | `setup --r2 --members` (If-Match) | every CLI (min_cli gate, TASK-4a); join |
| `u/<member_id>.json` | `{v:1, member_id, name, mode:"machine"\|"cloud", status, prev_status?, step?, step_name?, rotation:0, tunnel_id?, tunnel_name?, vpc_service_id?, port?, token:{id, name, expires_on}, token_unreachable_until?, invite:{hash, expires}?, added, joined?, updated, by}`; never a secret; `token_unreachable_until` is the `expires_on` of a token the current minter could not find, written by `rm`, `invite` or `rotate`, display only (`member ls` shows `token_unreachable` until it passes; DEC-78); `step`/`step_name` name the step of the running `...ing` (DEC-31) and are dropped on reaching a resting status | admin verbs (If-None-Match, then If-Match); member: `joining` (from `invited`), then `prev_status` if set else `active` (from `joining`, DEC-30), `left` (from `active`/`paused`); every write passes `member_can` (`### Member status transitions`) | admin verbs, `member ls`, join, member `status` |
| `u/purged.json` | `{v:1, ids:["m-..."]}` | `member purge` (If-Match) | member_id generation |
| `i/<64 hex>` | `{v:1, member_id, expires:<epoch>, sealed:"<base64>", mac:"<64 hex>"}` | `member add`, `invite`, `rotate` | Worker redeem only |
| `lock/admin` | `{v:1, holder:"<host>:<pid>:<nonce8>", verb, member, step, taken}`; `lease_renew` rewrites `step` at each step (DEC-36) with If-Match on the etag this holder last wrote, and a 412 dies `lease_lost` before the step's Cloudflare call; `lease_release` deletes only after a GET shows its own holder nonce (DEC-63); age judged by `LastModified` | every admin verb | every admin verb, `member ls` (prints the holder live or stale with the rerun) |
| `m/<id>` v:3 | `{v:3, id, storage:"machine", origin, name, by, added, expires, opts, type}`; `opts` tokens `noindex` (and `live` only if TASK-3f passes) | machine member `add` (If-None-Match), own reconcile | Worker, every reader |
| `t/<id>` | `{v:1, id, origin, by, at}`; `at` display only, age by `LastModified`; a `by` outside `[A-Za-z0-9._@:-]{1,64}` is read as `unknown`, so it never injects an opts token or a row into `index.tsv` (FG-16) | admin revoke, `member rm` | owner reconcile, `member sync` sweep, `rand_id` |

Status values: stored `adding`, `invited`, `joining`, `active`, `pausing`, `paused`, `resuming`, `inviting`, `rotating`, `renewing`, `removing`, `removed`, `left`. Derived, never stored: `EXPIRED` (`invited` and `invite.expires` past), `ONLINE`/`OFFLINE` (connector count from the tunnel API). The only allowed moves between them are the rows of `### Member status transitions` below.

Sealed bundle (plaintext inside `sealed`): `{v:1, host, bucket, r2_endpoint, member_id, name, mode, port?, tunnel_id?, publisher_token, connector_token?, token_expires_on}`.

Invite crypto (DEC-14; roundtrip sampled in `## Grounding`): `code` = 20 chars from the RFC 4648 base32 alphabet, from `/dev/urandom`; object id `h = sha256("share-invite-id:" + code)`; `sealed = base64(openssl enc -aes-256-cbc -pbkdf2 -iter 200000 -md sha256 -salt)` with the passphrase passed as `-pass fd:3`, never argv; `mac = HMAC-SHA256(key = sha256("share-invite-mac:" + code), sealed)`. Unseal verifies `mac` first.

Local config keys:

| Key | Profile | Meaning |
|---|---|---|
| `members=on` | origin | T2, together with the marker: the origin is T2 when config `members=on` OR marker `members:true`; when they disagree `state.tier_drift` is true and verbs report `config_drift` (DEC-33). The teardown, migrate and `--no-r2` refusals read the marker, and also refuse while the deployed settings hold any `vpc_service` binding, so neither a dropped config key nor a forged `members:false` opens them |
| `role=member` | member | the R7 detector |
| `member_id` | member | own identity; the v:3 `origin` |
| `member_mode` | member | `machine` or `cloud` (`mode` already means the quick tunnel, L77) |
| `tunnel_id` | machine member | own tunnel, for `status` |

`index.tsv` rows gain the opts token `revoked` (and `revoked_by=<by>`, display only); `rows_in` accepts both, and `write_caddyfile` skips a revoked row.

### API changes

Worker v5 (`WORKER_VERSION=5`, new `WORKER_SHA`; bindings `BUCKET`, `HITS`, `HOST`, `TEAM`, `VERSION`, `SHA`, `PASS`, `ALIASES`, `MEMBERS` (`1` on T2, DEC-59), `PAUSED` (JSON array of 8-hex binding suffixes, the same key row 13 routes by, `[]` by default; DEC-60), `DEPLOY` (nonce), `M_<8hex>` (one `vpc_service` per machine member), secret `SALT`). Decision order (new rows marked):

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
| 12 (new) | v:3 origin's last 8 hex in `PAUSED` (the same key row 13 routes by, so a forged name part cannot get past a pause; DEC-60) | 503, body `this link is paused by the tenant admin`, `no-store` |
| 13 (new) | v:3 binding `env["M_" + last 8 hex]` absent or not fetchable | 404 |
| 14 (new) | v:3 method not GET/HEAD | 405 |
| 15 (new) | v:3 fetch: `new Request("http://" + HOST + path + query)`, forwarding only the request headers `Range`, `If-*`, `Accept*` and `User-Agent` (no `Cookie`, no `Authorization`, no `cf-access-*`); `redirect: "manual"` | throw, or no `X-Share-Served` header: 503 offline page (unchanged text, no member name); else rewrap with `no-store`, `X-Robots-Tag`, `X-Share-Served` removed; `Set-Cookie`, `Clear-Site-Data` and `Refresh` dropped; a 3xx keeps `Location` only when it is a relative path or an absolute path under `/<id>/` (Caddy's folder redirect `/<id>` to `/<id>/` included), else 502; `Content-Type` set from the path extension (the Worker's `TYPES`; a path ending in `/` is `text/html`, a folder listing or index; any other unknown: `application/octet-stream`) with `X-Content-Type-Options: nosniff`; every answer whose type is not in the inert list (images other than SVG, `application/pdf`, audio, video, `text/plain`, `application/octet-stream`) carries `Content-Security-Policy: sandbox allow-scripts allow-forms allow-popups allow-downloads` (DEC-59); never counted as a hit |
| 16 | other records, cloud serving, hits | unchanged, except on a T2 tenant (plain-text binding `MEMBERS` = `1`, set by `setup --members`, dropped by `--no-members`, carried forward like `PAUSED`) the cloud path adds the same CSP sandbox and `nosniff` to HTML, SVG and XML answers, because any publisher token writes any cloud record (DEC-59) |

Named rows (DEC-38, inside the same v5 bump, no extra `WORKER_VERSION`): the table above is a pure `decide(request, env, rec)` returning `{row, status}`, and `handle` performs its answer. Row ids are constants: `ALIAS_301`, `WRONG_HOST`, `BAD_PATH`, `HEALTHZ`, `PASS_NON_ID`, `PASS_MISS`, `BAD_JSON`, `PASS_V2`, `V2_EXPIRED`, `BAD_RECORD`, `GATE_DENIED`, `V3_PAUSED`, `V3_UNBOUND`, `V3_DOWN`, `V3_METHOD`, `V3_EXPIRED`, `V3_SERVED`, `REDEEM_OK`, `REDEEM_METHOD`, `REDEEM_BAD_BODY`, `REDEEM_UNKNOWN`, `REDEEM_EXPIRED`, `REDEEM_UNAVAILABLE`, `SHARE_PATH_UNKNOWN`, `CLOUD_OBJECT`. Status codes stay as the table says. Every Worker 404 answers one plain-text body, `no such link (it may have expired or been removed)`, the same for every 404 row, and no header names the row: a per-row answer would be an id-existence oracle over 24-bit ids.

Cloudflare API calls added (admin token unless marked minter): tunnels `POST /accounts/<a>/cfd_tunnel` (`config_src: cloudflare`), `PUT .../cfd_tunnel/<t>/configurations` (only the `http_status:404` catch-all), `GET .../cfd_tunnel/<t>/token`, `GET .../cfd_tunnel/<t>/connections`, `DELETE .../cfd_tunnel/<t>/connections`, `DELETE .../cfd_tunnel/<t>`, `GET .../cfd_tunnel?name=<n>&is_deleted=false`; VPC Services `POST|GET|PUT|DELETE /accounts/<a>/connectivity/directory/services[/<id>]`; Worker deploy (existing multipart PUT, metadata gains `{type:"vpc_service", name:"M_<8hex>", service_id}` entries, `PAUSED`, `DEPLOY`); minter: `GET /user/tokens`, `POST /user/tokens`, `PUT /user/tokens/<id>`, `DELETE /user/tokens/<id>`, `GET /user/tokens/permission_groups`.

### UI changes

CLI verbs (admin verbs need the admin token, `CLOUDFLARE_API_TOKEN` or else the output of the config key `admin_token_cmd` (SPEC-010 G13, DEC-46), proven as admin by a settings GET 200, and take the tenant from `--tenant <host>` or the profile's `hostname`; token verbs also need the minter token, `SHARE_MINTER_TOKEN` or else the output of the config key `minter_token_cmd`, resolved only on `member add`, `invite`, `rotate`, `renew`, `rm` and `adopt` (SPEC-010 G13, DEC-80)):

| Verb | Actor | Notes |
|---|---|---|
| `share version` | anyone | prints `SHARE_VERSION` |
| `share setup <h> --r2 --bucket B --members [--yes]` / `--no-members` | admin, on the origin | T1 to T2 and back |
| `share member add <name> [--machine\|--cloud] [--port P] [--invite-ttl 7d] [--token-ttl 90d]` | admin | prints the invite line once; `--invite-ttl` above 30 days is refused, because the Worker reads an envelope more than 30 days ahead as forged |
| `share member ls [--json]` | admin | report only; writes nothing to the bucket or Cloudflare; its one local write is the `members` key of `.health` (DEC-71) |
| `share member sync [--rebind]` | admin | record repair from the deploy; expired invites and old tombstones swept |
| `share member rm <name> [--cloud-links keep\|delete]` | admin | default keep (DEC-1) |
| `share member purge <name>` | admin | REMOVED only |
| `share member pause <name>` / `resume <name>` | admin | machine members only (a cloud member is refused `member_cloud`) |
| `share member invite <name> [--port P] [--invite-ttl 7d]` | admin | new code; old token and invite gone |
| `share member rotate <name>` | admin | machine members only; new tunnel, service, tokens; same id and links |
| `share member renew <name> [--token-ttl 90d]` | admin | extends `expires_on` in place |
| `share member adopt <name> --token-id <id>` | admin | registers an R5 publisher as a cloud member |
| `share [--profile p] join <host> <code>`; `share join` | member | redeem; the bare form resumes a died join from its journal step; on R7 of the same member_id it re-joins after `rotate` or `invite` |
| `share leave [--local]` | member | `--local` makes no bucket call |
| `share status` (on R7) | member | record status, token expiry, Worker pair; removal shown only from a record read as `removed`, a 401 reads as a key problem (DEC-79) |

Refusal lines name the next command, as today, through `die_code` (DEC-35). Share Bar: revision 8 of `## UI design` (TASK-4b1 to TASK-4b23): a menu of recent links, v:3 rows read `<member>'s machine`, a member profile shows its status in Settings > Tenants, the admin manages members in Settings > Members.

### Infrastructure changes

Per machine member on the tenant's Cloudflare account: tunnel `share-<host-dashes>-<8hex>[-r<n>]` (remote-managed, config = only the catch-all, no DNS), VPC Service of the same name (`type: http`, `host.ipv4: 127.0.0.1`, `host.network.tunnel_id`, `http_port: <port>`, no `https_port`), Worker binding `M_<8hex>`. Per member: user token `share <host> <member_id>` (Workers R2 Storage Bucket Item Write on `com.cloudflare.edge.r2.bucket.<acct>_default_<bucket>`, Zone Read on the zone, `expires_on`). Admin token scopes grow by Cloudflare Tunnel Edit (already used by setup) and Connectivity Directory Admin (permission-group name: TASK-1a(a)). The minter token is new (API Tokens Read and Write), a separate 1Password item.

### The 28 `r2on` sites on a machine member (review-1 finding 9)

A machine member has `backend` unset and `bucket=` set, so `r2on=1` as on the origin; the R7 detector adds `member=1` right after L79. Every site keeps its origin behavior unless the row says otherwise.

| Line | Site | Machine member behavior |
|---|---|---|
| 78, 79 | `r2on` detector | unchanged; R7 detection lives inside SPEC-010's `profile_role` (role `member`), not as a new flag |
| 172 | `rand_id` bucket check | also refuses an id whose `t/<id>` exists (origin too) |
| 480, 484, 485 | storage choice | default storage `local`; `--cloud` allowed; `storage_default` ignored |
| 534 | `r2_token_check` | Keychain publisher token |
| 547 | `r2_pointer_put` | writes v:3 with `origin=<member_id>`; `r2_pointer_write` (L2936), which reconcile row 11 also calls (L2988), writes v:3 with `origin` on R7, never a v:2 |
| 574 | add lock release | unchanged |
| 589, 592 | `ls` empty and listing | unchanged |
| 638 | refresh dispatch | unchanged (cloud refresh only from the install that added it) |
| 660 | rm dispatch | no local row: cloud row by today's rule; v:3 of another origin and every v:2 refused before any call |
| 703 | interactive prune | cloud expiry, own v:3 pointer expiry, own-origin reconcile, orphan sweep on bare prune |
| 732 | hits dispatch | own machine row: its `access.log` (unchanged path); cloud row: refused naming Account Analytics Read |
| 783 | import | refused (unchanged text) |
| 960 | migrate | refused: "a member machine moves by leave and a new join" |
| 1478 | `profiles --json` | embeds `state` unchanged, so it carries `role` and `member {id, name, mode, status, step, token_expires}` (DEC-32) |
| 1861 | dry log | unchanged |
| 2396 | access sweep side | skipped (members hold no Access apps) |
| 2448, 2463, 2476, 2493 | `api-token` | publisher checks kept; the "Access scopes stay required" branches skip for R7 |
| 2909 | `list_rows` bucket rows | unchanged; v:3 rows of other origins show `origin=<name>` |
| 3000 | `r2_pointer_drop` | deletes only a v:3 whose `origin` is this member_id |
| 3520 | `r2_creds` | unchanged |
| 3849 | `setup --r2` sets `r2on` | `setup` refused on R7: "this machine is a member of <host>; share leave first" |

Non-`r2on` sites that change on R7: `r2_take` (on R7, `r2_machine` gets only v:3 pointers whose `origin` is this member_id, never a v:2; lands with TASK-1g, DEC-65), `r2_reconcile` (own-origin filter), `cmd_serve` (hourly loop runs `prune --loop`, TASK-2c), `cmd_teardown` (refused: "use share leave"), `cmd_setup` (refused), `cmd_status` (member variant), `write_caddyfile` (main site answers `http://<host>:<port>` and loopback, as named mode does today, L1091).

### Member status transitions (the contract of `reg_status`)

Source: audit D8. Owner: `member_can <status> <verb> <actor>` in `bin/share`, a `case` table (bash 3.2: no associative arrays), called by `reg_status` before every record write, by the admin and by the member. The doc table below and the `case` table are the same table; a suite test iterates every (status, verb, actor) triple, 13 stored statuses plus "none", against it (DEC-29). SPEC-010's hidden verb exposes it: `share state-fn member-can <status> <verb> <actor>`.

```
            add            join(member)        join(member)
  (none) ─────► adding ───► invited ───► joining ───► active ◄────────────┐
                 │            ▲  │                     │ │  ▲            │
                 │   invite   │  │ rm                 │ │  │ resume      │
                 │  inviting ─┘  ▼                    │ │  └── resuming ◄┐│
                 │            removing ──► removed ───┼─┼──► (purge)    ││
                 │                ▲                   │ └► pausing ► paused
                 └── rm ──────────┘   (rm from every   │       rotate: active|paused
                                       status except   │       ─► rotating ─► invited
                                       removed)        ▼          (prev_status kept)
                                                   left (leave)
```

From-set per verb; any `...ing` of the same verb is also allowed (a rerun):

| verb | actor | from | intent | to |
|---|---|---|---|---|
| add | admin | (none) | adding | invited |
| invite | admin | invited, joining, left | inviting | invited |
| pause | admin | active | pausing | paused |
| resume | admin | paused | resuming | active |
| rotate | admin | active, paused, invited, joining (machine mode) | rotating | invited (prev_status = active or paused; from `invited` or `joining` it keeps whatever it holds) |
| renew | admin | invited, active, paused | renewing | the status it started from |
| rm | admin | every status but removed | removing | removed |
| purge | admin | removed | (none) | record deleted |
| adopt | admin | (none) | (none) | active (cloud) |
| join step 3 | member | invited | joining | (step 6) prev_status if set, else active |
| leave | member | active, paused | (none) | left |
| sync | admin | active, pausing, resuming, paused | (none) | deploy wins for `paused`, except that a `paused` record missing from `PAUSED` is re-paused, never unpaused (DEC-75); `invited` and `joining` are reported, never changed (DEC-72; `member sync` below) |

Guards:
- `pause`, `resume` and `rotate` take a mode: `member_can <status> <verb> <actor> [mode]` answers no for mode `cloud`, so `can[]` never offers them for a cloud member.
- A verb that finds the record in a different verb's `...ing` refuses with code `member_busy`, copy `share: <name> is mid-<verb> (step <n>) since <time>; finish it: share member <verb> <name>`. Three exceptions: `rm` wins from any status (CC-04), `rotate` runs from `joining` (a leaked code someone else is redeeming, DEC-67), and `sync` reports instead of refusing.
- The member never writes once the record is `removing` or `removed` (`member_can` answers no for actor member there).
- `prev_status` (DEC-30, DEC-41): written when an `...ing` is entered from `active` or `paused`; entering an `...ing` from `invited`, `joining` or `left` keeps whatever it holds; a rerun never rewrites it. Reaching `active`, `paused`, `left` or `removed` clears it; reaching `invited` keeps it, so rotate's restore target survives a later `invite` or `renew`. Join's final write sets `prev_status` if set, else `active`, and clears it.
- "The status it started from" (renew, and an interrupted invite): `invited` when the record holds an `invite` object (a join is pending), else `prev_status`. Join's final write drops `invite`, since the code is spent.
- EXPIRED, ONLINE and OFFLINE stay derived (DEC-19); `member_can` never sees them.
- Each `...ing` write also writes `step` and `step_name` (DEC-31); the resting write drops them.

Rotate (DEC-30): rotate ends in `invited` with `prev_status` kept; join's final write restores it, so a paused member stays paused after re-joining (MB-12's intent) and join step 3 keeps one rule (`invited`).

Invite and join refusal contract (DEC-37). Each is a `die_code` code; the copy is the member's terminal line:

| redeem answer | code | copy |
|---|---|---|
| 404 | `invite_unknown_or_used` | machine member: `this invite was already used or never existed; ask the admin: share member rotate <name>` (a code someone else redeemed gave them the connector token, which only rotate replaces; DEC-67); cloud member (no connector token): `...; ask the admin: share member invite <name>` |
| 410 | `invite_expired` | `this invite expired; ask the admin: share member invite <name>` |
| 503, any other non-2xx, or no answer within 30 s | `invite_unavailable` | `the invite could not be released (it may be spent); ask the admin: share member invite <name>` |
| mac mismatch | `invite_tampered` | `this invite was altered; ask the admin for a new one` |
| record 412 | `member_changed` | `the admin changed this member during the join; nothing was kept here` |

### Admin verb write orders

Every admin verb: refusals and scope probes first; lease; the settings GET that builds a deploy body is made after the lease is taken (DEC-62); every tunnel, VPC Service and token it touches is found by name (invariant 8, DEC-58), never by an id read from `u/` alone; every token step lists the current minter's `GET /user/tokens` and acts on the token named `share <host> <member_id>`, whatever the record says; no match means the verb reports the drift code `token_unreachable` with the token's `expires_on` (DEC-78); record intent (If-Match, through `reg_status` and `member_can`); each Cloudflare step skipped when in place; record final; lease release. Each step below names how a rerun finds what an earlier run made. Each step is also an `op_step` of SPEC-010's journal on the admin's machine and a `step`/`step_name` on the record and the lease (DEC-31, DEC-36), so `member ls` and `status` name where a died verb stopped and print its rerun.

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

`join <host> <code>` (`seq-join`), on the member. Every step is an `op_step` of the `join` journal (SPEC-010 G2, `$root/ops/join.<pid>.json`); bare `share join` reads the step from the dead journal file, never from which local files exist (DEC-31):

| # | Step | Die here leaves | Recovery |
|---|---|---|---|
| 0 | refuse: profile not R0, unless R7 of the same host (a re-join after `rotate` or `invite`, DEC-30); CLI below marker `min_cli`; no `security` command (`member_needs_keychain`: members run on macOS only in v1, DEC-66); machine: `caddy` or `cloudflared` missing, invite port busy here | nothing | |
| 1 | `POST /_share/redeem` with `h` | code spent, nothing local | admin `member invite` |
| 2 | verify `mac`, unseal; on an R7 profile refuse unless the bundle's `member_id` equals config `member_id` (`member_changed`, nothing local touched); store both tokens in the Keychain (replaced in place on a re-join); write config (`role`, `member_id`, `member_mode`, host keys) through `config_put` | local config, no record change | `share join` (bare) resumes from the journal step |
| 3 | GET record: status `invited`, same member_id; PUT status=joining (If-Match, `member_can invited join member`). 412: remove local config and tokens (keep them on a re-join), die `member_changed` | | |
| 4 | machine: write Caddyfile, install and start the service | running service | resume |
| 5 | probe: add a probe file (v:3), GET it through `https://<host>/` 3x200, rm it | probe row | resume retries; failure names `member ls` for the admin |
| 6 | record status = `prev_status` if set, else `active`; `joined`; `prev_status`, `invite`, `step` dropped (DEC-30) | | |

`member rm <name>` (`seq-member-rm`): lease; status=removing; deploy without `M_<8hex>` and without its suffix in `PAUSED`, nonce 3x; delete VPC Service by name (404 = done); delete tunnel connections, then the tunnel, by name (404 = done); delete the token found by name in the current minter's `GET /user/tokens`; with no match, print `token not reachable by this minter; it expires <expires_on>` (the record's date, display only), write `token_unreachable_until`, and go on, so the verb still ends REMOVED and `member ls` shows `token_unreachable` (DEC-78); the lookup runs on every rerun, so a forged `step` cannot skip it; for each v:3 with this `origin`: `t/<id>` (If-None-Match; 412 = present), DELETE `m/<id>`; cloud links with `origin` this member per `--cloud-links`; delete the record's `i/`; status=removed; lease release.

`member pause` / `resume`: lease; status=pausing|resuming; deploy with the member's 8-hex suffix added to or dropped from `PAUSED` (carry-forward otherwise); status=paused|active.

`member invite`: lease; status=inviting (from `invited`, `joining` or `left`; `prev_status` kept, DEC-41); delete the token found by name (no match: the `token_unreachable` line and field, DEC-78), then mint a new one under the current minter; machine: delete tunnel connections; `--port` updates the VPC Service (`PUT`); record invite hash; delete old `i/`; new `i/`; status=invited.

`member rotate` (DEC-10): lease; status=rotating, `prev_status` kept; `rotation+1`; new tunnel `...-r<n>` and new VPC Service of that name; deploy rebinding `M_<8hex>` to the new service (same binding name, so links and PAUSED stay); delete old connections, old service, old tunnel; delete the token found by name (no match: the `token_unreachable` line and field, DEC-78) and mint a new one under the current minter; new invite; status=`invited`, `prev_status` kept (DEC-30; the earlier draft ended at `prev_status`, which join step 3 then refused, so every re-join after rotate died). The member is offline until it runs `share join <host> <code>` again; join on an R7 profile with the same member_id replaces tokens in place, and join's final write restores `prev_status`, so a paused member comes back paused.

`member renew`: lease; find the token by name in the current minter's `GET /user/tokens`; no match dies `token_unreachable`, naming the token's `expires_on` and `share member rotate <name>` (`invite` for a cloud member), before any record write (DEC-78); status=renewing; `PUT /user/tokens/<id>` on the found id with the same policies and the new `expires_on`; record `token.expires_on`; status back to the status it started from (`### Member status transitions`).

`member adopt <name> --token-id <id>`: refuse unless the id is in the minter's `GET /user/tokens` (made by the same user, so `rm` can revoke it) and its policy names only this bucket plus Zone Read; list the v:1 records whose `by` the admin names for confirmation (records keep `by`; `origin` is not rewritten); write `u/` status=active mode=cloud.

`member sync [--rebind]`: lease; per record, deploy wins for admin-set state, only from `active`, `pausing`, `resuming` or `paused` (DEC-72): suffix in `PAUSED` makes an `active`, `pausing` or `resuming` record `paused`; a `paused` record whose suffix is missing from `PAUSED` gets it back (sync deploys once, after printing the list; a forged `paused` record can only pause, never unpause); `pausing` bound and not paused turns `active`; `invited` and `joining` are reported, never changed, so rotate's `prev_status` survives; `removing`/`removed`/`left` with a binding are reported, never changed. `--rebind`: for each VPC Service on the account named `share-<host-dashes>-<8hex>[-r<n>]` whose record is not `removing`/`removed`, re-add its binding (the account objects are admin-only, so they are a trusted source), and restore `PAUSED` from records marked paused after printing the list. Also deletes `i/` objects past expiry and tombstones of REMOVED or purged origins older than 30 days by `LastModified`.

### Reconcile (every install, own origin only)

Own pointer: on the origin, a valid v:2; on a member, a valid v:3 whose `origin` is its member_id; on R7 the reap list `r2_machine` holds only those, never a v:2 (DEC-65). Reconcile lists `m/` before it reads `t/` (DEC-64). Rows run in this order; first match wins.

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
| 11 | live | absent | absent | write pointer (If-None-Match); 412 goes to row 12; then GET `t/<id>`: present means a revoke landed between the reads, so DELETE its own write and apply row 10 (DEC-64) |
| 12 | live | other record | absent | report "shadowed; rm one of them" |
| 13 | live | other record | present | flag row revoked (the id was reissued after a removal) |

On the origin the tombstone rows (5, 8, 9, 10, 13) never fire in v1: tombstones exist only for v:3 links, and the origin ignores `t/` for its own v:2 rows (DEC-17).

## UI design
Date: 2026-11-14 (revision 8; replaces the revision 2 brief of 2026-11-13)
Source: the reviewed prototype `docs/design/share-bar-redesign.html` revision 8 (open it and use the Scenario buttons: Admin with 12 members, Member, All calm, First run) and the interactions map `docs/design/share-bar-interactions.md` (every control, the command it runs and the state machine it moves, sections 1 to 8). This section names the shape, the rules and the contracts TASK-4b1 to TASK-4b23 build against; for any detail it does not restate (exact copy, step names, spacing), the prototype wins, then the interactions doc.

References: Dropbox, Tailscale, CleanShot X and Droplr menu bar apps (a recent list is the whole menu, status is one line, preferences live in a window); the macOS System Settings toolbar (icon tabs); Mobbin screens cited in the prototype's References section (Dropbox iOS file meta line and upload toast, Bloom and Firecrawl settings sections, Linear members table) and in the interactions doc 3a (Pitch "Links overview", Mistral counted status tabs).

### Aesthetic direction (feeds the generator)
- Purpose: the menu answers one question, "where is the link I just shared?". Team status, members, machines and tenants move to a Settings window. Built for a team of ten or more.
- Tone: a quiet native macOS utility. Gray when every link answers; one orange footer line when something needs a hand.
- Constraints: SwiftUI in an `NSPopover` on the status item, plus two windows (Settings, All links) and a Quick Look panel; the package stays `.macOS(.v13)` (DEC-42). The app reads `share state` and `share profiles --json`, and `share member ls --json` only while the Members tab is open (DEC-54 amends DEC-43). It never classifies state itself: it shows the CLI's sentence for a state and offers only the actions that state allows; a refusal shows the CLI's stable code as a sentence plus the next step (interactions doc, opening rule). SF Pro, SF Mono for hosts, ids and URLs, SF Symbols only, system light and dark.
- Differentiation: one list, one status line, one window for everything else; every confirm lists what stops and what keeps working, with real counts.
- Exclude: no route line, no needs-a-look strip, no grouping by origin or person, no members in the menu, no chips in menu rows (the meta line carries the state word), no color as the only state signal, no spinner without a step name, no confirm that hides what it stops.
- Persona: the tenant admin on a busy afternoon (three tenants, twelve members); a member who mostly needs their own links.

### Layout & structure
Surfaces and how they connect (each box is one view of the prototype):

```
 status item ──click──► Popover, 340 pt wide                     Settings window, 620 pt wide
 (dot when N > 0)        header: tenant ▾ · + · gear ─────────────► icon tabs: General · Tenants ·
 ⌃⌥S opens it with       search field (⌃⌥S hint)                    Members (admins) · Advanced
 search focused          Mine | Team (only when others' links exist)  Tenants: source list + detail, + and -
                         8 recent live links, newest first            Members: All / Needs a look / Removed,
                           click or Return: copy                      search, Invite…, row menu
                           Space: Quick Look ───────► Quick Look      sheets: add, progress, confirm, code,
                           drag out: the URL            panel         invite, remove, ask for the admin key
                           right click, More: row menu
                         Show all N links… ───────────────────────► All links window: tabs with counts,
                         footer: "All links answer" | "N need a look"  search, table, bulk Copy and Remove
                                       │
                                       ▼
                         Needs a look view: lines grouped by tenant, current first, one action each
 (no tenant)             first-run panel: Join a team with a code… / Set up my own hostname…
```

Popover regions, top to bottom: (1) header: the tenant button (host, a chevron when there is more than one; its menu lists each tenant with its role and a check on the current one, then "Manage tenants…"), + (file picker), gear (Settings); (2) search, filtering name and owner; (3) Mine | Team, Mine the default, remembered per tenant, hidden when every link is the viewer's; (4) the list: the most recent live links, newest first, 8 by default (General: 5, 8 or 12), expired links never shown here; (5) "Show all N links…"; (6) the footer status line, which a toast replaces for 3.5 s (6 s when it carries Undo). While a file is dragged over the status item or the popover, an overlay reads "Release to share on <host>" and "Stored on <machine>. Copies the link when done."; while a row is dragged out, the footer reads "Drop to paste the link to <name>".

Settings tabs (interactions doc 5 to 7): General (startup, menu scope, recent count, default expiry and storage written to the CLI config, after-sharing, notifications, the ⌃⌥S shortcut); Tenants (a source list with + and -, and a detail panel whose buttons come from role, tier and serve phase); Members (admins only); Advanced (CLI path, admin key source with Test, serve log, classic menu for one release, Copy share state as JSON).

All links window (interactions doc 3a): tabs All, Live, Needs a look, Expired with counts; search focused on open; columns Name (with created time and a state word), Owner, Lives on, Expires, Views (cloud links only), Copy; checkboxes with select all and a bar "N selected" with Copy links (one per line) and Remove (another member's link is revoked, not removed); expired rows dimmed with Copy disabled.

### Components & states
`PopoverState` (gap G1, DEC-44, DEC-70): one reducer in `ShareBarCore`, one swift test per transition. It holds one navigation mode from the table below plus two fields every mode handles: `pending: [Undo]` (each `{action, ids, deadline}`) and `publishing: [Publish]` (each `{file, step, of}`). An undo is not a mode: Remove, Revoke, the Delete key and a bulk Remove (from the popover or the All links window) append to `pending`; its deadline runs the CLI call once; Undo or ⌘Z cancels the newest with no call; popover close and app quit commit every pending undo at once. A publish is not a mode either: a file chosen with + or released on a drop appends to `publishing`, its row shows the step, and its exit copies the link or puts the CLI sentence in the footer, whatever mode is open then.

| Mode | Entered by | Left by |
|---|---|---|
| `firstRun` | every profile has `role` `none` | a profile gains a role |
| `list(scope, query)` | default; Back from `issues`; ⌃⌥S | footer button, a drag entering (`dropTarget`) |
| `issues` | the footer "N need a look" | Back, Esc, ⌃⌥S |
| `dropTarget(prev)` | an outside file drag enters the status item or the popover | release (append to `publishing`, back to `prev`), leave (back to `prev`) |
| `menu(id)` | right click, More, the ContextMenu key, Shift-F10 | an item, Esc, a scroll, a click outside |
| `quickLook(id)` | Space on a focused row | Space, Esc, Close, Copy link, Open in browser |

Link row: type glyph, name (middle truncation), one meta line, relative age, More on hover and focus. Meta line: the owner (Team only), where it lives (`this Mac`, `<member>'s machine` for v:3 per DEC-40, `cloud`), then the state word when the link does not answer, else time left (nothing for never, `live server` for a port share), then views for cloud links. Rules by `link_state` (gap G9, DEC-52):

| `link_state` | Meta word | Click or Return | Drag out | Row menu (items not allowed are hidden) |
|---|---|---|---|---|
| `live` | time left | copies; the row flashes "Copied" | yes | Copy link, Open in browser, Show in Finder (own link on this Mac), Refresh from source (only on the install that added it), Remove link… (own) or Revoke link… (admin, another member's link) |
| `offline` | offline | copies with "<machine> is offline: visitors get a 503 until it is back." | yes | as `live` |
| `paused` | paused | copies with "This member is paused: visitors get a 503." | yes | as `live` |
| `expired` | expired (All links window only) | never copies: "This link expired, so it no longer answers. Share the file again for a new link." | no | Show in Finder, Refresh from source, Remove link… (own) |
| `revoked` | removed by admin | never copies | no | Remove link… (own) |

Footer status line: "All links answer" (gray dot) or "N need a look" (orange, warning glyph); the status item shows a dot and its accessible label reads "Share Bar, N need a look". Needs a look lines and their single actions are the interactions doc section 4 table, in its order (interrupted commands, own serving problems, key problems, member problems); admins see team lines, everyone sees their own; lines group by tenant, the current tenant first with a "current" tag; an invited member is never a line.

Tenants detail: host with Open in browser, a status word with a dot (Serving, Starting with a spinner, Stopped: <reason>, Tunnel not connected, Interrupted), an interrupted-command callout with Roll back and Resume, then Your role, Storage, Members (not shown to members), Served from, Key (source and expiry). Buttons per the interactions doc section 5 table. A member whose `member.status` is `removed`, read from its own record, sees "You were removed from <host>" with Clean up (`share leave --local`) (gap G4, DEC-47, DEC-79); a key that is `expired` reads "Your key expired; ask the admin to renew it" and one that is `invalid` (a 401) reads "Your key stopped working; ask the admin", each with Copy request and never Clean up (DEC-79). Leave this tenant (-) stays an explicit action behind the impact sheet.

Members list: initials, name, a sub line (machine, last seen, code expiry, or the step of a running verb), a status chip (Invited info, Paused and Removed quiet, Left and a running or stopped verb attention) or the presence word (Online, Offline), the link count, and a row menu. The row menu lists exactly the verbs `member ls --json` reports in `can[]` for that member, the destructive one last after a separator (gap G10, DEC-53); a running verb shows "Pausing, step 2 of 3", a stale lease "Pausing stopped at step 2" with Finish.

Sheets (interactions doc 3b): add (Join a team | Set up a hostname), progress (each journal step done, now or pending; "Step n of m. Stopping keeps your place; Resume continues from this step."; Stop), confirm with an impact list (a cross for what stops, a check for what keeps working, real counts from `share state` rows), code (shown once, Copy code, Done), invite (name, "On their computer" or "In the cloud" with one-line consequences, code expiry 1, 7 or 30 days, "Nothing is sent from here."), remove member (their cloud links: keep until they expire, or delete now), remove tenant per role (refused for a tenant with members, gap G6), ask for the admin key (a secure field, used for one command, never stored, gap G3). Esc closes every sheet except progress.

### Responsive behavior
Fixed widths: popover 340 pt (list region up to 360 pt, then it scrolls), Settings and All links 620 pt, Quick Look up to 560 pt. The checked states are the prototype's four scenarios in light and dark; the HTML prototype at 390 px phone width is for the review page only. Every state an acceptance criterion names is captured by `mac/shots.sh` (TASK-4b4) after a real click, key press or drag, never by setting state in code (DEC-56).

### Accessibility targets
Contrast 4.5:1 for body text and 3:1 for glyphs, chips and the focus ring, in both appearances (the prototype's tokens were chosen to pass). Keyboard: ⌃⌥S opens the menu with search focused; arrows move rows; Return copies; Space opens Quick Look; Delete removes through the undo window; the ContextMenu key or Shift-F10 opens the row menu, which takes arrows and Esc; ⌘Z undoes; arrows move Settings tabs; focus is restored by id after every refresh. VoiceOver: a row's label is its name plus its meta line and exposes its actions; the status item label carries the count; the footer toast is a live region held while its Undo is focused. Reduce Motion turns the drop overlay into a fade.

### Design-system tokens (3-tier ladder)
Values are the prototype's `.mac` and `.mac.dark` blocks.
- primitive: system colors; label `#1d1d1f`, secondary `#5f5f64`, tertiary `#7a7a80`, dimmed `#66666b` (dark `#f5f5f7`, `#b0b0b6`, `#8a8a8f`, `#9a9aa0`); type 15 title, 13 body, 12 SF Mono, 11 meta; radius 6 buttons, 7 rows and fields, 4 chips; row height at least 40 pt; icon buttons 26 pt.
- semantic: `state-attention` systemOrange (ink `#8a4b00`), `state-error` ink `#a3190f`, `state-quiet` `#8e8e93` (ink `#4a4a4f`), `state-info` `#0060df` (ink `#0050b8`), `state-ok` `#28a745`, `focus` = `state-info`; `row-hover` label at 6%, `row-pressed` 10%, `selection` 8%.
- component: `chip-bg` = the state color at 14% (dark 24%), `chip-fg` = its ink; `toast-bg`, `toast-fg`, `toast-action`.
- dark mode overrides the semantic tier only. Orange marks only what needs a hand; red ink only the destructive action; accent only focus, selection, the primary button and progress.

### Content/copy
Voice: plain, not chatty; specific, not technical; calm, not alarming; short, not terse. The prototype holds the full copy; the interactions doc holds every refusal sentence.
| Context | Tone shift | Example |
|---|---|---|
| Everything answers | quietest | "All links answer" |
| Something needs a hand | names the count, then each line names its fact | "2 need a look", then "An's MacBook is offline: 2 links answer 503 until it is back" |
| Copy of a link that does not answer | the consequence | "Copied. An's MacBook is offline: visitors get a 503 until it is back." |
| A failure | what happened plus the next step | "Couldn't publish: the bucket refused the upload. Try again, or run `share status`." |
| Destructive confirm | lists effects with counts | "Stop serving s.console.so from this Mac?" then "4 links on this Mac stop answering until you start again" and "9 cloud and member links keep working" |
| Refusal | the rule and the way through | "s.console.so has members. Remove every member first; then this Mac can remove the tenant." with Open Members |
| Member invite | what the admin sends | "You get a one-time code to send them. Nothing is sent from here." then "Share Bar shows the code only now. If it is lost, send a new one." |

## Visual critique
Superseded by revisions 3 to 8 of `docs/design/share-bar-redesign.html`, each checked in screenshotted states reached through real interactions; the six-lens rounds below apply to revision 2.

Date: 2026-11-13
Visual source: scratchpad `share-design/share-bar-redesign.html` (round 0 prototype) and its headless screenshots
Lenses run: hierarchy/typography, system-consistency, accessibility/contrast, restraint/simplicity, expressiveness/brand-fit, persona (tenant admin on a busy afternoon); missing: none

### Critical findings
(none)

### High findings
1. The eye lands on the solid blue Share File button, not on the warning; the "one warm signal" rule is broken by orange, amber, red, blue and green competing. Found by: restraint, hierarchy, persona, brand-fit. Fix: Share File becomes a neutral bordered button in the status row; orange only marks what needs a hand; paused, offline, expired and invited chips go neutral; red only for the destructive state; accent blue only for focus, selection and progress.
2. One fact is said three to five times (offline in the status line, group chip, dimmed rows, members summary and member row; "expired" as chip and as trailing text; the host in tab, header and drop text). Found by: restraint, hierarchy, persona. Fix: one carrier per fact. The status line counts once, the group header owns origin state, a row chip appears only when the row differs from its group, the trailing column is blank for "never" and empty when a chip already says it, the host appears only in the switcher.
3. Chrome above the first link is about 210 pt and the members roster sits under a 420 pt list, so the popover reaches about 850 pt (cap 640) with two scroll regions. Found by: persona, restraint, hierarchy. Fix: merge status and tenant header; a "needs a look" strip under the status line lists each problem with one action; one scroll region holds links and a collapsed roster; the drop target appears only during a drag.
4. The origin idea reads as an ordinary grouping and the tenant header does not read like a route. Found by: brand-fit, hierarchy. Fix: a route line under the switcher (`s.console.so ▸ Mini · An · Bình · Dũng · Cloud`, attention origin warm, offline origins dimmed); group headers in label color, weight 600, written as a route ("→ An's MacBook"); distinct origin marks (filled for this Mac, outlined initials for members, dashed for cloud).
5. The brief's 3-tier token ladder is not built and type drifts across 7 sizes. Found by: system-consistency, hierarchy. Fix: primitive, semantic and component tiers with dark overriding the semantic tier only; type at 15 title, 13 body, 12 mono, 11 meta; spacing 4/8/12/16; radius 6 and 4; one origin-mark background token.
6. Light-mode contrast misses targets: secondary label 4.34:1, dimmed rows by opacity, green chip 4.19:1, white on the primary button 4.02:1, drop border and offline ring 2.2:1. Found by: accessibility. Fix: secondary label #5f5f64, dim by a fixed color, green ink #17692d, primary #0060df (dark #0a6fe0), tertiary #7a7a80 (dark #8a8a8f).
7. Keyboard and VoiceOver path incomplete: focus drops to body on every re-render, the kebab menu and tab list have no arrow or Esc handling, the toast is not a live region and hides its Undo after 5 s. Found by: accessibility. Fix: restore focus by id after each render; roving arrows and Esc in the menu and tabs; `role="status"` toast that holds while hovered or focused; rows expose their action and shortcut.

### Medium findings
1. The copy toast appears up to 600 pt from the clicked row and says only "Copied" for a link whose owner is offline. Found by: persona. Fix: flash a check on the row itself; for a dim row the toast adds "An's MacBook is offline: visitors get a 503 until it is back".
2. Tab attention is a 6 px dot with no count, glyph or accessible name; the menu bar badge is color only. Found by: accessibility, persona. Fix: a count with a warn glyph in the tab and in its accessible name; the status item gets a label.
3. Invited and Left count as "need a look", so the status line cries wolf. Found by: persona. Fix: split alerts (offline, paused, expired code, left awaiting removal) from information (invited).
4. Trailing columns and hover insets disagree between link rows and member rows; icon buttons come in two sizes. Found by: system-consistency. Fix: one trailing grid of 40 pt and one 24 x 24 icon button; equal row insets.
5. Copy button below the 24 pt minimum and invisible until hover. Found by: accessibility. Fix: 24 x 24, shown at 40% opacity at rest.

### Low findings
1. The footer sentence is filler when nothing is truncated. Found by: restraint, persona. Fix: show it only when rows are capped.
2. Hosts share the "s." prefix, so a long host truncates at the distinguishing tail. Found by: persona. Fix: truncate in the middle.

### Scores
- Hierarchy/typography: 6/10
- System-consistency: 6/10
- Accessibility/contrast: 5/10
- Restraint/simplicity: 5/10
- Expressiveness/brand-fit: 5/10
- Tenant admin on a busy afternoon (persona): 6/10

### Verdict: REVISE (round 1)

### Rounds
- Round 1 (prototype r0): REVISE. Scores 6 / 6 / 5 / 5 / 5 / 6. Seven HIGH findings above, all addressed in r1.
- Round 2 (r1): hierarchy 8 SOLID, system 8 SOLID, brand fit 7 SOLID, busy admin 8 SOLID, restraint 7 REVISE (route line repeats the group headers), accessibility 7 REVISE (dim text contrast, Undo unreachable by keyboard, live region rebuilt each render).
- Round 3 recheck of the two REVISE lenses (r2): restraint 8 SOLID (route line kept as the signature element, calm and hidden for one-origin tenants; orange only in the title glyph, strip tint and tab count); accessibility 8 with two small fixes applied after the recheck (dim text #66666b, the Undo hold timer).
- Final: SOLID on every lens after the two small fixes. Prototype: `docs/design/share-bar-redesign.html`.

### Deferred findings
- MEDIUM: the attention strip's 9% orange tint is a colored section background, which the brief's exclude list names; kept as the one warm carrier, revisit after use.
- MEDIUM: the tab truncates the host from the left ("...console.so"); keeps the distinguishing tail, clips the brand prefix.
- MEDIUM: the strip adds about 90 pt above the first link in a busy state; capped at 3 rows.
- LOW: copy icons rest at 40% opacity on every row (accessibility wants them visible; hierarchy would show them on hover only).
- LOW: blue Uploading and red Removed chips remain beside the gray set.

## Task Breakdown

Each task lands with its tests on the existing seams. Edge-case ids name the rows each task must turn green; tests are labeled `mm <id>: ...` in `tests/share.sh` and `v5 <id>: ...` in `tests/worker.mjs`.

Edge-case rows no task AC named before round 1 of validation, now owned: OC-05, FG-12, OT-07, OT-13, OT-18 by TASK-0d; LK-13 and OT-01 by TASK-0d (Worker side) and ML-9 (live); CC-01, CC-12, CK-03 by TASK-1f3; CC-05 by TASK-1g; CC-04, OT-08, OT-09, OT-11, OT-12, OT-17 by TASK-2d; CK-02, CK-06 by TASK-2b; CK-05 by TASK-2c; FG-08 by TASK-1h; OT-10 by TASK-3c; OT-15 by TASK-1c1.

### SPEC-010 tasks each task needs

A SPEC-009 task starts only when every SPEC-010 task in its row has shipped (DEC-68). A builder who finds one missing stops; it never writes its own copy.

| SPEC-009 task | Needs (SPEC-010 phase) | Fallback when absent |
|---|---|---|
| TASK-0c | G7 `link_state` (Phase 2) for the `revoked` value | lands `origin` and the readers only; the `link_state` values wait for G7 |
| TASK-0f | G4 (Phase 1) | none |
| TASK-1c1, 1c2, 1f1 to 1f3, 2a, 2d, 3a to 3e | G1, G2a, G13 `admin_token_resolve` (all Phase 1) | none |
| TASK-1d | G1, G2a, G3, G4 (Phase 1), and SPEC-009 TASK-1c2 (the lease) | none |
| TASK-1h | G1, G2a, G3, G4 (Phase 1) | none |
| TASK-1e, 1g | G1, G3 (Phase 1); 1g's SV-25 also G7 (Phase 2) | SV-25 waits for G7 |
| TASK-1i | G1, G2a, G13 (Phase 1); G10's `.health` per-key writer (Phase 2) for the `members` key | the task lands the per-key writer for the `members` key only |
| TASK-2e, 3d | G10 `.health` (Phase 2) | the task lands the `.health` writer for R7 only |
| TASK-4a | G1 (Phase 1) | none |
| TASK-4b1 to 4b23 | G6, G7, G9, G10, G11a, G11b, G11c, G14 (Phase 2); G13 (Phase 1) | the per-key fallback of the TASK-4b rule |
| TASK-4b18 | G2b, G2c (Phase 1) | none |

### Phase 0: Groundwork (helps with no members; one release, Worker v5)

Phase 0 ships before TASK-1a's samples on purpose: a T1 tenant holds no v:3 pointer, `vpc_service` binding or `i/` object, so the new Worker branches are inert until the first T2 tenant, and TASK-1a runs before that. A sample that disagrees with the documented shape lands as a Worker v6 fix in Phase 1.

- [x] TASK-0a: CLI version constant. `SHARE_VERSION=0.9.0` near the top of `bin/share`, `share version`, and `bin/release` rewrites the constant in the release commit. AC: `share version` prints `X.Y.Z`; a suite check finds it equal to the newest `## [vX.Y.Z]` heading in `CHANGELOG.md`; OT-19.
- [x] TASK-0b: Caddy serves listed rows only. `write_caddyfile` renders, per live non-revoked snapshot row, a matcher on `/<id>` and `/<id>/*` with `root * "$pub"` and the existing `file_server`; the catch-all `handle` answers 404; every response carries `X-Share-Served: caddy`; `rows_in` accepts `revoked` and `revoked_by=`. AC: SV-01 to SV-05; SPEC-008 compat row 1 updated to expect the new Caddyfile and nothing else.
- [x] TASK-0c: readers (built with the gate table's fallback: `origin` and the readers; the `link_state` values wait for SPEC-010 G7). `r2_record_raw` treats any `storage:"machine"` record with no `prefix` and `v >= 2` as readable (the sweep no longer blocks); `r2_take` validates v:3 into the display rows with `origin`; the origin's reap list stays v:2; `rand_id` refuses an id with a `t/<id>`; `state` rows gain `origin`, and, once SPEC-010 G7 has shipped, SPEC-010's per-row `link_state` gains `revoked` (opts `revoked`, `reason` `revoked_by=<by>`); `paused` and `offline` come from the members cache (TASK-1i, DEC-71). `state` stays `schema: 1` and gains no `state.state` value (DEC-32). AC: SV-06 to SV-09, OC-01, OC-06, OC-08, RC-14, FG-16; `state_schema_ok` (tests/share.sh L1000) passes unchanged on every new fixture.
- [x] TASK-0d: Worker v5, every row of `### API changes`, one version bump, built as the pure `decide()` with named rows and the uniform 404 body (DEC-38). `tests/worker.mjs` gains a fake `vpc_service` binding (records each request, answers from a fixture or throws) and an R2 fake honoring `onlyIf.etagMatches`, and asserts the row id of every request, not only its status. AC: SV-10 to SV-24, SV-26 to SV-28, FG-12, OC-05, OT-07, OT-13, OT-18; SV-23 also covers `application/xhtml+xml`, `text/xml`, `text/html; charset=utf-8`, an answer with no type, a `Set-Cookie` and an off-path `Location` from the binding, and a cloud `.html` on a `MEMBERS=1` tenant; existing rows pass unchanged on the v5 source.
- [x] TASK-0e: deploy carry-forward. `r2_deploy_meta` takes the deployed bindings (from the settings GET every deploy path already makes) and re-sends each `vpc_service`, `MEMBERS` and `PAUSED`, plus a fresh `DEPLOY`; the deploy compare adds the binding set, `MEMBERS` and `PAUSED`; `setup --force` that would lower `WORKER_VERSION` is refused while the settings carry a `vpc_service` binding, `MEMBERS`, or a non-empty `PAUSED`, or the marker holds `members:true` (a T2 tenant with cloud members only still needs the redeem route); the dry seam keeps these bindings in `script.json`; deploy waits for `X-Share-Deploy` 3x. AC: DY-01 to DY-05.
- [x] TASK-0f: member config keys ride the key-keeping writer (DEC-34). Requires SPEC-010 G4 (`config_put`). Every writer a SPEC-009 path adds or touches (`setup --members`, `--no-members`, join's config write, `leave`) calls `config_put` with its owned set; no new whitelist writer. AC: a config holding `members=on`, `role=member`, `member_id=m-an-aaaaaaa1`, `member_mode=machine` keeps all four lines byte for byte across a `setup <host>` rerun and an `api-token --cmd '<cmd>'` write; TN-10.

### Phase 1: Tenant, lease, registry, add, join, ls, sync

Phase 1 starts only after SPEC-010's Phase 1 (G1, G1b, G2a to G2c, G3, G4, G5, G13) has shipped: TASK-1c1, 1c2, 1e, 1h and 1i call `die_code`, the step journal, `profile_role`, `config_put` and `admin_token_resolve` (`### SPEC-010 tasks each task needs`).

- [ ] TASK-1a: residual live samples on Console Labs, throwaway `share-e2e-*` names, cleanup asserted by name. (a) VPC Service create, get, list, update, delete over REST with an API token, and the token permission-group names that allow it; (b) a multipart deploy with a `vpc_service` binding entry, the settings GET shape of that binding, and that a deploy without it drops it; (c) the minter mints a token with Workers R2 Storage Bucket Item Write on one `share-e2e-*` bucket plus Zone Read, its S3 pair does `PUT If-None-Match`, `PUT /user/tokens/<id>` moves `expires_on`, `DELETE` revokes it; the per-user token count limit; (d) the binding fetch with the member's cloudflared stopped, with Caddy stopped, and with a non-Caddy listener on the port: throw or status, and how long; (e) a deploy with 25 `vpc_service` bindings; (f) `GET .../connections` with one cloudflared: connector count vs `conns`; delete connections, then the tunnel; (g) a fresh remote-managed tunnel with only the catch-all over REST, and `GET .../token`; (h) R2 binding `put` with `onlyIf.etagMatches` on a stale etag returns null. AC: each answered in `docs/implementation-notes/multi-member.md` with the masked excerpt; (a), (b) or (c) failing stops Phase 1 and amends `## Design`; (e) failing lowers the cap to the measured value.
- [x] TASK-1b: dry seams. `r2_api_dry` answers tunnels, configurations, connections, token, Connectivity Directory services and `/user/tokens` from state files under `.cf/`, each call one `API <METHOD> <path>` line in `r2-calls.log`, all failable through `SHARE_R2_DRY_FAIL` and `SHARE_R2_DRY_FAIL_TIMES`; `SHARE_TEST_MEMBER_IDS` and `SHARE_TEST_CODE` make ids and codes deterministic (as `SHARE_TEST_IDS`, L160); `SHARE_R2_DRY_WORKER` names a command (the suite sets `node tests/worker.mjs --dir <dry> --host <h>`) that answers dry redeem and probe requests, and `tests/worker.mjs` integration mode gains `--post <path> <body>` and `--bind M_<hex>=127.0.0.1:<port>`. AC: seam self-checks in a new `=== members: dry seams ===` section; every seam refuses outside `SHARE_TUNNEL=0` and a `.test` host, as `r2_api_dry` does (L3612).
- [x] TASK-1c1: admin context (DEC-77). `cmd_member` dispatcher; tenant from `--tenant` or profile; the admin token from SPEC-010 G13's `admin_token_resolve` (`CLOUDFLARE_API_TOKEN`, else `admin_token_cmd`; gap G3, DEC-46), proven by settings GET 200; bucket name from the `BUCKET` binding; marker check; the minter token from SPEC-010 G13's `minter_token_resolve` (`SHARE_MINTER_TOKEN`, else `minter_token_cmd`), resolved only on the minter paths `member add`, `invite`, `rotate`, `renew`, `rm` and `adopt` (DEC-80); scope probes before the first write (each missing scope named). Bucket calls with the admin token preset the admin S3 pair as `cmd_setup_tenant` does, because `r2_creds` refuses an admin token as a publisher. Every refusal is a `die_code` code (DEC-35). AC: CC-13, WM-03, MB-04, OT-15, OT-16; every refusal in this task's tests, rerun with `SHARE_ERROR_JSON=1`, ends with one JSON line whose `code` is in `share state-fn codes`; with `CLOUDFLARE_API_TOKEN` unset and `admin_token_cmd` set to a fixture command, `member ls` runs the command once and proves admin, and with both unset it dies `admin_token_missing` before any bucket or API call; with `SHARE_MINTER_TOKEN` unset and `minter_token_cmd` set to a fixture command that touches a marker, `member ls` leaves the marker absent and `member renew` runs the command once.
- [x] TASK-1c2: the admin lease (DEC-77). `lease_take`, `lease_renew` before each Cloudflare step (If-Match on its own last etag; 412 dies `lease_lost`), `lease_release` (only after a GET shows its own nonce), takeover rules (DEC-63). The lease body names `verb`, `member` and `step`, rewritten by each `lease_renew` (DEC-36). Needs TASK-1c1. AC: CC-09, CC-10, CC-15, CK-01, FG-10; CC-09 also asserts the `lock/admin` body names the verb, member and step of the killed holder.
- [x] TASK-1d: tenant T1 to T2 and back. `setup <h> --r2 --bucket B --members [--yes]`, `--no-members`, and the T2 refusals in teardown, migrate, `--no-r2`. T2 is config `members=on` OR marker `members:true`; the refusals read the marker; a disagreement sets `state.tier_drift` and reports `config_drift` with its repair line (DEC-33). On T2 every deploy path (a `setup --r2` rerun, `--alias`, `--members`, `--no-members`, every member verb) takes `lock/admin` first, then builds its deploy body from a settings GET made after `lease_take`, and holds the lease through the nonce wait (DEC-62); a settings read made before the lease is used for refusals only. Teardown on T2 refuses with `die_code members_present "<host> has members; remove every member first" "share member ls"` (gap G6, DEC-49). `--members` and `--no-members` run as the journaled verbs `setup-members` and `no-members` (SPEC-010 G2a), one `op_step` per write, so the Share Bar's Turn on members shows the steps and Stop then Resume continues (gap G7, DEC-50). AC: TN-01 to TN-09 (TN-09 with its marker-then-config die row), TN-11, TN-12, CC-14; TN-07 asserts the code `members_present` under `SHARE_ERROR_JSON=1`; the die-point loop (kill at each `op_step`, rerun, happy end state, empty `ops/`) for `setup-members` and `no-members`.
- [x] TASK-1e: registry. `u/` reader and validator (a record failing validation is reported, never trusted), member_id generation unique against records, `u/purged.json`, live bindings and account services; `member_can`, the `case` table of `### Member status transitions` (DEC-29); `reg_status` (If-Match through `member_can`; re-read once on 412 and continue only if `member_can` still allows the move from the new status); the `prev_status` rule (DEC-41); `step`/`step_name` on every `...ing` write (DEC-31). `share state-fn member-can <status> <verb> <actor> [mode]` exposes it. member_id generation refuses an 8-hex suffix that any record, `u/purged.json` id, binding or service already uses (DEC-60). AC: MB-03, MB-24, MB-25, FG-05 to FG-07, FG-13; `mm member_can: every (status, verb, actor, mode) tuple` iterates all 14 x 12 x 2 x 2 tuples (13 stored statuses plus none) and matches the doc table, with `rm` and `sync` excepted from `member_busy` and `pause`, `resume`, `rotate` refused for mode `cloud`.
- [x] TASK-1f1: Cloudflare object helpers (DEC-69). Tunnel, VPC Service and user token: create, find by name, delete, each idempotent and each on the TASK-1b seams; a record id is used only after a GET by that id returns the expected name (invariant 8, DEC-58); the token helpers find a token only by its name `share <host> <member_id>` in the current minter's `GET /user/tokens` and report a miss as `token_unreachable` with the token's `expires_on` (DEC-78); no create is retried automatically (a rerun finds it by name). Needs TASK-0e and TASK-1a (a) to (c). AC: FG-15; a seam self-check per helper (create twice finds one object; delete of a missing object is done); a forged record id naming another object is ignored.
- [x] TASK-1f2: invite seal and unseal (DEC-14, DEC-69). `invite_seal` and `invite_open` with the passphrase on fd 3 and encrypt then MAC; the code from `/dev/urandom`. AC: a roundtrip on both CI runners; a flipped byte in `sealed` or `mac` dies `invite_tampered` before any decrypt; Q-SEC-6: the test shims `jq`, `openssl`, `security`, `curl` and `cloudflared` on PATH, logs every argv, and greps it and all stderr for the fixture code and tokens.
- [x] TASK-1f3: `member add` (both modes), the step table above, built on TASK-1f1 and TASK-1f2 (DEC-69). AC: MB-01, MB-02, MB-05, CC-01, CC-12, CK-03, DP-add-1 to DP-add-9, Q-SEC-6 grep of argv and logs.
- [x] TASK-1g: R7. Detector (the `member` row of SPEC-010's `profile_role`), `member_mode`, every row of the `r2on` table, the v:3 pointer writer, member add/rm/refresh of own machine links, refusals. On R7, `r2_take` puts only own-origin v:3 pointers into `r2_machine`, and `r2_pointer_write` writes v:3 with `origin`, never v:2 (DEC-65), landed here because R7 runs `prune` from this task on. AC: LK-01 to LK-07, LK-13, LK-17, LK-18, WM-01, WM-02, CC-05, OT-05, RC-15, SV-25 (once G7 has shipped).
- [x] TASK-1h: `join` and its bare resume, recorded in the `join` journal (SPEC-010 G2) and resumed from the journal step, never from file presence (DEC-31); the re-join on an R7 profile of the same member_id, and join's final write restoring `prev_status` (DEC-30); the invite and join refusal table, each row a `die_code` code (DEC-37). AC: MB-06, MB-07 (one code asserted per refusal, `member_needs_keychain` included), MB-26, MB-27, MB-32, DP-join-1 to DP-join-6, CC-11, FG-08, OT-04, OT-06.
- [x] TASK-1i: `member ls` and `member sync` (with `--rebind`, expired-invite delete). `member ls` prints, per record in an `...ing`, `<name>: <status>, step <n> of <m> (<step_name>), lease held by <holder> (live)` or `(stale since <time>; rerun: share member <verb> <name>)` (DEC-36); `--json` adds `step`, `step_name`, `lease`, and `can[]` (gap G10, DEC-53); `drift[]` entries are codes (DEC-35); `member ls` writes the `members` key of `.health` and `state` reads it into `link_state` `paused` and `offline` (DEC-71); sync's from-set (DEC-72). AC: MB-08, MB-20, MB-22, MB-23, MB-28, MB-29, MB-33, MB-35, OC-03, FG-05, FG-06.

### Phase 2: rm, leave, purge, tombstones, the member reconcile loop

- [x] TASK-2a: admin revoke. `rm <id>` on a v:3 of another origin with the admin token proven: `t/<id>` (If-None-Match), DELETE pointer, proof GET 404, message "revoked; the bytes stay on <name>'s machine"; without the admin token refused; v:2 from a non-origin refused. AC: LK-08 to LK-10, LK-19, WM-04.
- [x] TASK-2b: reconcile, every row of the table above, and the tombstone sweep in `member sync`. AC: RC-01 to RC-14, LK-16, CC-06 to CC-08, CK-02, CK-06, FG-01 to FG-04, FG-11, FG-14, OC-02; CC-06 pauses reconcile between its `m/` list and its `t/` read with the revoke's two writes landing in each order.
- [x] TASK-2c: member serve loop. On R7, `cmd_serve` keeps `SHARE_API_TOKEN_OFF=1` for Access and runs `share prune --loop` hourly, which resolves the publisher token from the Keychain only and runs local expiry, own pointer expiry and reconcile; a locked Keychain logs one line and skips. AC: LK-11, LK-12, CK-05, OT-02, Q-OPS-1.
- [x] TASK-2d: `member rm` and `member purge`, objects found by name (DEC-58), the token step's name lookup and its `token_unreachable` report (DEC-78). AC: MB-13, MB-16, MB-34, DP-rm-1 to DP-rm-8, LK-15, FG-15, CC-04, OT-08, OT-09, OT-11, OT-12, OT-17, Q-SEC-5 (dry listing of every object kind empty for the member).
- [x] TASK-2e: `leave`, `leave --local`, and what member `status` reports. `status`, join and the member loop write what they read to the `.health` cache, so `state` makes no network call. A record read as `removed` sets `state.member.status` `removed`, and the Share Bar shows "You were removed" with Clean up (gap G4, DEC-47). A 401 never infers removal (DEC-79): it sets `state.token.status` `expired` when the local `token_expires` is past, else `invalid`, with the copy `your key stopped working; ask the admin` (`expired` names `share member renew <name>`), and never Clean up. AC: MB-14, MB-15, MB-21 (also asserts `state.member.status` after `status` in both cases), MB-30, MB-31, DP-leave-1 to DP-leave-3, OT-03.

### Phase 3: pause, resume, rotate, invite, renew, adopt

- [ ] TASK-3a: `pause`, `resume`. AC: MB-10, MB-11, LK-14, CC-02, DP-pause-1, DP-pause-2.
- [ ] TASK-3b: `member invite`. AC: MB-09, DP-invite-1 to DP-invite-3.
- [ ] TASK-3c: `rotate`, ending in `invited` with `prev_status` kept (DEC-30), also from `invited` and `joining` (DEC-67). AC: MB-12, MB-26, MB-36, OT-10, DP-rotate-1 to DP-rotate-4, CC-03, OT-14; DP-rotate rows end with a re-join that asserts the record returns to the status rotate started from.
- [ ] TASK-3d: `renew` and expiry warnings. On R7, `state.token = {source, status, expires_on}` in SPEC-010's D5 shape, read from the `.health` cache that join, `status` and the member loop write (SPEC-010 G10; if G10 has not shipped, this task lands the cache writer for R7 only), so MB-19's warning reaches the Share Bar, not only `status` (DEC-39). AC: MB-18, MB-19 (also asserts `state.token.status` is `expiring` with `expires_on`), MB-37, CK-04; `state` still writes nothing and makes no network call.
- [ ] TASK-3e: `adopt`. AC: MB-17, OC-07.
- [ ] TASK-3f: WebSocket and streaming through the binding (live, Console Labs). Pass: member `add <port>` renders `handle_path /<id>/*` to the port, the Worker forwards an `Upgrade` request for a v:3 `live` pointer and returns the 101 untouched, and `live` joins the v:3 opts; fail: the refusal stays and the result is recorded. AC: LK-02 in the branch taken; the live result in the implementation notes.

### Phase 4: min_cli, Share Bar, docs, live acceptance

- [ ] TASK-4a: `min_cli` enforcement. Every bucket write on a v0.10+ CLI reads the marker once per process; below `min_cli` it refuses writes with `die_code cli_below_min` ("upgrade share to <min_cli>; <host> requires it") and allows reads (DEC-35). AC: OC-04, FG-09; with `SHARE_ERROR_JSON=1` the last stderr line parses as JSON with `code` `cli_below_min`.

TASK-4b, the Share Bar, is twenty-three atomic tasks that build revision 8 (`## UI design`, `docs/design/share-bar-redesign.html`, `docs/design/share-bar-interactions.md`) in SwiftUI. Cites use the audit's form: `MM:` `MenuModel.swift`, `PB:` `Publish.swift`, `MO:` `MutationOutcome.swift`, all under `mac/Sources/ShareBarCore/`. Rule for every one of them: when a new `state` key is present the app uses it; when it is absent (an older CLI) the app falls back to today's derivation (`Health.of` MM:L31-39, `PublishChoice.isEligible` PB:L44-56, the expiry rule MM:L117-128); Swift mirrors display rules only, never classification (audit X5). Swift tests live in `mac/Tests/ShareBarCoreTests`; new fixtures in `mac/Tests/ShareBarCoreTests/Fixtures`. Package platform stays `.macOS(.v13)` (DEC-42). Every command the app runs is spawned with argv only; a token reaches a child through its environment only (Q-SEC-6). Phase 4 needs SPEC-010 G6, G7, G9, G10, G11a to G11c, G13 and G14 shipped.

Every TASK-4b AC ends with the same two lines, written out in each task: `swift build --package-path mac`, `swift test --package-path mac` and `bash mac/build.sh 0.0.0` pass; and the shipped Share Bar keeps working against the new CLI (`bash mac/compat-check.sh v0.9.0` exits 0, built in TASK-4b1). A UI state named in an AC is verified by a screenshot of that state reached through a real interaction: `mac/shots.sh` (TASK-4b4) launches the built app against a fake CLI scenario and reaches the state with clicks, key presses or drags sent through the Accessibility API; a state set in code is not evidence (DEC-56). Screenshots land in `docs/verification/share-bar/<task>-<state>-<light|dark>.png` and are listed in `docs/verification/multi-member.md`.

- [ ] TASK-4b1: decode the new keys and the compat check. `Snapshot`, `ProfileState` and `Share` gain optional `role`, `tier`, `serve {phase, reason}`, `ops [{verb, step, of, name, alive, rerun, rollback}]`, `token {source, status, expires_on}`, `compat {cli, worker, status, min_cli}`, `member {id, name, mode, status, step, token_expires}`, and per row `link_state`, `reason`, `origin`, `views`; a `MemberList` type decodes `share member ls --json` with `can[]` (TASK-1i); a `Progress` type decodes SPEC-010's `{"progress":{verb, step, of, name}}` stderr line. Uses SPEC-010 G11's types where shipped; owns any key G11 has not landed. `mac/compat-check.sh <tag>` builds the `ShareBarCore` sources of a release tag in a temp package and decodes every new-CLI fixture with them. AC: swift test rows `decode: every new key present` (new fixture `state-full.json`), `decode: every new key absent` (the existing `state.json`, `profiles.json`, `profiles-tenant.json` decode to the same values as today), `decode: an unknown extra key is ignored`, `decode: member ls --json with can[]`, `decode: progress line`; `bash mac/compat-check.sh v0.9.0` decodes every fixture HOME's `profiles --json` and `state` output from the new CLI with no profile mapped to `.error` or to "Update Share Bar" (OC-06, Q-COMPAT-3); `swift build --package-path mac`, `swift test --package-path mac` and `bash mac/build.sh 0.0.0` pass; the shipped Share Bar keeps working against the new CLI.
- [ ] TASK-4b2: derivation in `ShareBarCore`, pure. `ProfileView` computes the serve sentence from `serve.phase` when present (`worker_down` reads `Worker not answering`, `failed` reads `Stopped: <reason copy>`, `elsewhere` reads the hosts line), else `Health.of`; publish eligibility from `role`, `member.status`, `token.status` and `compat.status` with a reason (`migrated` reads `Moved to another machine`, neutral; `paused`, `left`, `removed`, token `expired`/`invalid`, `cli_below_min` are ineligible with their copy), else today's rule; `LinkView` builds the meta line of `### Components & states` (owner in Team, where it lives with the v:3 word `<member>'s machine` (DEC-40), the state word or time left, views on cloud rows); `StorageField.member` renamed `cloudOnly` (source only, no wire key). AC: table-driven swift rows, one per `serve.phase`, one per `role`, one per ineligible reason, one per `link_state` for the meta line, plus the row with no `link_state` or `origin`; `StateMappingTests` and `PublishFormTests` pass unchanged on fixtures without the keys; `swift build --package-path mac`, `swift test --package-path mac` and `bash mac/build.sh 0.0.0` pass; the shipped Share Bar keeps working against the new CLI.
- [ ] TASK-4b3: `PopoverState` (gap G1, DEC-44, DEC-70). One reducer `reduce(state, event) -> (state, [effect])` over a navigation mode (`firstRun`, `list(scope, query)`, `issues`, `menu(id)`, `quickLook(id)`, `dropTarget(prev)`) and two fields every mode handles, `pending: [Undo]` and `publishing: [Publish]` (`### Components & states`); popover close and app quit commit every pending undo at once; effects are values (`run(argv)`, `copy(url)`, `focus(id)`), never side effects, so a test can assert that an undone Remove never emits `run`. AC: one swift row per row of the transition table, plus `undo deadline emits run once`, `undo or ⌘Z emits no run`, `drop leave returns to the previous state`, `publish failure puts the sentence in the footer and keeps the mode`, `⌃⌥S from issues lands in list with search focused`, `close during undo emits run once`, `a second Delete keeps both undos`, `menu and Quick Look during publishing keep the upload`, and `the reducer's table equals the spec table` (a row iterates both); `swift build --package-path mac`, `swift test --package-path mac` and `bash mac/build.sh 0.0.0` pass; the shipped Share Bar keeps working against the new CLI.
- [ ] TASK-4b4: screenshot harness and fake CLI. `mac/Tests/fixtures/bin/share` is a fake CLI that answers `profiles --json`, `state`, `member ls --json` and every mutating verb from a scenario directory (`admin` with three tenants and twelve members, `member`, `calm`, `firstrun`, the prototype's four Scenario buttons, plus `cli-old`), prints `SHARE_PROGRESS` lines with a delay for journaled verbs, and appends each argv to `argv.log`; `mac/shots.sh <scenario> <step file>` builds the app, starts it with `SHARE_BIN` pointing at the fake (CLI.swift L27), replays the steps (click a named control, press keys, drag from Finder) through the Accessibility API, and captures the frontmost Share Bar window with `screencapture -l` in light and dark. AC: `bash mac/shots.sh calm open-popover` writes the popover state, verified by a screenshot of that state reached through a real interaction (a click on the status item); negative control: a step naming a missing control fails the run with the control's name and writes no image; a step file that removes a link leaves `rm <id>` in `argv.log`; `swift build --package-path mac`, `swift test --package-path mac` and `bash mac/build.sh 0.0.0` pass; the shipped Share Bar keeps working against the new CLI.
- [ ] TASK-4b5: tokens and state words. `Tokens.swift` with the three tiers of `### Design-system tokens` (dark overrides the semantic tier only); `StateWord` gives an SF Symbol and a word for every `link_state` and every member status. AC: swift rows `every link state has a symbol and a word`, `every member status has a symbol and a word`, `dark overrides only semantic tokens`, `every text token pair meets 4.5:1 and every glyph, chip and focus pair 3:1 in both appearances` (computed from the token values); `swift build --package-path mac`, `swift test --package-path mac` and `bash mac/build.sh 0.0.0` pass; the shipped Share Bar keeps working against the new CLI.
- [ ] TASK-4b6: the popover shell. `StatusItemController` replaces the `NSMenu` with an `NSPopover` holding an `NSHostingController` of `ShareBarView`, driven by `PopoverState`; the header (tenant button and its menu with "Manage tenants…", +, gear), 340 pt wide, the list region scrolling past 360 pt; the status item dot and accessible label; the defaults key `LegacyMenu` (the Advanced checkbox, TASK-4b15) builds today's `MenuModel` for one release (DEC-42). AC: swift rows `the view model lists header, search, scope, list, show all, footer in order` (from `state-full.json`) and `LegacyMenu builds today's MenuModel`; screens `calm popover` and `admin tenant menu open, current tenant checked`, each verified by a screenshot of that state reached through a real interaction; `swift build --package-path mac`, `swift test --package-path mac` and `bash mac/build.sh 0.0.0` pass; the shipped Share Bar keeps working against the new CLI.
- [ ] TASK-4b7: recent list, search, Mine and Team. The most recent live links, newest first, capped by General's count (5, 8, 12; default 8); expired rows never in the menu; Mine the default, Team adds the owner to the meta line, the choice remembered per tenant, the control hidden when every link is the viewer's; search filters name and owner (`No links match "<q>".`); an empty tenant reads `No links yet. Drop a file on the menu bar icon to share it.`; "Show all N links…" opens the All links window (TASK-4b20). AC: swift rows `mine hides others`, `team adds the owner`, `scope remembered per tenant`, `scope hidden when every link is own`, `search matches name and owner`, `cap follows General`, `expired never in the menu`; screens `admin Mine`, `admin Team`, `search with a match`, `search with no match`, `member scenario`, `calm without Mine and Team`, each verified by a screenshot of that state reached through a real interaction; `swift build --package-path mac`, `swift test --package-path mac` and `bash mac/build.sh 0.0.0` pass; the shipped Share Bar keeps working against the new CLI.
- [ ] TASK-4b8: Needs a look. An `Issues` model built from `serve`, `ops`, `token`, `member` and, on the admin's Members data, member records, one line per row of the interactions doc section 4 table in its order, each with exactly one action mapped to its command (Resume: the journal's `rerun`; Start: `share start`; Renew: `share member renew <me>` for an admin, `share api-token` for an owner, "Copy request" for a member; Open: Settings > Members with the member selected; Resume member: `share member resume <name>`; Remove: the remove sheet; Send a new code: `share member invite <name>`; Finish: the stopped verb; Clean up: `share leave --local`); lines grouped by tenant, current first with a `current` tag; the footer reads `All links answer` or `<n> need a look`; the status item dot and label carry the count; an invited member is never a line. AC: swift rows one per section 4 line, `invited is not a line`, `line order`, `current tenant first`, `each action maps to its argv`; with the fake CLI, pressing Resume on the interrupted line leaves the journal's `rerun` argv in `argv.log`; screens `footer all answer`, `footer 4 need a look`, `issues view with three tenants`, `issues view empty: Nothing needs a look.`, `status item with its dot`, each verified by a screenshot of that state reached through a real interaction; `swift build --package-path mac`, `swift test --package-path mac` and `bash mac/build.sh 0.0.0` pass; the shipped Share Bar keeps working against the new CLI.
- [ ] TASK-4b9: link actions and the row menu (gap G9, DEC-52). Click and Return per the `link_state` table of `### Components & states` (flash, the offline and paused warnings, expired and revoked never copy); the row menu shows only the items the table allows, anchored to More, the pointer or the row, opening upward when there is no room below and staying inside the popover, closing on scroll; Remove, Revoke and the Delete key append to `pending` for 6 s (DEC-70) (held while Undo has focus; ⌘Z undoes), then run `share rm <id>` once (an admin's rm of another member's v:3 link is a revoke, TASK-2a: "The file stays on <machine>."); Show in Finder reveals the row's `pub/<id>`; Refresh runs `share refresh <id>` only on the install that added the link. AC: table-driven swift rows `row menu items per link_state and role`, `remove waits for the undo window`, `undo cancels the CLI call`, `hold while Undo is focused`, `revoke argv for another member's link`; with the fake CLI, an undone Remove leaves no `rm` in `argv.log` and a completed one leaves exactly one; screens `row menu on an own live link`, `row menu on another member's link as admin`, `undo footer after Remove`, `copy warning on an offline link`, each verified by a screenshot of that state reached through a real interaction; `swift build --package-path mac`, `swift test --package-path mac` and `bash mac/build.sh 0.0.0` pass; the shipped Share Bar keeps working against the new CLI.
- [ ] TASK-4b10: publish and drop in. + opens a file picker; a file dragged from outside onto the status item or the popover enters `dropTarget` with the overlay naming the host and the storage (General's default, `on this Mac` when the tenant has no cloud storage); release or a picked file runs `share add <file>` with `SHARE_PROGRESS=1`, and the placeholder row shows the add journal's step (SPEC-010 G9) with a progress bar; success copies the link and flashes the new row; failure shows the CLI sentence and `next`. AC: swift rows `progress lines move the publishing entry's step`, `a drop with no tenant is refused with the first-run panel`; with the fake CLI, a drop leaves `add <path>` in `argv.log`; screens `drop overlay during a drag from Finder`, `uploading row at step 2`, `new row flashed after publish`, each verified by a screenshot of that state reached through a real interaction; `swift build --package-path mac`, `swift test --package-path mac` and `bash mac/build.sh 0.0.0` pass; the shipped Share Bar keeps working against the new CLI.
- [ ] TASK-4b11: drag a row out. A `live`, `offline` or `paused` row drags as an `NSItemProvider` carrying the link URL as a URL and as plain text; the footer reads `Drop to paste the link to <name>` during the drag; `expired` and `revoked` rows do not drag; an internal drag never enters `dropTarget`. AC: swift rows `the drag item carries the URL as url and text`, `expired and revoked do not drag`, `an internal drag never enters dropTarget`; screens `footer hint during a drag out` and `the URL pasted in TextEdit after the drop`, each verified by a screenshot of that state reached through a real interaction (a harness drag); `swift build --package-path mac`, `swift test --package-path mac` and `bash mac/build.sh 0.0.0` pass; the shipped Share Bar keeps working against the new CLI.
- [ ] TASK-4b12: Quick Look. Space on a focused row opens a non-activating panel (up to 560 pt): Close, the name, Open in browser, Copy link (default button), a preview, the URL in SF Mono and the meta line; a row whose bytes are on this Mac previews `pub/<id>` through `QLPreviewView`; a port share shows `Live server` and what answers on its port; any other row (cloud, another member's machine) shows its glyph and meta with no network fetch (DEC-55); Space or Esc closes and returns focus to the row; Copy link closes and copies. AC: swift rows `preview source per row kind` and `close returns focus to the row id`; screens `Quick Look on a local PDF`, `on a folder`, `on a port share`, `on a cloud link`, each verified by a screenshot of that state reached through a real interaction (Space on a focused row); `swift build --package-path mac`, `swift test --package-path mac` and `bash mac/build.sh 0.0.0` pass; the shipped Share Bar keeps working against the new CLI.
- [ ] TASK-4b13: the global hotkey Control-Option-S. Registered with Carbon `RegisterEventHotKey` (no Accessibility permission); it opens the popover from any app in `list` with the search focused, from `issues` too, closing any open menu; a failed registration shows `Control-Option-S is in use by another app` under General's Shortcut and nothing else changes. AC: swift row `the hotkey event from issues lands in list with search focused` (reducer); negative control: a second registration of the same key reports in use; screen `popover opened by ⌃⌥S while Finder is frontmost, search focused`, verified by a screenshot of that state reached through a real interaction (the key pressed through the harness); `swift build --package-path mac`, `swift test --package-path mac` and `bash mac/build.sh 0.0.0` pass; the shipped Share Bar keeps working against the new CLI.
- [x] TASK-4b14: the Settings window and General. One 620 pt window with icon tabs General, Tenants, Members (shown when any profile is a T2 tenant whose `role` is not `member`; `member ls` itself proves the admin token, and its refusal shows as a sentence in the tab), Advanced; arrows move tabs; the gear opens General, "Manage tenants…" opens Tenants with the current tenant selected. General: Open at login (`SMAppService`), Menu shows (Mine or Team), Recent links (5, 8, 12), After sharing (copy, notify), Notify me when (a machine serving my links goes offline, a link is about to expire, a member needs a look for admins), the shortcut; New links expire and Store new links write the CLI config through `share config ttl <v>` and `share config storage_default <v>` (SPEC-010 G14, DEC-57), Store new links shown only on tenants with cloud storage. AC: swift rows `Members tab hidden for a non-admin`, `General's expiry writes argv share config ttl 7d`; with the fake CLI, changing the expiry leaves that argv in `argv.log`; screens `General tab`, `Settings for a member without the Members tab`, each verified by a screenshot of that state reached through an in-app test hook or the fake CLI (DEC-81); `swift build --package-path mac`, `swift test --package-path mac` and `bash mac/build.sh 0.0.0` pass; the shipped Share Bar keeps working against the new CLI.
- [x] TASK-4b15: Advanced, the admin key and the minter key (gap G3, DEC-46, DEC-80). CLI path (default from `CLI.locate`, shown with `share version`); Admin key source: From 1Password (an item picker; shows the item's name and vault, never its path or value; writes `share admin-token --cmd 'op read op://<vault id>/<item id>/credential'` with the 26-character ids, each checked against `[a-z0-9]{26}`, never the names, so a vault or item name cannot inject shell), From a command (a text field; `share admin-token --cmd '<command>'`), Ask me each time (`share admin-token --clear`); Test runs `share admin-token --test --json` and shows what the token can do (tunnels, DNS, Workers, R2, Connectivity Directory), never the token; Minter key source: the same three choices, writing `share minter-token --cmd 'op read op://<vault id>/<item id>/credential'` (the same id check), `share minter-token --cmd '<command>'` or `share minter-token --clear`, with Ask me each time passing the token to that one member command as `SHARE_MINTER_TOKEN` and never storing it, and Test running `share minter-token --test --json`; Show serve log in Finder; Use the classic menu (one release only), the `LegacyMenu` key; Copy share state as JSON. AC: swift rows `each source writes its argv`, `each minter source writes its argv`, `Test shows capabilities and never a token-shaped string`; with the fake CLI, each source change of either key leaves its argv in `argv.log`; screens `Advanced with a 1Password item picked`, `minter key from 1Password`, `with a command`, `with Ask me each time`, `Test passed`, `Test failed with the CLI sentence`, each verified by a screenshot of that state reached through an in-app test hook or the fake CLI (DEC-81); `swift build --package-path mac`, `swift test --package-path mac` and `bash mac/build.sh 0.0.0` pass; the shipped Share Bar keeps working against the new CLI.
- [x] TASK-4b16: dialogs (interactions doc 3b). One `ImpactSheet` (title, optional body, lines with a cross for what stops and a check for what keeps working, Cancel and one action button, destructive in red ink) whose counts come from `share state` rows, never from fixed copy: Stop serving counts this Mac's links against cloud and member links; Pause counts the member's machine links; Remove member offers keep or delete for cloud links; Roll back names its command. Also the code sheet (the code once, Copy code, Done, "Share Bar shows the code only now."), the invite sheet (name, where links live with one-line consequences, code expiry 1, 7 or 30 days), the refusal sheet (the CLI sentence and its next action as a button), and the ask-for-admin-key sheet: a secure field whose value is passed to that one command as `CLOUDFLARE_API_TOKEN` in its environment and dropped when the command exits. Esc closes every sheet but progress. AC: swift rows `stop serving counts from rows`, `pause counts the member's machine links`, `the asked key reaches the child environment only` (argv and the app's defaults hold no token), `Esc never closes progress`; screens `Stop serving confirm with counts`, `Pause confirm`, `Remove member with the cloud-links choice`, `invite sheet`, `code sheet`, `ask for the admin key`, each verified by a screenshot of that state reached through an in-app test hook or the fake CLI (DEC-81); `swift build --package-path mac`, `swift test --package-path mac` and `bash mac/build.sh 0.0.0` pass; the shipped Share Bar keeps working against the new CLI.
- [x] TASK-4b17: Tenants, list and detail. The source list (host, `<role> · <status word>`, a needs-a-look dot, + and - below) and the detail of `### Components & states`; Start serving (`share start`) and Stop serving (`share stop` after the impact sheet) shown per the interactions doc section 5 table; - opens the remove sheet per role: owner `share teardown --yes`, member `share leave`, removed member `share leave --local`, and an admin of a T2 tenant gets the refusal sheet "Remove every member first" with Open Members, which is also what the CLI's `members_present` code maps to if teardown runs anyway (gap G6, DEC-49); a member whose `member.status` is `removed` (read from its own record, never inferred from a 401) sees "You were removed from <host>" with Clean up (gap G4, DEC-47); a `token.status` of `expired` shows `Your key expired; ask the admin to renew it` and `invalid` shows `Your key stopped working; ask the admin`, each with Copy request, never Clean up; Leave this tenant stays an explicit action behind the impact sheet (DEC-79). AC: swift rows `buttons per role, tier and phase` (table-driven from section 5), `members_present maps to the refusal sheet`, `removed member shows Clean up`, `expired or invalid key never shows Clean up`; with the fake CLI, Clean up leaves `leave --local` in `argv.log`; screens `admin tenant serving`, `owner tenant stopped with its reason`, `starting`, `refused removal of a T2 tenant`, `owner removal sheet`, `member: You were removed`, each verified by a screenshot of that state reached through an in-app test hook or the fake CLI (DEC-81); `swift build --package-path mac`, `swift test --package-path mac` and `bash mac/build.sh 0.0.0` pass; the shipped Share Bar keeps working against the new CLI.
- [x] TASK-4b18: Tenants, journaled flows (gaps G2, G5, G7, DEC-45, DEC-48, DEC-50). Add (+ in Tenants, and the first-run panel) opens the add sheet: Join a team runs `share join <host> <code>`, Set up a hostname runs `share setup <host>` (with Also turn on cloud storage, `share setup <host> --r2 --bucket share-<host>` after it); Turn on cloud storage (owner or admin, T0) and Turn on members (admin, T1) run the `setup-r2` and `setup-members` verbs; every one runs with `SHARE_PROGRESS=1` and shows the progress sheet from the journal's `step`, `of` and `name`; Stop sends SIGTERM, the journal keeps the step, and the tenant shows the interrupted callout; Resume runs the journal's `rerun` (bare `share join` for a join), Roll back its `rollback`. Step names shown are the journal's, through a copy table for known names that falls back to the raw name. AC: swift rows `progress sheet follows progress lines`, `Stop sends SIGTERM and leaves the callout`, `Resume runs rerun`, `Roll back runs rollback`, `the tier buttons are admin only`; with the fake CLI, a join stopped at step 4 then resumed leaves `join <host> <code>` then `join` in `argv.log`; screens `add sheet, join`, `add sheet, set up`, `progress at step 4 of 6`, `interrupted callout`, `cloud storage progress`, `members progress`, each verified by a screenshot of that state reached through an in-app test hook or the fake CLI (DEC-81); `swift build --package-path mac`, `swift test --package-path mac` and `bash mac/build.sh 0.0.0` pass; the shipped Share Bar keeps working against the new CLI.
- [ ] TASK-4b19: Members (gap G10, DEC-53). Reads `share member ls --json` when the tab opens and after each member action, never on the 60 s poll (DEC-54); filters All, Needs a look and Removed with counts, and a search; the row of `### Components & states`; the row menu lists exactly the verbs in the member's `can[]` (Finish, Resume, Pause…, Send a new code, Rotate keys…, Renew key…, then Remove… or Delete record), mapped to `share member resume|pause|invite|rotate|renew|rm|purge <name>` through the existing `MutationQueue`, with the sheets of TASK-4b16 for pause, rotate, renew, remove and the code; Invite… opens the invite sheet and runs `share member add <name> --machine|--cloud --invite-ttl <n>d`; a running verb shows its step from the record, a stale lease Finish. A `member ls` failure shows its sentence in place of the list. AC: swift rows `row menu equals can[]` (every stored status), `each verb maps to its argv`, `filters count`, `member ls failure shows the sentence`; with the fake CLI, Pause then Resume leaves both argvs in `argv.log`; screens `Members all, 12 people`, `Needs a look filter`, `Removed filter`, `row menu of an active member`, `row menu of a stale pausing member`, `invite sheet then its code`, each verified by a screenshot of that state reached through a real interaction; `swift build --package-path mac`, `swift test --package-path mac` and `bash mac/build.sh 0.0.0` pass; the shipped Share Bar keeps working against the new CLI.
- [ ] TASK-4b20: the All links window (interactions doc 3a). Every link of the current tenant, expired included: tabs All, Live, Needs a look, Expired with counts; search over name, owner and machine, focused on open; columns Name (created time and state word), Owner, Lives on, Expires, Views (cloud rows only, blank otherwise), Copy; select with checkboxes and select all; the bar `<n> selected` with Copy links (one URL per line) and Remove (one `pending` entry, DEC-70, `share rm <id>...`, another member's link revoked); expired rows dimmed with Copy disabled. AC: swift rows `tab counts`, `views only on cloud rows`, `bulk copy joins URLs one per line`, `bulk remove argv revokes others' links`; with the fake CLI, a bulk Remove leaves one `rm` argv with every id; screens `All tab`, `Needs a look tab`, `Expired tab`, `three selected with the bar`, `search with no match`, each verified by a screenshot of that state reached through a real interaction; `swift build --package-path mac`, `swift test --package-path mac` and `bash mac/build.sh 0.0.0` pass; the shipped Share Bar keeps working against the new CLI.
- [ ] TASK-4b21: app states and first run (gap G8, DEC-51; interactions doc section 1). Loading (no `profiles` result yet), CLI missing (spawn fails: "Install the share command" with Copy install command), CLI too old (`compat.status` `cli_below_min` or an old help banner: "Update share to 0.10" with Copy upgrade command), No tenant (the first-run panel with Join a team with a code… and Set up my own hostname…, each opening the add sheet of TASK-4b18), Ready. AC: swift rows one per app state from its fixture; screens `loading`, `CLI missing`, `CLI too old`, `first run`, `join sheet opened from first run`, each verified by a screenshot of that state reached through a real interaction (the fake CLI's `firstrun` and `cli-old` scenarios, a missing `SHARE_BIN` path); `swift build --package-path mac`, `swift test --package-path mac` and `bash mac/build.sh 0.0.0` pass; the shipped Share Bar keeps working against the new CLI.
- [ ] TASK-4b22: keyboard path and VoiceOver (`### Accessibility targets`). Every key of that section in the popover, the row menu, Quick Look, Settings, the sheets and the All links window; focus restored by row id after every refresh; row labels are the name plus the meta line and expose actions; the status item label carries the count; the toast is a live region; Reduce Motion fades the drop overlay. AC: swift rows for the label builder (one per `link_state`), `focus restores by id after a refresh that reorders rows`, `status item label carries the count`; screens `focus ring on the third row after Arrow Down twice`, `row menu opened by Shift-F10`, each verified by a screenshot of that state reached through a real interaction; a VoiceOver and keyboard checklist run by hand and recorded in `docs/verification/multi-member.md`; `swift build --package-path mac`, `swift test --package-path mac` and `bash mac/build.sh 0.0.0` pass; the shipped Share Bar keeps working against the new CLI.
- [ ] TASK-4b23: errors and running ops. Mutations run with `SHARE_ERROR_JSON=1`; `MutationOutcome` reads the trailing JSON line (`{"error":{code, message, next}}`) and shows the sentence with `next` as a copyable line, else today's last `share: ` line (MO:L87-92); a progress line from another process's alive op shows `Working: <verb> (<step>/<of>)` in the footer; the Stop Waiting copy reads `The add stops where it is; share prune cleans up what it left.` (SPEC-010 G9). AC: `MutationOutcome` swift rows with and without the JSON line, and one per SPEC-009 code the app maps to a sheet (`members_present`, `member_busy`, `cli_below_min`, the join table); screens `publish failure with its next step`, `Working line for an add from the terminal`, each verified by a screenshot of that state reached through a real interaction; `swift build --package-path mac`, `swift test --package-path mac` and `bash mac/build.sh 0.0.0` pass; the shipped Share Bar keeps working against the new CLI.
- [ ] TASK-4c: docs. README, `docs/how-it-works.md`, `docs/setup.md` (member onboarding: one pasted line), `docs/SYSTEM-DESIGN.md` rev C as built (the delta table in `## Design`), ADR-0009 accepted, glossary `CONTEXT.md`, `docs/QUALITY.md` with the Q- entries. AC: the existing docs grep (`tests/share.sh` "tenant docs" section) extended to every member verb, flag and config key named here.
- [ ] TASK-4d: `tests/e2e-members.sh`, the live legs in `## Verification`, refusing any hostname, bucket, tunnel, service or token name without the `share-e2e-` prefix, with an EXIT trap that deletes by name and prints each leftover. AC: ML-1 to ML-12 green twice in a row.
- [ ] TASK-4e: STOP for Han, then the live acceptance on `s.console.so` with the owner's second machine as the first member (DEC-3), and `docs/verification/multi-member.md` with each negative control's red and green run. AC: every `## After state` item checked.

Task count: Phase 0: 6; Phase 1: 12 (TASK-1c is split into 1c1 and 1c2, DEC-77; TASK-1f into 1f1 to 1f3, DEC-69); Phase 2: 5; Phase 3: 6; Phase 4: 27 (TASK-4a, TASK-4b1 to TASK-4b23, TASK-4c, TASK-4d, TASK-4e); 56 in all.

## After state

- [ ] `share member add an --machine` on a T2 tenant prints one `share join s.console.so <code>` line; nobody opens the Cloudflare dashboard. (Today: the admin hand-makes a token in the dashboard.)
- [ ] On the member machine, `share join s.console.so <code>` ends with `joined as m-an-<8hex>`, and `share add f.pdf` prints `https://s.console.so/<id>/f.pdf`, which answers 200 while the file never leaves that machine. (Today: a member can publish cloud links only.)
- [ ] A second `share join` with the same code answers "this invite was already used or never existed". (Today: no invites.)
- [ ] `share member pause an` makes An's machine links answer 503 within the verb; `resume` restores 200.
- [ ] `share member rm an` leaves no tunnel, VPC Service, `M_<8hex>` binding, token, `i/` object or v:3 pointer of An, checked by `tests/e2e-members.sh` listings by name. (Today: no member objects exist.)
- [ ] An origin with R2 off or on and no members serves exactly as before, except that `curl http://127.0.0.1:<port>/<unlisted id>/x` answers 404. (Today: 200, the whole `pub/` tree is served, L1127.)
- [ ] A v0.9 `share` on a T2 tenant lists, adds and removes cloud links, and never deletes or mis-serves a member link.
- [ ] After `member rotate an` on a paused member and a re-join with the new code, `share member ls` shows an `paused`. (Today, in the earlier draft: rotate ended at `paused` and join step 3 refused anything but `invited`, so the re-join died.)
- [ ] A died admin verb or join is named by `share member ls` or `share status` with its step and the exact rerun line. (Today: the step lives only in the dying terminal.)
- [ ] The Share Bar opens a popover of recent links with search, Mine and Team, and one footer status line; Settings holds General, Tenants, Members (admins) and Advanced; All links, Quick Look, drag out and Control-Option-S work; every state an AC names has a screenshot in `docs/verification/share-bar/` reached through a real interaction; `swift test --package-path mac` passes. (Today: an `NSMenu` built from `MenuModel`.)
- [ ] From the Share Bar alone, with the admin key from 1Password, an admin turns on members, invites a member, pauses and resumes them, and stops and resumes a `setup --r2`; the commands in the fake CLI's `argv.log` match the interactions doc rows. (Today: every one of these is command line only.)
- [ ] The shipped v0.9.0 Share Bar still renders every profile the new CLI reports: `bash mac/compat-check.sh v0.9.0` exits 0.
- [ ] `node tests/worker.mjs` and `bash tests/share.sh` pass on Linux and macOS CI with every `mm` and `v5` row.

## Quality requirements

No `docs/QUALITY.md` exists in the worktree; TASK-4c creates it with these entries (full text in `QUALITY-additions.md`). All are new.

- Q-SEC-1 (new): forged bucket writes never delete bytes on another machine. Tested by: RC-08, RC-10, FG-01, FG-02; negative control NC-1.
- Q-SEC-2 (new): forged bucket writes never serve an unlisted or revoked row, never change routing, and never redirect an admin verb to another object. Tested by: SV-01, SV-27, FG-03 to FG-07, FG-15; NC-2, NC-9.
- Q-SEC-3 (new): an invite yields its sealed bytes at most once. Tested by: SV-14 to SV-18, CC-11; NC-5.
- Q-SEC-4 (new): Access credentials never reach a member machine. Tested by: SV-21; ML-7; NC-4.
- Q-SEC-5 (new): `member rm` leaves zero objects of the member, or names the one token it could not reach, with its expiry. Tested by: MB-13, MB-34, ML-11; NC-10.
- Q-SEC-6 (new): no token, key or code in argv, files or output. Tested by: TASK-1f2 and TASK-1f3 argv and log grep; existing "live transport, retries, secrets" section extended.
- Q-REL-1 (new): every multi-step admin verb converges after a die at any step with zero orphans. Tested by: every DP- row.
- Q-REL-2 (new): concurrent admin verbs lose no binding and no pause. Tested by: CC-01, CC-02; NC-7.
- Q-REL-3 (new): every deploy path keeps every member binding, `MEMBERS` and `PAUSED`. Tested by: DY-01 to DY-04; NC-6.
- Q-AVAIL-1 (new): a member link adds at most 400 ms p50 and 800 ms p95 over 20 GETs. Tested by: ML-6.
- Q-AVAIL-2 (new): a routing change is live when the verb exits. Tested by: DY-05, ML-8.
- Q-AVAIL-3 (new): a member machine down leaves origin and cloud links unaffected. Tested by: OT-01, ML-9.
- Q-COMPAT-1 (new): a tenant with no members behaves as before except unlisted bytes. Tested by: SV-01 to SV-05, SPEC-008 compat row 1.
- Q-COMPAT-2 (new): an older CLI or Worker fails closed on member records. Tested by: OC-01 to OC-06.
- Q-COMPAT-3 (new): the shipped Share Bar renders every profile the new CLI reports; `state` stays schema 1 with no new `state.state` value. Tested by: TASK-4b1 `mac/compat-check.sh`, OC-06, OC-08.
- Q-REL-4 (new): a member record only moves along a row of the transition table. Tested by: TASK-1e `member_can` iteration, MB-24, MB-25.
- Q-COST-1 (new): one bucket read per visitor request for a v:3 link and no new read for v:1 or v:2. Tested by: SV-24.
- Q-SCALE-1 (new): 20 machine members per tenant deploy and route. Tested by: TASK-1a(e), DY-04.
- Q-OPS-1 (new): a revoked link 404s at once and loses its Caddy handle within one hourly loop. Tested by: LK-11, ML-10.

## Acceptance Criteria

- [ ] All 56 tasks pass their individual acceptance criteria.
- [ ] Every row of `### SPEC-010 tasks each task needs` held when its task merged; SPEC-010's Phase 1 (G1, G1b, G2a to G2c, G3, G4, G5, G13) shipped before the first Phase 1 task merged.
- [ ] The shipped Share Bar keeps working against the new CLI (`bash mac/compat-check.sh v0.9.0`).
- [ ] Every status write goes through `member_can`; the triple iteration test is green.
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
bash mac/compat-check.sh v0.9.0   # the shipped Share Bar decodes the new CLI's output (TASK-4b1)
```

By hand on a Mac with Accessibility granted to the terminal: `bash mac/shots.sh all` (TASK-4b4) reaches every screenshot state a TASK-4b AC names through real clicks, keys and drags, in light and dark.

CI runs `bash tests/share.sh` on `ubuntu-latest` and `macos-latest` (`.github/workflows/ci.yml`); macOS `/bin/bash` 3.2 must parse `bin/share` (CLAUDE.md).

By hand, with Console Labs credentials from 1Password (never in argv): `tests/e2e-members.sh`, then TASK-4e on `s.console.so`. Live legs:

| # | Step | Assert |
|---|---|---|
| ML-1 | throwaway T1 tenant `share-e2e-*` on origin A; `setup --r2 --members` | marker `members:true`, `min_cli`; Worker v5 pair; `PAUSED` `[]` |
| ML-2 | `member add m1 --machine` | one invite line; tunnel, service, binding, token exist by name |
| ML-3 | member HOME B (second machine, or a second HOME on A with its own cloudflared): `join` | ACTIVE; probe 3x200 |
| ML-4 | B `add` a PDF, an HTML file, a folder | 200 each through the Worker; the HTML file and the folder's `/<id>/` answer `text/html` with the CSP sandbox; the PDF does not and renders |
| ML-5 | B `refresh`, `rm`; A `ls` | shared list shows B's rows with `origin=m1`; rm 404 at once |
| ML-6 | 20 GETs of a B link and of an A link | p50 and p95 of the difference within Q-AVAIL-1 |
| ML-7 | gated link on A (admin), then GET a B link with the Access cookie and a forged `cf-access-jwt-assertion` header | B's Caddy access log holds neither |
| ML-8 | `pause m1`, `resume m1` | 503 at verb exit, 200 at verb exit |
| ML-9 | stop B's cloudflared | B links 503 offline page; A and cloud links 200; `member ls` connectors 0 |
| ML-10 | A admin `rm` of a B link | 404 at once; B's handle dropped at its next loop (forced with `share prune --loop`) |
| ML-11 | `member rm m1`, then B `status`, `leave --local` | listings by name empty; B reports its key stopped working (`invalid`), never removal inferred from the 401; B's service gone |
| ML-12 | `--no-members`, admin purge, teardown | no `share-e2e-*` object of any kind remains |

## Edge Cases

A full scenario pass. Test file: `tests/share.sh` unless marked `worker.mjs` or live (`e2e-members`).

### Tenant (brief tenant table)

| # | Scenario | Expected |
|---|---|---|
| TN-01 | T1 `setup --r2 --bucket B --members --yes` | log order: settings GET (admin proof and refusals only) < scope probes < services list probe < lease PUT < settings GET (the deploy body) < deploy (v5, `PAUSED` `[]`) < healthz nonce 3x < marker PUT If-Match < config `members=on` < lease DELETE |
| TN-02 | each guard fails: a missing scope (each named), services list 403, a local row without its pointer, marker names another host, no TTY and no `--yes` for the min_cli confirmation | dies before any PUT, POST or DELETE |
| TN-03 | rerun on T2 | no marker PUT, deploy skipped when equal, exit 0 |
| TN-04 | `--no-members` with a record not REMOVED | refused naming the member |
| TN-05 | `--no-members` with every record REMOVED or purged | marker keys dropped (If-Match); deploy without `PAUSED` and with no binding; config key dropped |
| TN-06 | `--no-r2` on T2 | refused "--no-members first" |
| TN-07 | `teardown` on a T2 origin with records; `migrate` | refused before any change; teardown's code is `members_present` (gap G6) |
| TN-08 | `setup --r2` rerun and `--alias` on T2 | bindings and `PAUSED` carried (DY-01) |
| TN-09 | die after the deploy, after the marker, before config | rerun converges; a dead same-host lease is taken over at once; die between marker and config: refusals still hold (teardown, migrate and `--no-r2` refuse, reading the marker) |
| TN-10 | a T2 origin config with `members=on` (and a member config with `role=member`, `member_id`, `member_mode`): `setup <host>` rerun, `api-token --cmd` | every one of those lines survives byte for byte (TASK-0f) |
| TN-11 | marker `members:true`, config without `members=on` (an older CLI's rerun dropped it) | `state.tier` `t2`, `state.tier_drift` true; `status` prints the `config_drift` repair line; teardown still refused |
| TN-12 | marker forged to `members:false` while the deployed settings hold a `vpc_service` binding | teardown, migrate and `--no-r2` still refused |

### Member (brief member table)

| # | Scenario | Expected |
|---|---|---|
| MB-01 | `member add an --machine` | DP-add steps in order; record `invited` with `tunnel_id`, `vpc_service_id`, `token.id`, `invite.hash`; one invite line |
| MB-02 | `member add bo --cloud` | no tunnel, service or deploy calls; record `invited` mode cloud |
| MB-03 | name `A_n`, a 25-char name, a name held by an active record | refused before any write; an `adding` or `invited` record of the same name resumes with its member_id |
| MB-04 | no minter source (`SHARE_MINTER_TOKEN` unset, no `minter_token_cmd`); minter lacking API Tokens Write; admin lacking Connectivity Directory Admin | refused before the lease; the first with `minter_token_missing` |
| MB-05 | 21st machine member | refused naming the cap |
| MB-06 | `join s.console.so <code>` | DP-join steps; record `active` with `joined`; config `role=member` |
| MB-07 | join refusals: CLI below `min_cli`; redeem 404; redeem 410; redeem 503; record not `invited` or member_id differs; port busy; profile not R0 and not R7 of the same host; `mac` mismatch | each dies with its code (`cli_below_min`, `invite_unknown_or_used`, `invite_expired`, `invite_unavailable`, `member_changed`, `port_busy`, `profile_not_empty`, `invite_tampered`), asserted from the `SHARE_ERROR_JSON=1` line; nothing local remains except after a 200 redeem with a later refusal, which removes its own config and tokens |
| MB-08 | INVITED past `invite.expires` | `member ls` shows EXPIRED; `member sync` deletes the `i/` object |
| MB-09 | `member invite an` from INVITED and from EXPIRED, with `--port 8801` | old token deleted, connections deleted, new token, service port updated, old `i/` deleted, new `i/`, new code |
| MB-10 | `member pause an` | record `paused`; `PAUSED` holds an's suffix; v:3 503; an's cloud links 200; an's CLI refuses `add` |
| MB-11 | `member resume an` | record `active`; `PAUSED` without an's suffix; v:3 200 |
| MB-12 | `member rotate an` from ACTIVE and from PAUSED | new tunnel and service `-r1`; binding `M_<8hex>` names the new service; old ones deleted; record `invited` with `prev_status` `active` or `paused`; after the re-join the record is back to that status, so a PAUSED member stays paused |
| MB-13 | `member rm` from INVITED, EXPIRED, ACTIVE, PAUSED, LEFT, and from each `...ing` | REMOVED; v:3 pointers tombstoned; cloud links kept (or deleted with `--cloud-links delete`); no object left |
| MB-14 | `leave` on ACTIVE | own links rm'd (pointer, then bytes); service uninstalled; record `left` (If-Match); tokens forgotten; config dropped |
| MB-15 | `leave --local` | `r2-calls.log` has no line; service gone; tokens forgotten; rows and `pub/` moved to trash |
| MB-16 | `member purge` on REMOVED; on ACTIVE | record deleted and id in `u/purged.json`; refused |
| MB-17 | `adopt bo --token-id <id>`: own user's bucket-scoped token; another user's token; an account-wide token | ACTIVE cloud; refused; refused |
| MB-18 | `renew an --token-ttl 90d` | `PUT /user/tokens/<id>` with the same policies; token id unchanged; the member keeps working |
| MB-19 | token expiry 14 days away | `status` on the member and `member ls` warn; on R7 `state.token.status` is `expiring` with `expires_on` (DEC-39) |
| MB-20 | two connectors on a member tunnel | `member ls` flags "extra connector: rotate now" |
| MB-21 | member removed while asleep, then `status`: (a) the rm could not reach the token, so it still answers and the record reads `removed`; (b) the rm deleted the token, so the bucket answers 401 | (a) `state.member.status` `removed`, "this machine was removed from <host>; share leave --local"; (b) `state.token.status` `invalid`, "your key stopped working; ask the admin", `state.member.status` unchanged; no pointer check is made |
| MB-22 | record `active` while `PAUSED` holds the id; record `removed` while bound | `member ls` prints two drift lines, writes nothing |
| MB-23 | `member sync` on MB-22's state | record becomes `paused`; the removed-but-bound case is reported, not changed |
| MB-24 | record in `pausing` (step 2); admin runs `member rotate an`, then `member rm an`, then `member sync` | rotate refused `member_busy` naming `pause` and step 2 with `share member pause an`; rm proceeds; sync reports and writes no refusal |
| MB-25 | `member pause an` dies after `pausing`; the record is then rerun by `member pause an` twice | `prev_status` stays `active` across both reruns (never rewritten); cleared when `paused` lands |
| MB-26 | PAUSED member: `rotate`, then `member invite an` (a lost code), then `renew an`, then join with the newest code | record `invited` with `prev_status` `paused` after each admin verb (DEC-41); join ends `paused`; `prev_status` and `invite` dropped |
| MB-27 | join on an R7 profile: bundle `member_id` equals config; bundle names another member_id | tokens replaced in place, record restored; refused `member_changed` before any local write |
| MB-28 | admin verb killed at step 3 on another host | `member ls` prints the record's `step 3 of <m> (<step_name>)`, the lease holder, `(live)` while the holder runs, then `(stale since <time>; rerun: share member <verb> <name>)` |
| MB-30 | member `active`, local `token_expires` past, publisher token 401 | `state.token.status` `expired` (by local `token_expires`, DEC-79), `state.member.status` stays `active`; copy names `share member renew <name>`; no Clean up; after the admin's `renew` the member publishes again with no re-join |
| MB-31 | member `active`, token 401 before its local expiry (minting user left, or a finished `rm` deleted it) | `state.token.status` `invalid`; copy `your key stopped working; ask the admin`; `state.member.status` never `removed`; no Clean up offered |
| MB-32 | `join` with no `security` command on PATH (the suite's stub removed) | dies `member_needs_keychain` before the redeem; nothing written |
| MB-33 | rotate a paused member, then `member sync`, then join with the new code | sync reports and leaves the record `invited` with `prev_status` `paused`; join ends `paused` |
| MB-34 | `member rm an` run with the minter of a different user than the one that minted An's token | rm ends REMOVED and prints `token not reachable by this minter; it expires <expires_on>`; `member ls` shows `token_unreachable` with that date until it passes |
| MB-36 | a machine member's code redeemed by someone else while the record is `invited`, and again after the other redeemer reached `joining`; admin runs `member rotate an` | rotate proceeds from both; the old tunnel is gone, so the other redeemer's connector stops; the new code joins; a cloud member's 404 copy names `invite` |
| MB-37 | `member renew an` with the minter of a different user than the one that minted An's token; the same for a cloud member | dies `token_unreachable` naming the token's `expires_on` and `share member rotate an`, or `invite` for the cloud member; record unchanged |
| MB-35 | `member ls` with one paused member and one whose connectors are 0, then `state` on the admin HOME | the `members` key of `.health` written; their v:3 rows read `link_state` `paused` and `offline`; with the cache removed both read `live`; `state` makes no network call |
| MB-29 | `member ls --json` with one record in each stored status, and a `pausing` record whose lease is stale | each `can[]` equals the verbs `share state-fn member-can <status> <verb> admin` allows; the stale `pausing` record also lists `finish`; a `removed` record lists only `purge` (gap G10) |

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

RC-01 to RC-13 are rows 1 to 13 of the reconcile table, one test each, run on a member HOME with fixtures aged by the suite's `aged` helper. RC-14: on the origin, a v:3 pointer of any age, with or without a local row of the same id, is never deleted (the origin's reap list stays v:2). RC-15: on a member HOME, an origin v:2 pointer aged 660 s with no local row is never deleted (`mdel` 0, no PUT), on `ls`, `prune` and `prune --loop` (DEC-65).

### Who may

| # | Scenario | Expected |
|---|---|---|
| WM-01 | paused, left or removed member `add` | refused before any write |
| WM-02 | member `member add` (no admin token) | refused "needs the tenant admin token" |
| WM-03 | origin without the admin token runs a member verb | settings GET 403: refused |
| WM-04 | origin without the admin token `rm` of a v:3 | refused, naming the admin |

### Die points (kill or fail injection after each step, then rerun)

Kill: `SHARE_R2_DRY_PAUSE="<METHOD> <key>"` holds the call, the test sends `kill -9`, then reruns. Fail: `SHARE_R2_DRY_FAIL` on the next call. Before each rerun the test asserts that `member ls` (admin verbs) or `share status` (join, leave) names the died step and prints the exact rerun line (DEC-31); after each rerun it asserts the end state of the happy row, an empty orphan listing, and an empty `$root/ops/`.

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
| CC-04 | join while `member rm` runs | rm wins from any state; the member's probe fails; `status` reports `removed` only if it read its record as `removed`, else `token.status` `invalid`, never removal from the 401 alone |
| CC-05 | two machines add the same id | If-None-Match: one gets 412 and a new id |
| CC-06 | admin revoke racing the owner's reconcile, with the revoke's `t/` PUT and `m/` DELETE landing before, between and after reconcile's `m/` list and `t/` read | reconcile row 9 skips the young tombstone; row 11's tombstone check deletes its own rewrite; no resurrection in any order |
| CC-07 | owner `rm` racing admin revoke | the leftover tombstone is deleted by row 5 |
| CC-08 | the member loop racing the member's own add | add lock and the 10-minute rule keep the pointer |
| CC-09 | lease holder killed on another host | takeover after `LastModified` + 900 s; before it, `member ls` names the holder's verb, member and step from the lease body (DEC-36) |
| CC-10 | two takers of one stale lease | If-Match: one wins |
| CC-11 | two redeems of one code at once (`worker.mjs`, interleaved `get`) | exactly one 200 |
| CC-12 | admin verbs for two different members, sequential | independent; both bindings |
| CC-14 | on T2, a `setup --r2` rerun held at its deploy while `member pause an` runs; and the reverse, `member pause an` held at its deploy while a `setup --r2` rerun starts | in each order the second waits for the lease and reads settings after taking it; the end deploy holds an's suffix in `PAUSED` |
| CC-15 | a lease holder paused past 900 s; a second verb takes the lease over; the first resumes | the first dies `lease_lost` before its next Cloudflare call; the second's lease and both members' bindings stay |
| CC-13 | admin token sources: `CLOUDFLARE_API_TOKEN` and `admin_token_cmd` both present; only the command; the command exits 1; neither | the variable wins and the command never runs; the command runs once per process; dies `admin_token_cmd_failed` naming the exit status, never its output; dies `admin_token_missing`; each before any bucket or API write (gap G3) |

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
| OC-06 | an older Share Bar reads the new state JSON | extra keys ignored; a swift row decodes the current `Fixtures/state.json` plus every new key (`role`, `tier`, `serve`, `ops`, `token`, `compat`, `member`, row `link_state`/`reason`/`origin`) with today's `Snapshot`, and `mac/compat-check.sh v0.9.0` does the same with the shipped sources |
| OC-08 | why no `state.state` value is added | a swift row feeds today's `Snapshot` an unknown `state.state` (`"paused"`) and asserts `Health.error` ("Error: state not readable", MM:L38): the reason every new phase rides `serve.phase` or `member.status`, never `state.state` |
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
| FG-15 | forged `u/` `tunnel_id`, `vpc_service_id`, `token.id` and `token.name` naming the tenant tunnel, another member's service and the minter's own token; then `member rm`, `invite --port`, `rotate`, `renew` | none of the named objects is touched; each verb acts only on the tunnel and service found by this member's names and the token named `share <host> <member_id>` in the current minter's list; a forged `token_unreachable_until` changes only the `member ls` display |
| FG-16 | forged `t/` with `by` holding a tab, a newline or a space | the row reads `revoked revoked_by=unknown`; `index.tsv` gains no extra row or opts token |
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
| SV-07 | `ls` and `state` with v:3 rows | `origin` shown; `link_state` `live` |
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
| SV-21 | v:3 with `cf-access-jwt-assertion`, `cf-access-authenticated-user-email`, `cf-access-client-secret`, `Authorization`, cookie `a=1; CF_Authorization=x`, and `Range` | binding sees `Range` and none of the others, no cookie at all |
| SV-22 | binding answer without `X-Share-Served`; binding throws | 503 offline page each |
| SV-23 | binding answers `text/html`; `application/pdf`; the path `x.xhtml`, `x.xml`, a path with no extension; `Set-Cookie`; a 302 to `https://evil.example/` | CSP sandbox on every answer but the PDF; `Content-Type` from the path, `nosniff`; `Set-Cookie` dropped; the 302 answers 502; `X-Share-Served` removed; a cloud `.html` on a `MEMBERS=1` tenant also carries the sandbox |
| SV-24 | count `BUCKET.get` per request for v:1, v:2, v:3 | 2, 1, 1 (unchanged for v:1 and v:2) |
| SV-25 | `state` on a member HOME with a revoked row and, with the member paused, a live v:3 row | `link_state` `revoked` with `reason` `revoked_by=<by>`; `paused`; every old row field equal to the pre-change output |
| SV-28 (worker.mjs) | a folder link: `/<id>` answered by a 308 to `/<id>/`, then `/<id>/` answered `text/html` | the redirect passes with its `Location`; the listing is served `text/html` with the CSP sandbox, never `application/octet-stream` |
| SV-27 (worker.mjs) | `PAUSED` `["3f9a1c2d"]`; a v:3 whose `origin` is `m-zz-3f9a1c2d` (another name, the paused suffix) | 503 paused, no binding call |
| SV-26 (worker.mjs) | every request of every existing and new row | `decide()` returns the named row id; every 404 carries the one body `no such link (it may have expired or been removed)`; no response header names the row |

### Deploy

| # | Scenario | Expected |
|---|---|---|
| DY-01 | `setup --r2` rerun after a CLI bump with two bindings, `MEMBERS` `1` and `PAUSED` `["aaaaaaa1"]` deployed | new `script.json` holds both bindings, `MEMBERS` and the same `PAUSED` |
| DY-02 | `--alias` fold on T2 | same as DY-01, `MEMBERS` included |
| DY-03 | `setup --force` lowering the version with a binding present | refused |
| DY-04 | 20 bindings in the dry deploy | one metadata body, every binding present |
| DY-05 | deploy returns 200 but healthz shows the old nonce | the verb waits; after `SHARE_R2_WAIT` it dies naming the rerun |

### Other

| # | Scenario | Expected |
|---|---|---|
| OT-01 | member machine sleeps | v:3 503; origin and cloud links unaffected; `member ls` connectors 0 |
| OT-02 | member Keychain locked under launchd | the loop logs one line and skips; serving continues |
| OT-03 | member removed while offline, comes back | cloudflared fails to connect (tunnel gone); `status` reads 401 and says `your key stopped working; ask the admin`, never removed; Leave this tenant (`leave --local`) cleans |
| OT-04 | invite port busy on the member | refused with "ask the admin: share member invite <name> --port <free port>" |
| OT-05 | member profile beside another tenant's origin profile | named profile; ports checked across profiles |
| OT-06 | the owner's second machine joins its own tenant | works; admin verbs run from it with the env token |
| OT-07 | bucket read of `m/` fails in the Worker | pass to the origin (unchanged); member ids 404 there |
| OT-08 | `member add` while the Worker deploy hits a Cloudflare 5xx | `r2_api_retry` 3 tries, then die; rerun converges |
| OT-09 | two tenants on one account | names carry the host; no collision |
| OT-10 | minting user leaves the account | members read `token.status` `invalid`; `rotate` (machine) or `invite` (cloud) under a new minter finds no old token, prints `token_unreachable` with its expiry, mints a new token and a code; the re-join recovers each; no verb refuses |
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
| Leaked invite code | the member's redeem answers 404 | One-time redeem; the member's copy sends the admin to `rotate`, which replaces the connector token the other redeemer holds (DEC-67) |
| Leaked connector token | connectors above 1 | `rotate` replaces the tunnel |
| Leaked member publisher token | unexpected writes in `ls` | `member rm` or `rotate` deletes it; the trust limit holds until Worker-mediated writes (ADR-0009) |
| Minting user leaves the account | 401 on every member token; members read `token.status` `invalid`, never removed (DEC-79) | `rotate` (machine) or `invite` (cloud) each member under a new minter; a token step that finds no match reports `token_unreachable` with the token's expiry and goes on (DEC-78); account-owned tokens are the upgrade |
| A member token expires | 401 with local `token_expires` past | `token.status` `expired`; the admin runs `member renew`; no re-join, no Clean up (DEC-79) |
| A lease holder outlives its lease (laptop sleep) | renew 412 | dies `lease_lost` before the next Cloudflare call; the new holder continues (DEC-63) |
| A deploy path outside the member verbs races a pause | `member ls` drift `deploy_unpaused_record_paused` | on T2 every deploy path holds `lock/admin` (DEC-62), so the race cannot happen; if the drift shows anyway, `member sync` re-adds the suffix to `PAUSED` (DEC-75) |
| A forged record names another object's id | a GET by id returns a different name | objects are found by name; the id is a hint (DEC-58) |
| A member's HTML reads another link | n/a (browser-side) | CSP sandbox on member HTML; named teammates only (ADR-0009) |
| A v0.9 admin downgrades the Worker with `--force` | v:3 links 404 | `member sync --rebind` from account services |
| Bindings-per-Worker limit lower than 20 | deploy 4xx in TASK-1a(e) | Cap lowered to the measured value |
| Member Keychain locked | loop log line | Reconcile waits for the next unlocked loop; Worker already 404s revoked links |

## Out of Scope

- `member move` (rm and re-add, or rotate on the new machine, covers it), an `edit` verb, `teardown --cascade`, gated links added by members, member `hits` and Worker hit counting for v:3, a public per-member health leg (DEC-5).
- Live port shares by members, unless TASK-3f proves WebSocket through the binding (DEC-8).
- `--host` for members (needs DNS and ingress).
- Members on Linux: `join` needs the macOS Keychain (DEC-66).
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
- DEC-15: The deploy is authoritative and the registry a journal: every deploy carries the deployed bindings, `MEMBERS` (DEC-59) and `PAUSED` forward and applies one delta; the registry is cross-checked only. After a wipe, account VPC Services (admin-only objects) are the rebuild source. Rejected: deploy built from records (a member could unpause itself; review-1 finding 5).
- DEC-16: Pause means machine links answer 503; a paused member's cloud links keep serving and its own CLI refuses new adds (cooperative). Rejected: stamping cloud records (more writes for a rare case).
- DEC-17: In v1 tombstones exist only for v:3 links; an admin revokes an origin link on the origin. Rejected: a `t/` read in the Worker's miss branch (one more read for every legacy miss).
- DEC-18: Down detection for v:3 uses the Caddy header `X-Share-Served`, because a binding answer carries no `cf-cache-status`. Rejected: status codes alone (a foreign listener on the port would be served).
- DEC-19: EXPIRED and ONLINE/OFFLINE are derived, never stored; `member ls` reads connectors from the tunnel API, no probe link.
- DEC-20: The lease is 600 s, renewed before each Cloudflare step, stale at `LastModified` + 900 s; same-host dead holders are taken over at once. Its body names verb, member and step (DEC-36).
- DEC-21: Join writes tokens and config locally before the record write and the record before the service, so a die after redeem resumes with a bare `share join`. Amended by DEC-31: the resume reads the step from the join journal, not from which files exist.
- DEC-22: Redeem sends `h`, not the code; the code never leaves the member's machine.
- DEC-23: `member add` records the invite hash before the `i/` PUT, so a rerun can delete a half-made invite.
- DEC-24: Unregistered R5 publishers keep working on T2; `member adopt` is optional.
- DEC-25: Admin verbs need only the admin token and the hostname; the bucket name comes from the deployed `BUCKET` binding.
- DEC-26: Member links answer GET and HEAD only in v1.
- DEC-27: Machine members are capped at 20 until TASK-1a(e) measures the binding limit.
- DEC-28: The tombstone young-skip (10 minutes) closes the revoke race where the owner deletes a fresh tombstone before the admin deletes the pointer.
- DEC-29 (audit A1): The D8 transition table is the contract of `reg_status`: `member_can <status> <verb> <actor>`, a bash `case` table that is also the doc table, checked before every record write; a different verb's `...ing` refuses with `member_busy` (rm and sync excepted); a test iterates every triple. Rejected: TASK-1e's earlier "continue only if the new status is still valid for the verb", which had no table to check against.
- DEC-30 (audit A2, bug fix): `rotate` ends in `invited` with `prev_status` kept; join's final write restores it. The earlier draft ended rotate at `prev_status` while join step 3 required `invited`, so every re-join after rotate died. Join on an R7 profile of the same member_id is allowed (step 0) and checked after unseal (step 2). Rejected: a second join rule that accepts `active`/`paused` (two rules for one step, and a paused member could re-join as active).
- DEC-31 (audit A3): records carry `step`/`step_name` during an `...ing`; join and every admin verb record SPEC-010's step journal; bare `share join` resumes from the journal step (DEC-21 amended); every DP row asserts that `member ls` or `status` names the died step and the rerun. Rejected: inferring the step from file presence (a wrong guess spends the single-use code).
- DEC-32 (audit A4): every `state` addition stays `schema: 1` and never adds a `state.state` value; `member_status` became `state.member.status`; rows gain `link_state` with `revoked` and `paused`. Old Share Bars show "Update Share Bar" on a schema bump and an error on an unknown `state.state` (SN:L166, MM:L38), so additive keys are the only safe change (OC-06, OC-08).
- DEC-33 (audit A5): T2 is config `members=on` OR marker `members:true`; a disagreement is `config_drift` with a repair line; the refusals read the marker. Rejected: config alone (an older CLI's `setup` rerun drops the key and with it every T2 refusal).
- DEC-34 (audit A6): config writers keep keys they do not own (SPEC-010 G4, `config_put`) before any member key lands; TASK-0f proves it for the four member keys. Rejected: adding the member keys to each whitelist (the next new key repeats the loss).
- DEC-35 (audit A7): every new refusal uses SPEC-010's `die_code`; `member ls --json` `drift[]` entries are codes. Rejected: free-text drift lines (the Share Bar and agents would parse prose).
- DEC-36 (audit A8): the `lock/admin` body names verb, member and step, renewed per step; `member ls` prints the holder live or stale with the rerun. Rejected: holder only (a stuck lease then needs two objects and a guess to explain).
- DEC-37 (audit A9): the invite and join code table is the join refusal contract; MB-07 asserts one code per refusal. Rejected: per-call copy (redeem answers 404, 410 and 503 with no agreed member wording).
- DEC-38 (audit A10): Worker v5 is a pure `decide()` with named rows and one uniform 404 body, inside the one v5 bump. Rejected: a reason header or per-row bodies (an id-existence oracle over 24-bit ids).
- DEC-39 (audit A11): R7 `state.token` carries `expires_on` in SPEC-010's D5 shape, read from the `.health` cache, so MB-19's warning reaches the Share Bar. Rejected: `status` only (the menu would learn of an expired token from a failed add).
- DEC-40 (audit A12): the RowGlyph word for a v:3 row is `on <member>'s machine`. Rejected: today's `on this tenant's machine` (wrong once a link can live on a teammate's machine).
- DEC-41: the `prev_status` rule refines D8's "written on entering an `...ing` from a resting status, cleared on reaching a resting status": written only from `active` or `paused`, kept on entering from `invited`/`joining`/`left`, kept on reaching `invited`, cleared on reaching any other resting status; renew's "status it started from" is `invited` while the record holds an `invite`, else `prev_status`. Why: D8's literal wording let a `member invite` or `renew` after a rotate overwrite `prev_status` with `invited`, so the re-join would land in `invited` and the paused member would come back active or stuck (MB-26). Rejected: a second field such as `rejoin_status` (one more field for the same fact).
- DEC-42: the Share Bar becomes an `NSPopover` holding SwiftUI (prototype call 1); the `NSMenu` path stays one release behind the defaults key `LegacyMenu`, then goes. The package stays `.macOS(.v13)`: `NSPopover`, `NSHostingController` and every SwiftUI view the redesign needs exist there, and the brief's "macOS 14+" was not a requirement any view needs. Rejected: menu only (a menu cannot hold chips, presence or a route line); dropping the menu at once (no fallback if the popover regresses on a user's Mac).
- DEC-43: the admin's members roster reads `share member ls --json` on popover open and after a member action only, never on the 60 s poll, because it calls the tunnel API; X1 names it the one machine surface for members. The brief's "only `profiles --json` and `state --json`" holds for everything else. Rejected: embedding the roster in `state` (it would make `state` call the network, breaking its read-only, no-network rule).

Gap ids G1 to G10 below are the interactions doc's section 8 (`docs/design/share-bar-interactions.md`), written `gap Gn`; they are not SPEC-010's task ids.

- DEC-44 (gap G1): the menu gets its own state machine, `PopoverState` (`firstRun`, `list(scope, query)`, `issues`, `publishing(step, of)`, `dropTarget`, `undo(action, deadline)`, `menu(id)`, `quickLook(id)`), one pure reducer whose effects are values, one swift test per transition (TASK-4b3). Rejected: view-local flags (revision 2's strip, toast and drop zone each kept their own booleans, so an undone Remove and a poll could both fire).
- DEC-45 (gap G2): "Add a tenant" means one of two paths, join with a code (R0 to R7, the `join` journal of TASK-1h) or set up a hostname (R0 to R2, SPEC-010 G2c's `setup-tunnel` journal); both show the journal's steps while they run (TASK-4b18). Rejected: one combined wizard (the two paths share no step).
- DEC-46 (gap G3): admin verbs take the admin token from `CLOUDFLARE_API_TOKEN`, else from the output of the profile config key `admin_token_cmd` (a command such as `op read op://<vault>/<item>/credential`, never the token), the pattern `api_token_cmd` already uses (SPEC-010 G13, ADR-0009). With neither, the Share Bar asks for the token for one command, passes it in that child's environment and drops it. Listings, `state`, `status` and publisher paths never run the command. Rejected: storing the admin token in the Keychain (a stored admin token on every member's Mac); env only (the Share Bar, started by launchd, has no shell environment, so no admin action could run from it).
- DEC-47 (gap G4): a member whose own record is `removed` gets a display state "You were removed from <host>" with Clean up (`share leave --local`); a 401 alone never shows it (DEC-79); `state.member.status` carries it from the `.health` cache, so `state` stays network free (TASK-2e, TASK-4b17). Rejected: showing a generic error (the member could not tell removal from an outage).
- DEC-48 (gap G5): Stop on a running journaled command sends SIGTERM; the journal keeps the step (no EXIT-trap removal, SPEC-010 G2a); the tenant shows Resume (the journal's `rerun`) or Roll back (its `rollback`). Rejected: a modal that cannot be stopped (setup --r2 runs 16 steps and can wait minutes on propagation).
- DEC-49 (gap G6): teardown of a T2 tenant refuses with the code `members_present` and the next command `share member ls`; the Share Bar shows the refusal sheet with Open Members before running anything when `tier` is `t2`, and maps the code to the same sheet if it runs anyway (TASK-1d, TASK-4b17, ADR-0009). Rejected: `teardown --cascade` (cut in DEC-5).
- DEC-50 (gap G7): Turn on cloud storage (owner or admin, T0 to T1) and Turn on members (admin, T1 to T2) are buttons in the tenant detail that run the journaled `setup-r2` (SPEC-010 G2b) and `setup-members` (TASK-1d) verbs. Rejected: command line only (an admin with the app open would still need a terminal).
- DEC-51 (gap G8): with no tenant, the menu is the first-run panel with the two Add paths; Loading, CLI missing and CLI too old are app states before it (TASK-4b21). Rejected: an empty menu with a Settings link.
- DEC-52 (gap G9): row actions beyond copy live in a row menu whose items follow `link_state` and role; items not allowed are hidden, not dimmed; `expired` and `revoked` rows never copy and never drag (TASK-4b9, TASK-4b11). Rejected: inline action buttons per row (clutter a list built for scanning).
- DEC-53 (gap G10): the Members row menu lists exactly `member ls --json`'s `can[]`, which the CLI computes with `member_can`, so Swift never mirrors the D8 table. Revision 8's row menu hides a verb that is not allowed; the interactions doc's older "disabled with help text" applies nowhere in revision 8, and a refusal that still happens (a stale list) shows the CLI's code sentence. Rejected: a Swift copy of the D8 table (two tables drift).
- DEC-54: revision 8 replaces revision 2: the menu is recent links with search, Mine and Team, and one footer line; the route line, the needs-a-look strip, grouping by origin and the members roster in the menu are gone; members live in Settings > Members, which reads `share member ls --json` when the tab opens and after a member action (amends DEC-43, whose "on popover open" moves to the tab); DEC-40's word reads `<member>'s machine` in the meta line; DEC-42 holds. Why: the owner reviewed revisions 3 to 8 and chose a menu that answers one question for a team of ten or more. Rejected: revision 2 (it grew with every member).
- DEC-55: Quick Look previews bytes only when they are on this Mac (`pub/<id>` through `QLPreviewView`); a cloud or member link shows its glyph and meta with no fetch. Rejected: fetching the public URL (a GET per Space press counts as a view on cloud links and answers 503 for an offline member).
- DEC-56: a UI state is evidence only as a screenshot reached through a real interaction (`mac/shots.sh` driving the built app against a fake CLI through the Accessibility API); setting a state in code proves nothing about how a user gets there. Every TASK-4b AC that names a state says so. Rejected: snapshot tests of views fed fixture state alone (revision 2's rounds passed states no click could reach).
- DEC-57: General's "New links expire" and "Store new links" write the CLI config through `share config ttl|storage_default` (SPEC-010 G14), so the command line uses the same defaults (interactions doc section 7). Rejected: the app writing the config file (ADR-0003: the app goes through the CLI); keeping them in UserDefaults (the CLI would not see them).

Spec validation round 1 (2026-11-14) folded these criticals:

- DEC-58: admin verbs find every tunnel, VPC Service and token by deterministic name; an id in `u/` is a hint used only after a GET by that id returns the expected name (invariant 8, FG-15). Why: any publisher token can write `u/`, so a forged id could make `rm` delete the tenant tunnel or the minter's own token, or make `invite --port` repoint another member's service. Rejected: trusting record ids (the record is a journal, not an authority, DEC-15).
- DEC-59: the v:3 path sets `Content-Type` from the path extension, adds `nosniff`, and sandboxes every answer outside an inert type list; it forwards only `Range`, `If-*`, `Accept*` and `User-Agent`, drops `Set-Cookie`, `Clear-Site-Data` and `Refresh` from the answer, and refuses an off-path redirect. On a T2 tenant (new binding `MEMBERS`) the cloud path sandboxes HTML, SVG and XML too. Amends DEC-13. Why: a member's Caddy picks the type, and XHTML, XML or a sniffed answer would run script on the tenant origin; any member can also publish cloud HTML. Rejected: sandboxing `text/html` only (SV-23 passed while the hole stayed).
- DEC-60: `PAUSED` holds 8-hex binding suffixes and row 12 tests the suffix row 13 routes by; member_id generation refuses a suffix already in use. Why: a pointer rewritten to `m-zz-<paused suffix>` passed the full-id check and still reached the paused member's binding, so a bucket write changed routing (invariant 1). Rejected: also checking the name part in the Worker (the name is member-writable; only the suffix is bound by the deploy).
- DEC-61: replaced by DEC-79 (owner decision 2026-11-14). The round 1 fold read a 401 as removal when the member's own pointer also answered 404.
- DEC-62: on T2 every deploy path (a `setup --r2` rerun, `--alias`, `--members`, `--no-members`) holds `lock/admin` from its settings GET through the nonce wait; `member ls` gains the drift codes `deploy_unpaused_record_paused` and `deploy_unbound_record_live`. Why: a setup rerun that read settings before a pause deployed would drop the pause, and sync would then ratify the loss. Rejected: a compare-and-swap on the deploy (the Workers API has none).
- DEC-63: `lease_renew` writes with If-Match on its own last etag and a 412 dies `lease_lost` before the step's Cloudflare call; `lease_release` deletes only its own lease. Why: a holder that sleeps past 900 s loses the lease to a takeover and would otherwise keep writing, or delete the new holder's lease. Rejected: a longer stale time (only moves the window).
- DEC-64: reconcile lists `m/` before it reads `t/`, and row 11 re-reads `t/<id>` after its pointer write, undoing its own write when a tombstone landed. Why: with `t/` read first and `m/` second, an admin revoke between the two reads let row 11 rewrite the pointer and row 8 later delete the tombstone, silently undoing the revoke. Rejected: relying on the 10-minute young-skip alone (it covers only a tombstone already read).
- DEC-65: on R7, `r2_take` puts only own-origin v:3 pointers into `r2_machine`, landed in TASK-1g. Why: today's code puts every v:2 pointer there and its first reconcile loop deletes those over 10 minutes old with no local row, so a member's first `prune` would delete the origin's links; RC-01 to RC-13 used v:3 fixtures only. Rejected: waiting for TASK-2b's reconcile filter (R7 runs `prune` from TASK-1g on).
- DEC-66: `join` refuses with `member_needs_keychain` when `security` is missing; members run on macOS only in v1. Why: `token_store` falls back to a 600 file without `security`, which invariant 7 forbids, and the suite's stub `security` hides it on Linux CI. Rejected: allowing the file fallback for members (a connector token on disk).
- DEC-67: the `invite_unknown_or_used` copy sends the admin to `rotate`, not `invite`. Why: whoever redeemed first holds the connector token, which only rotate replaces (DEC-10). Rejected: `invite` (it re-mints the publisher token only).
- DEC-68: one table, `### SPEC-010 tasks each task needs`, gates each task on the SPEC-010 tasks it calls; Phase 1 now also waits for G13, and Phase 4 for G6 and G7. Why: TASK-1c calls G13's `admin_token_resolve`, TASK-2e writes G10's cache and TASK-0c fills G7's `link_state`, while the phase lines named only G1 to G5, so a builder would write a second copy. Rejected: phase lines only.
- DEC-69: TASK-1f splits into TASK-1f1 (Cloudflare object helpers), TASK-1f2 (invite seal) and TASK-1f3 (`member add`). Why: one task held three units the design names as separately testable plus nine die points; it did not fit one fresh context.
- DEC-70: `PopoverState` holds one navigation mode plus two fields every mode handles, `pending: [Undo]` and `publishing: [Publish]`; popover close and app quit commit pending undos. Amends DEC-44. Why: with `undo` and `publishing` as modes, closing the popover, a second Delete or a right click during the window had no row, so a remove was dropped or the popover froze, and the table test locked that in. Rejected: modal undo (blocks the next action for 6 s).
- DEC-71: `member ls` writes a local members cache (the top-level key `members` of SPEC-010 G10's single `.health` file, through its per-key writer, matched by suffix), and `state` fills a v:3 row's `link_state` `paused` or `offline` from it by `origin`; no cache or a cache older than 24 h reads `live`. Why: `offline` had no producer, `state` makes no network call, and only R7 knew its own pause, so the admin's Team view and Needs a look could never show either value outside the fake CLI. Rejected: a tunnel API call from `state` (breaks its no-network rule, DEC-43).
- DEC-72: `member sync` applies deploy-wins only to `active`, `pausing`, `resuming` and `paused` records; `invited` and `joining` are reported. Why: after rotate on a paused member the record is `invited` with `prev_status` `paused` while `PAUSED` still holds the suffix; sync turned it into `paused`, cleared `prev_status`, and the re-join died at step 3 with the code spent. Rejected: sync on any status (the old row).
- DEC-73: replaced by DEC-78 (owner decision 2026-11-14). The round 1 fold kept the minting user's identity on the record and refused a token step under another minter.
- DEC-74: round 1 high findings folded as spec edits: `--invite-ttl` capped at 30 days (the Worker's forged-envelope bound); `pause`, `resume` and `rotate` refused for cloud members through a `member_can` mode argument; the T2 refusals also hold while any `vpc_service` binding is deployed (TN-12); `setup --force` downgrade also refused on marker `members:true`; join step 0 checks `caddy` and `cloudflared`; every redeem answer outside 200, 404 and 410 maps to `invite_unavailable`; `t/.by` validated before it reaches `index.tsv` (FG-16); the 1Password picker writes ids, never names; admin bucket calls preset the admin S3 pair; every edge-case row has an owning task; the Picture shows the Share Bar. The other warnings are in `docs/implementation-notes/multi-member.md`.

Spec validation round 2 (2026-11-14) folded these regressions of round 1's folds:

- DEC-75: `member sync` re-adds a `paused` record's suffix to `PAUSED` when the deploy lacks it, and never unpauses a `paused` record. Refines DEC-72 and DEC-15's deploy-wins rule for this one case. Why: under DEC-62 a missing pause can only come from a lost deploy, and turning the record `active` would ratify the loss; a forged `paused` record can only pause, which the admin sees in the printed list first. Rejected: deploy wins in both directions (the round 1 text).
- DEC-76: round 2 regression folds as spec edits: a path ending in `/` is `text/html` (sandboxed) and an absolute `Location` under `/<id>/` passes, so folder links work (SV-28, ML-4); every deploy builds its body from a settings GET made after `lease_take` (TN-01, CC-14 both orders); rotate also runs from `invited` and `joining`, and a cloud member's 404 copy names `invite` (MB-36); the members cache is the `members` key of SPEC-010 G10's single `.health` file, matched by suffix; `MEMBERS` is carried in DY-01, DY-02, the Interfaces input, DEC-15 and Q-REL-3; `r2_pointer_write` writes v:3 on R7; `PopoverState` leftovers in TASK-4b3, 4b9, 4b10 and 4b20 use `pending` and `publishing`; the gate table follows SPEC-010's current phases (G13 and G1b in Phase 1, G11 split into G11a to G11c) and puts TASK-1d after TASK-1c2.
- DEC-77: TASK-1c splits into TASK-1c1 (admin context) and TASK-1c2 (the lease), and the edge rows it collected in round 1 move to the tasks that exercise them. Why: after round 1 it held two units, seventeen test ids and five sentences.

Owner decisions 2026-11-14 on the round 2 rescope proposals:

- DEC-78 (OQ-9, proposal A, owner decision 2026-11-14): no minter identity on the record and no refusal for a different minter. Every token step lists the current minter's `GET /user/tokens` and deletes or updates the token named `share <host> <member_id>`, whatever the record says. No match: `rm`, `invite` and `rotate` go on and report the drift code `token_unreachable` with the token's `expires_on` (verb output and `member ls`, through the display-only `token_unreachable_until`); `renew` dies `token_unreachable` naming `rotate` (`invite` for a cloud member). `invite` and `rotate` mint under the current minter. `rm` needs no escape flag. Replaces DEC-73. Why: the identity lived in the member-writable `u/` record, so a forged value could block or skip `rm`, and the refusal blocked OT-10's stated recovery, a `rotate` under a new minter. Cost: a token another admin minted stays live until its expiry; the verb names it and the date. Rejected: the round 1 fold (DEC-73).
- DEC-79 (OQ-10, proposal B, owner decision 2026-11-14): never infer removal from a 401. A 401 sets `token.status` `invalid` with the copy `your key stopped working; ask the admin`; a token past its local `token_expires` stays `expired`. "You were removed" shows only when the member reads its own record as `removed`. The Share Bar never offers Clean up from an inference; Leave this tenant stays an explicit action behind the impact sheet. Replaces DEC-61, amends DEC-47 and gap G4; the removal check by the member's own pointer is gone. Why: day-90 expiry and a departed minting user both answer 401, and a member's pointer can answer 404 for unrelated reasons (no links, an expired link, a link it removed). Cost: a removed member usually sees the key line, not "removed", because `rm` deletes the token before it writes `removed`; the admin tells the member. Rejected: the round 1 fold (DEC-61).
- DEC-80 (OQ-8, owner decision 2026-11-14): the minter token comes from `SHARE_MINTER_TOKEN`, else the config key `minter_token_cmd` on DEC-46's rule (SPEC-010 G13: run once per process, never stored, only on `member add`, `invite`, `rotate`, `renew`, `rm` and `adopt`; codes `minter_token_missing`, `minter_token_cmd_failed`; `share minter-token --cmd|--clear|--test`). The Share Bar's Advanced tab picks its source like the admin key's (TASK-4b15). ADR-0009 amended. Why: the Share Bar's Invite, Send a new code, Rotate keys and Renew need the minter, and launchd gives it no shell environment. Rejected: `SHARE_MINTER_TOKEN` only (no member action from the Share Bar).
- DEC-81 (owner decision 2026-11-15): screenshots exist for the proof and the design score, so a state of TASK-4b14 to TASK-4b18 is reached by an in-app test hook (`-ShareBarShotsScreen`, DEBUG builds only, calling the store's own methods) or by the fake CLI, never by pointer, key or drag input on the live desktop. This replaces DEC-56 for those tasks; the ACs name the hook. Rejected: real interactions on the owner's desktop (a locked screen stalls the run).

Audit A13 (R7 config stores the bucket as `member_bucket=`) is ranked later and is not folded here; TASK-1g keeps `bucket=` as `### The 28 r2on sites` says.

## Open questions

Each is a fact the code cannot settle; the named task closes it before the task that depends on it.

| # | Question | Closes in |
|---|---|---|
| OQ-1 | The API-token permission-group name that allows Connectivity Directory service create and delete (spike O1 used wrangler OAuth as Super Admin) | TASK-1a(a), before TASK-1c1's scope probe |
| OQ-2 | The REST multipart `vpc_service` binding entry and its settings GET shape (spike O1 deployed with wrangler) | TASK-1a(b), before TASK-0e is exercised live and TASK-1f1 |
| OQ-3 | Whether the minter can mint a token scoped to one R2 bucket (spike O2 minted Zone Read only; Console Labs had no share bucket) | TASK-1a(c), before TASK-1f1 |
| OQ-4 | What a binding fetch returns when the member's cloudflared or Caddy is down | TASK-1a(d), before the SV-22 fixture is final |
| OQ-5 | The binding count one Worker accepts | TASK-1a(e) |
| OQ-6 | WebSocket and upgrade through a binding | TASK-3f |
| OQ-7 | That an R2 binding `put` with `onlyIf.etagMatches` on a stale etag returns null (documented, not sampled); the redeem claim relies on it | TASK-1a(h), before the first T2 tenant exists (a T1 tenant holds no `i/` object, so Worker v5 is inert until then) |
| OQ-8 (closed by DEC-80) | The Share Bar's Invite, Send a new code, Rotate keys and Renew also need the minter token, which ADR-0009 keeps in `SHARE_MINTER_TOKEN` only; gap G3 decided the admin token alone. Proposed: a `minter_token_cmd` key on DEC-46's rule; until decided, the Share Bar asks for the minter token per action and never stores it | decided 2026-11-14: `minter_token_cmd` on DEC-46's rule (SPEC-010 G13); the Share Bar picks its source in Advanced (TASK-4b15) |
| OQ-9 (closed by DEC-78) | Rescope proposal A: drop the minter identity on the record and its refusal | decided 2026-11-14: tokens are found by name in the current minter's list; no match reports `token_unreachable` with the expiry |
| OQ-10 (closed by DEC-79) | Rescope proposal B: never infer removal from a 401 | decided 2026-11-14: a 401 reads `invalid`; "You were removed" only from a record read as `removed` |

## Rescope proposals (validation round 2, applied)

Two areas drew criticals in round 1 and again in round 2: minter identity (proposal A) and removal detection from a 401 (proposal B). The owner approved both on 2026-11-14. They are applied in the text above as DEC-78 and DEC-79, which record the findings, the costs and what they replaced.

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
| The invite seal and MAC work with the system and Homebrew openssl | sampled 2026-11-13 on the Mac (output masked to a boolean) | `/usr/bin/openssl` (LibreSSL 3.3.6) and `/opt/homebrew/bin/openssl` (OpenSSL 4.1.0): `enc -aes-256-cbc -pbkdf2 -iter 200000 -md sha256 -salt -a -A` roundtrip `roundtrip-ok`; `dgst -sha256 -hmac` ok. Linux CI openssl not sampled; TASK-1f2 runs on both CI runners |

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
| NC-6 | `r2_deploy_meta` ignores the carried bindings | dry `.cf/script.json` with `M_aaaaaaa1`, `M_bbbbbbb2`, `PAUSED` `["aaaaaaa1"]`; `WORKER_SHA` bumped in a temp copy | `setup <h> --r2 --bucket B` rerun on the origin | `mm DY-01: a setup rerun keeps every member binding and PAUSED` |
| NC-7 | `lease_take` returns 0 without the PUT | `SHARE_TEST_MEMBER_IDS="m-an-aaaaaaa1 m-bo-bbbbbbb2"`; first `member add an` held by `SHARE_R2_DRY_PAUSE="PUT i/<h of SHARE_TEST_CODE>"` | second `member add bo` runs to the end, then the first resumes and deploys without `M_bbbbbbb2` | `mm CC-01: two admin adds at once keep both bindings` |
| NC-8 | the member reconcile drops the origin filter | member HOME (member_id `m-an-aaaaaaa1`); dry `m/ee0001` v:3 `origin` `m-bo-bbbbbbb2` aged 660 s, no local row | `r2_reconcile` row 6 | `mm RC-06: a member never touches another origin's pointer` (`mdel ee0001` = 1) |
| NC-9 | the deploy builder reads `PAUSED` from `u/` records | dry deploy `PAUSED` `["aaaaaaa1"]`; `u/m-an-aaaaaaa1.json` forged to `active` | `member pause bo` (any verb that deploys) | `mm FG-05: a forged record never unpauses a member` |
| NC-10 | `member rm` skips the service delete | dry `.cf/services/<id>.json` for an | `member rm an` | `mm MB-13: no object of a removed member remains` (lists `.cf/services/`) |
| NC-11 | join installs the service before its record write | `SHARE_R2_DRY_FAIL="PUT u/m-an-aaaaaaa1.json"` | `cmd_join` step 3 | `mm DP-join-3: a join that loses the record race leaves no service` (stub `launchctl` log shows a bootstrap) |
| NC-12 | `r2_record_raw` treats v:3 as unreadable | dry `m/ff0001` v:3; `o/9e0001.00000001/x` aged 25 h with no record | bare `share prune` on the origin | `mm SV-06: a v:3 pointer never blocks the orphan sweep` (the old upload stays; the warning prints) |
| NC-13 | the Worker ignores `PAUSED` | `worker.mjs`: `PAUSED` `["aaaaaaa1"]`, v:3 `ab0001` of that origin | Worker row 12 | `v5 SV-12: a paused member's link answers 503` |
| NC-14 | reconcile row 9 removed (no young-skip) | member HOME row `ac0001`, own pointer, `t/ac0001` aged 60 s | `r2_reconcile`; then the admin's pending DELETE lands; then a second reconcile | `mm CC-06: an admin revoke in flight is never undone` (the second reconcile rewrote the pointer) |
| NC-15 | the Worker serves a binding answer without `X-Share-Served` | `worker.mjs` fake binding answers 200 with no header | Worker row 15 | `v5 SV-22: a foreign listener is never served` |
| NC-16 | `rand_id` skips the `t/` check | dry `t/ad0001`; `SHARE_TEST_IDS="ad0001 ad0002"` | member `add` | `mm SV-09: a tombstoned id is never picked` (the add lands on `ad0001`) |

## Review
Date: 2026-11-15 | Reviewer: /kit:review (scope: Phase 1, TASK-1b to 1i; the Phase 0 review is in git history)

### Verdict: SHIP

Seven findings were fixed in the same branch before this verdict (marked FIXED). One stays open as a TODO; it is not a hole in the paths this phase ships.

### Findings

## HIGH (FIXED): the real redeem POST sent a trailing newline
**File:** bin/share `worker_call`
**What:** the real-mode POST fed the body through a here-string, which appends a newline; the Worker reads the body raw and wants exactly 64 hex, so every live join would have died 400 (`invite_unavailable`). The dry seam passes the body as an argument, so the suite could not see it.
**Fix:** `printf '%s' "$3" | curl --data-binary @-`. Live proof is owed by SG-11 (ML-3).
**Effort:** S

## HIGH (FIXED): a forged `lock/admin` could steer the rerun line
**File:** bin/share `lease_line`, `mb_report`
**What:** any publisher token writes `lock/admin`; its `verb` and `holder` reached the `member ls` rerun line and the terminal raw, so a forged body could print `rerun: share member rm ...` or escape sequences.
**Fix:** `lease_jq_clean` whitelists the verb, shapes the holder and member, and drops the rerun line for an unknown verb. Test: `mm MB-28: a forged lock/admin never steers the rerun line nor reaches the terminal raw`.
**Effort:** S

## MEDIUM (FIXED): record date fields reached refusal text unvalidated
**File:** bin/share `reg_jq_valid`
**What:** `updated`, `added` and `joined` were printed (the `member_busy` copy) without a shape check.
**Fix:** each must be an ISO-like string of `[0-9TZ:.-]`, else the record is `record_invalid`.
**Effort:** S

## MEDIUM (FIXED): the join probe's own rm could end the join
**File:** bin/share `join_probe`
**What:** `cmd_rm` dies through `exit`, which `|| true` cannot catch, so a failing cleanup would end a join that had just proved its link.
**Fix:** the rm runs in a subshell.
**Effort:** S

## LOW (FIXED): `member sync --rebind` put an account service id into a jq program unshaped
**File:** bin/share `cmd_member_sync`
**Fix:** a service id outside `[A-Za-z0-9-]{1,64}` is skipped.
**Effort:** S

## LOW (FIXED): a step's record write came before its lease renew
**File:** bin/share `reg_step`
**Fix:** renew first, so a holder that lost the lease writes nothing more (DEC-63).
**Effort:** S

## MEDIUM (OPEN): teardown without the admin token cannot see a deployed member binding
**File:** bin/share `cmd_teardown` (`t2_refuse`)
**What:** with no admin token, teardown reads only the config and the marker; a forged `members:false` plus a dropped config key (TN-12) passes it while bindings are deployed. With the admin token TN-12 holds.
**Why:** a teardown then deletes the origin tunnel under a members tenant; member links keep working (they ride their own tunnels), the origin's do not.
**Fix:** require the admin token for teardown of an R2-on origin, or name the gap in the docs. Left for SG-07 (rm and teardown work) to decide.
**Effort:** S

## LOW (FIXED): `member add <name>` resuming a record ignored `--cloud`/`--machine`
**File:** bin/share `cmd_member_add`
**What:** the resumed record's mode won silently.
**Fix:** a flag naming the other mode refuses `member_name_taken`.
**Effort:** S

### Previously rejected
none (no `docs/verification/rejected-findings.md` in this repo)

### TODOs (open follow-ups)
- Teardown of an R2-on origin without the admin token (MEDIUM above).
- SG-11: the first live join proves the redeem POST body (ML-3).
