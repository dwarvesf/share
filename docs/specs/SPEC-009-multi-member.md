# Spec: multi-member tenants
Generated: 2026-11-13
Status: DRAFT
Lane: full
Depth: research (outside: whether a Workers VPC tunnel binding reaches a plain-HTTP loopback Caddy from a Free-plan Worker, and whether an API token can mint account-owned R2 bucket-scoped tokens and extend their expiry) + blind-spot (failure: a multi-step admin verb that dies mid-way leaves an orphan tunnel, VPC Service, binding or token that no rerun finds)
References: `docs/briefs/DECISION-BRIEF-multi-member.md` (r2, the design this spec builds); `docs/research/2026-11-13-current-state-machines.md` (state map with line cites; imitate its step tables for every new verb); `docs/research/2026-11-13-multi-member-review-1.md` (33 findings, each folded below); `docs/research/2026-11-13-multi-member-outside.md` and `docs/research/2026-11-13-multi-member-spikes.md` (Cloudflare facts); `docs/SYSTEM-DESIGN.md` rev B (diagram ids cited in `## Design`); ADR-0007, ADR-0008, ADR-0009; `bin/share` `cmd_setup_r2` steps 0 to 14 (imitate: every refusal before the first write, every step skipped when in place), `r2_reconcile` (imitate: a 10-minute age test before deleting anything another writer may be finishing), `r2_dry` and `r2_api_dry` (extend these seams, never a new test transport); `docs/research/2026-11-13-implicit-state-machines.md` (the state machine audit: decisions D1 to D9, amendments A1 to A12 folded below, each with a Decision Log entry).
Depends on: SPEC-010 (`docs/specs/SPEC-010-state-groundwork.md`). Phase 1 requires SPEC-010 tasks G1 to G5 shipped (codes and `die_code`, the step journal, `profile_role`, `config_put`, the skill reading `share state`). Phase 0 may land first, except TASK-0f, which needs G4. Phase 4's Share Bar tasks also need SPEC-010 G9 to G11, G13 (the admin key command) and G14 (`share config`).

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

 admin (any machine; CLOUDFLARE_API_TOKEN or admin_token_cmd, SHARE_MINTER_TOKEN)
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
- The deployed Worker settings, `GET /accounts/<a>/workers/scripts/<w>/settings`: `.result.bindings[]`, read on every deploy path to carry `vpc_service` bindings and `PAUSED` forward (shape of the `vpc_service` entry: TASK-1a(b)).
- The bucket through the S3 API (unchanged transport, ADR-0007): `share.json`, `u/`, `i/`, `t/`, `lock/admin`, `m/`, `o/`.
- The Cloudflare API with the admin token: tunnels, tunnel configurations, tunnel connections, tunnel token, Connectivity Directory services, Worker scripts. With the minter token: `/user/tokens` (list, create, update, delete, permission_groups).
- Local: config, `index.tsv`, Keychain items `share-api[.<p>]:<host>` (publisher token) and `share-tunnel[.<p>]:<host>` (connector token), the existing services.

Outputs / produces:
- The Worker v5 HTTP contract (below), relied on by `join`.
- `share state` JSON stays `schema: 1` and never gains a `state.state` value (DEC-32). It gains, additively: per row `origin` (member name or empty) and `link_state` with the SPEC-009 values `revoked` and `paused` beside SPEC-010's `live`, `expired`, `shadowed`, `gate_missing`, plus `reason`; per profile `role` (SPEC-010 G3; `member` on R7), and on R7 `member = {id, name, mode, status, step, token_expires}` (the earlier draft's flat `member_id`/`member_status` became `member.id`/`member.status`) and `token = {source, status, expires_on}` (DEC-39). Share Bar reads them (TASK-4b1).
- `share member ls --json`: one object per member with `member_id`, `name`, `mode`, `status`, `step`, `step_name`, `lease` (`holder`, `verb`, `step`, `live`), `deploy` (`bound`, `paused`), `account` (`tunnel`, `connectors`, `services`), `token_expires`, `invite_expires`, `can[]` (the verbs `member_can <status> <verb> admin` allows from the record's status, plus `finish` for an `...ing` whose lease is stale; the Share Bar's row menu lists exactly these, DEC-53), `drift[]`; each `drift[]` entry is a stable code from SPEC-010's `code_text` (`config_drift`, `deploy_paused_record_active`, `deploy_bound_record_removed`, `extra_connector`, `record_invalid`), never free text (DEC-35).
- Every refusal a SPEC-009 verb adds (member verbs, join, `min_cli`) goes through SPEC-010's `die_code <code> <message> [next]`: the human line is unchanged in shape, `SHARE_ERROR_JSON=1` adds the JSON line (DEC-35).

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
| `u/<member_id>.json` | `{v:1, member_id, name, mode:"machine"\|"cloud", status, prev_status?, step?, step_name?, rotation:0, tunnel_id?, tunnel_name?, vpc_service_id?, port?, token:{id, name, expires_on}, invite:{hash, expires}?, added, joined?, updated, by}`; never a secret; `step`/`step_name` name the step of the running `...ing` (DEC-31) and are dropped on reaching a resting status | admin verbs (If-None-Match, then If-Match); member: `joining` (from `invited`), then `prev_status` if set else `active` (from `joining`, DEC-30), `left` (from `active`/`paused`); every write passes `member_can` (`### Member status transitions`) | admin verbs, `member ls`, join, member `status` |
| `u/purged.json` | `{v:1, ids:["m-..."]}` | `member purge` (If-Match) | member_id generation |
| `i/<64 hex>` | `{v:1, member_id, expires:<epoch>, sealed:"<base64>", mac:"<64 hex>"}` | `member add`, `invite`, `rotate` | Worker redeem only |
| `lock/admin` | `{v:1, holder:"<host>:<pid>:<nonce8>", verb, member, step, taken}`; `lease_renew` rewrites `step` at each step (DEC-36); age judged by `LastModified` | every admin verb | every admin verb, `member ls` (prints the holder live or stale with the rerun) |
| `m/<id>` v:3 | `{v:3, id, storage:"machine", origin, name, by, added, expires, opts, type}`; `opts` tokens `noindex` (and `live` only if TASK-3f passes) | machine member `add` (If-None-Match), own reconcile | Worker, every reader |
| `t/<id>` | `{v:1, id, origin, by, at}`; `at` display only, age by `LastModified` | admin revoke, `member rm` | owner reconcile, `member sync` sweep, `rand_id` |

Status values: stored `adding`, `invited`, `joining`, `active`, `pausing`, `paused`, `resuming`, `inviting`, `rotating`, `renewing`, `removing`, `removed`, `left`. Derived, never stored: `EXPIRED` (`invited` and `invite.expires` past), `ONLINE`/`OFFLINE` (connector count from the tunnel API). The only allowed moves between them are the rows of `### Member status transitions` below.

Sealed bundle (plaintext inside `sealed`): `{v:1, host, bucket, r2_endpoint, member_id, name, mode, port?, tunnel_id?, publisher_token, connector_token?, token_expires_on}`.

Invite crypto (DEC-14; roundtrip sampled in `## Grounding`): `code` = 20 chars from the RFC 4648 base32 alphabet, from `/dev/urandom`; object id `h = sha256("share-invite-id:" + code)`; `sealed = base64(openssl enc -aes-256-cbc -pbkdf2 -iter 200000 -md sha256 -salt)` with the passphrase passed as `-pass fd:3`, never argv; `mac = HMAC-SHA256(key = sha256("share-invite-mac:" + code), sealed)`. Unseal verifies `mac` first.

Local config keys:

| Key | Profile | Meaning |
|---|---|---|
| `members=on` | origin | T2, together with the marker: the origin is T2 when config `members=on` OR marker `members:true`; when they disagree `state.tier_drift` is true and verbs report `config_drift` (DEC-33). The teardown, migrate and `--no-r2` refusals read the marker, so a dropped config key never opens them |
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

Named rows (DEC-38, inside the same v5 bump, no extra `WORKER_VERSION`): the table above is a pure `decide(request, env, rec)` returning `{row, status}`, and `handle` performs its answer. Row ids are constants: `ALIAS_301`, `WRONG_HOST`, `BAD_PATH`, `HEALTHZ`, `PASS_NON_ID`, `PASS_MISS`, `BAD_JSON`, `PASS_V2`, `V2_EXPIRED`, `BAD_RECORD`, `GATE_DENIED`, `V3_PAUSED`, `V3_UNBOUND`, `V3_DOWN`, `V3_METHOD`, `V3_EXPIRED`, `V3_SERVED`, `REDEEM_OK`, `REDEEM_METHOD`, `REDEEM_BAD_BODY`, `REDEEM_UNKNOWN`, `REDEEM_EXPIRED`, `REDEEM_UNAVAILABLE`, `SHARE_PATH_UNKNOWN`, `CLOUD_OBJECT`. Status codes stay as the table says. Every Worker 404 answers one plain-text body, `no such link (it may have expired or been removed)`, the same for every 404 row, and no header names the row: a per-row answer would be an id-existence oracle over 24-bit ids.

Cloudflare API calls added (admin token unless marked minter): tunnels `POST /accounts/<a>/cfd_tunnel` (`config_src: cloudflare`), `PUT .../cfd_tunnel/<t>/configurations` (only the `http_status:404` catch-all), `GET .../cfd_tunnel/<t>/token`, `GET .../cfd_tunnel/<t>/connections`, `DELETE .../cfd_tunnel/<t>/connections`, `DELETE .../cfd_tunnel/<t>`, `GET .../cfd_tunnel?name=<n>&is_deleted=false`; VPC Services `POST|GET|PUT|DELETE /accounts/<a>/connectivity/directory/services[/<id>]`; Worker deploy (existing multipart PUT, metadata gains `{type:"vpc_service", name:"M_<8hex>", service_id}` entries, `PAUSED`, `DEPLOY`); minter: `GET /user/tokens`, `POST /user/tokens`, `PUT /user/tokens/<id>`, `DELETE /user/tokens/<id>`, `GET /user/tokens/permission_groups`.

### UI changes

CLI verbs (admin verbs need the admin token, `CLOUDFLARE_API_TOKEN` or else the output of the config key `admin_token_cmd` (SPEC-010 G13, DEC-46), proven as admin by a settings GET 200, and take the tenant from `--tenant <host>` or the profile's `hostname`; token verbs also need `SHARE_MINTER_TOKEN`):

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
| `share [--profile p] join <host> <code>`; `share join` | member | redeem; the bare form resumes a died join from its journal step; on R7 of the same member_id it re-joins after `rotate` or `invite` |
| `share leave [--local]` | member | `--local` makes no bucket call |
| `share status` (on R7) | member | record status, token expiry, Worker pair, removal detection |

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
| 547 | `r2_pointer_put` | writes v:3 with `origin=<member_id>` |
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

Non-`r2on` sites that change on R7: `r2_reconcile` (own-origin filter), `cmd_serve` (hourly loop runs `prune --loop`, TASK-2c), `cmd_teardown` (refused: "use share leave"), `cmd_setup` (refused), `cmd_status` (member variant), `write_caddyfile` (main site answers `http://<host>:<port>` and loopback, as named mode does today, L1091).

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
| rotate | admin | active, paused | rotating | invited (prev_status = active or paused) |
| renew | admin | invited, active, paused | renewing | the status it started from |
| rm | admin | every status but removed | removing | removed |
| purge | admin | removed | (none) | record deleted |
| adopt | admin | (none) | (none) | active (cloud) |
| join step 3 | member | invited | joining | (step 6) prev_status if set, else active |
| leave | member | active, paused | (none) | left |
| sync | admin | any | (none) | deploy wins for paused/active only (`member sync` below) |

Guards:
- A verb that finds the record in a different verb's `...ing` refuses with code `member_busy`, copy `share: <name> is mid-<verb> (step <n>) since <time>; finish it: share member <verb> <name>`. Two exceptions: `rm` wins from any status (CC-04), and `sync` reports instead of refusing.
- The member never writes once the record is `removing` or `removed` (`member_can` answers no for actor member there).
- `prev_status` (DEC-30, DEC-41): written when an `...ing` is entered from `active` or `paused`; entering an `...ing` from `invited`, `joining` or `left` keeps whatever it holds; a rerun never rewrites it. Reaching `active`, `paused`, `left` or `removed` clears it; reaching `invited` keeps it, so rotate's restore target survives a later `invite` or `renew`. Join's final write sets `prev_status` if set, else `active`, and clears it.
- "The status it started from" (renew, and an interrupted invite): `invited` when the record holds an `invite` object (a join is pending), else `prev_status`. Join's final write drops `invite`, since the code is spent.
- EXPIRED, ONLINE and OFFLINE stay derived (DEC-19); `member_can` never sees them.
- Each `...ing` write also writes `step` and `step_name` (DEC-31); the resting write drops them.

Rotate (DEC-30): rotate ends in `invited` with `prev_status` kept; join's final write restores it, so a paused member stays paused after re-joining (MB-12's intent) and join step 3 keeps one rule (`invited`).

Invite and join refusal contract (DEC-37). Each is a `die_code` code; the copy is the member's terminal line:

| redeem answer | code | copy |
|---|---|---|
| 404 | `invite_unknown_or_used` | `this invite was already used or never existed; ask the admin: share member invite <name>` |
| 410 | `invite_expired` | `this invite expired; ask the admin: share member invite <name>` |
| 503 | `invite_unavailable` | `the invite could not be released (it is now spent); ask the admin: share member invite <name>` |
| mac mismatch | `invite_tampered` | `this invite was altered; ask the admin for a new one` |
| record 412 | `member_changed` | `the admin changed this member during the join; nothing was kept here` |

### Admin verb write orders

Every admin verb: refusals and scope probes first; lease; record intent (If-Match, through `reg_status` and `member_can`); each Cloudflare step skipped when in place; record final; lease release. Each step below names how a rerun finds what an earlier run made. Each step is also an `op_step` of SPEC-010's journal on the admin's machine and a `step`/`step_name` on the record and the lease (DEC-31, DEC-36), so `member ls` and `status` name where a died verb stopped and print its rerun.

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
| 0 | refuse: profile not R0, unless R7 of the same host (a re-join after `rotate` or `invite`, DEC-30); CLI below marker `min_cli`; machine: invite port busy here | nothing | |
| 1 | `POST /_share/redeem` with `h` | code spent, nothing local | admin `member invite` |
| 2 | verify `mac`, unseal; on an R7 profile refuse unless the bundle's `member_id` equals config `member_id` (`member_changed`, nothing local touched); store both tokens in the Keychain (replaced in place on a re-join); write config (`role`, `member_id`, `member_mode`, host keys) through `config_put` | local config, no record change | `share join` (bare) resumes from the journal step |
| 3 | GET record: status `invited`, same member_id; PUT status=joining (If-Match, `member_can invited join member`). 412: remove local config and tokens (keep them on a re-join), die `member_changed` | | |
| 4 | machine: write Caddyfile, install and start the service | running service | resume |
| 5 | probe: add a probe file (v:3), GET it through `https://<host>/` 3x200, rm it | probe row | resume retries; failure names `member ls` for the admin |
| 6 | record status = `prev_status` if set, else `active`; `joined`; `prev_status`, `invite`, `step` dropped (DEC-30) | | |

`member rm <name>` (`seq-member-rm`): lease; status=removing; deploy without `M_<8hex>` and without the id in `PAUSED`, nonce 3x; delete VPC Service (404 = done); delete tunnel connections, then the tunnel (404 = done); delete the token (404 = done); for each v:3 with this `origin`: `t/<id>` (If-None-Match; 412 = present), DELETE `m/<id>`; cloud links with `origin` this member per `--cloud-links`; delete the record's `i/`; status=removed; lease release.

`member pause` / `resume`: lease; status=pausing|resuming; deploy with the id added to or dropped from `PAUSED` (carry-forward otherwise); status=paused|active.

`member invite`: lease; status=inviting (from `invited`, `joining` or `left`; `prev_status` kept, DEC-41); delete token, re-mint; machine: delete tunnel connections; `--port` updates the VPC Service (`PUT`); record invite hash; delete old `i/`; new `i/`; status=invited.

`member rotate` (DEC-10): lease; status=rotating, `prev_status` kept; `rotation+1`; new tunnel `...-r<n>` and new VPC Service of that name; deploy rebinding `M_<8hex>` to the new service (same binding name, so links and PAUSED stay); delete old connections, old service, old tunnel; delete and re-mint the token; new invite; status=`invited`, `prev_status` kept (DEC-30; the earlier draft ended at `prev_status`, which join step 3 then refused, so every re-join after rotate died). The member is offline until it runs `share join <host> <code>` again; join on an R7 profile with the same member_id replaces tokens in place, and join's final write restores `prev_status`, so a paused member comes back paused.

`member renew`: lease; status=renewing; `PUT /user/tokens/<id>` with the same policies and the new `expires_on`; record `token.expires_on`; status back to the status it started from (`### Member status transitions`).

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
`PopoverState` (gap G1, DEC-44): one reducer in `ShareBarCore`, one swift test per transition.

| State | Entered by | Left by |
|---|---|---|
| `firstRun` | every profile has `role` `none` | a profile gains a role |
| `list(scope, query)` | default; Back from `issues`; ⌃⌥S | footer button, drop, + |
| `issues` | the footer "N need a look" | Back, Esc, ⌃⌥S |
| `publishing(step, of)` | a file chosen with +, or released on a drop | the add exits: link copied and its row flashes, or the CLI sentence in the footer |
| `dropTarget` | an outside file drag enters the status item or the popover | release (to `publishing`), leave (back) |
| `undo(action, deadline)` | Remove, Revoke, the Delete key, a bulk Remove | the deadline passes (the CLI call runs once), Undo or ⌘Z (no call runs) |
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

Tenants detail: host with Open in browser, a status word with a dot (Serving, Starting with a spinner, Stopped: <reason>, Tunnel not connected, Interrupted), an interrupted-command callout with Roll back and Resume, then Your role, Storage, Members (not shown to members), Served from, Key (source and expiry). Buttons per the interactions doc section 5 table. A member whose own record is `removed`, or whose key answers 401, sees "You were removed from <host>" with Clean up (`share leave --local`) (gap G4, DEC-47).

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

### Phase 0: Groundwork (helps with no members; one release, Worker v5)

Phase 0 ships before TASK-1a's samples on purpose: a T1 tenant holds no v:3 pointer, `vpc_service` binding or `i/` object, so the new Worker branches are inert until the first T2 tenant, and TASK-1a runs before that. A sample that disagrees with the documented shape lands as a Worker v6 fix in Phase 1.

- [ ] TASK-0a: CLI version constant. `SHARE_VERSION=0.9.0` near the top of `bin/share`, `share version`, and `bin/release` rewrites the constant in the release commit. AC: `share version` prints `X.Y.Z`; a suite check finds it equal to the newest `## [vX.Y.Z]` heading in `CHANGELOG.md`; OT-19.
- [ ] TASK-0b: Caddy serves listed rows only. `write_caddyfile` renders, per live non-revoked snapshot row, a matcher on `/<id>` and `/<id>/*` with `root * "$pub"` and the existing `file_server`; the catch-all `handle` answers 404; every response carries `X-Share-Served: caddy`; `rows_in` accepts `revoked` and `revoked_by=`. AC: SV-01 to SV-05; SPEC-008 compat row 1 updated to expect the new Caddyfile and nothing else.
- [ ] TASK-0c: readers. `r2_record_raw` treats any `storage:"machine"` record with no `prefix` and `v >= 2` as readable (the sweep no longer blocks); `r2_take` validates v:3 into the display rows with `origin`; the origin's reap list stays v:2; `rand_id` refuses an id with a `t/<id>`; `state` rows gain `origin`, and SPEC-010's per-row `link_state` gains `revoked` (opts `revoked`, `reason` `revoked_by=<by>`) and `paused` (a v:3 row whose origin member is paused; R7 knows its own). `state` stays `schema: 1` and gains no `state.state` value (DEC-32). AC: SV-06 to SV-09, SV-25, OC-01, OC-06, OC-08, RC-14; `state_schema_ok` (tests/share.sh L1000) passes unchanged on every new fixture.
- [ ] TASK-0d: Worker v5, every row of `### API changes`, one version bump, built as the pure `decide()` with named rows and the uniform 404 body (DEC-38). `tests/worker.mjs` gains a fake `vpc_service` binding (records each request, answers from a fixture or throws) and an R2 fake honoring `onlyIf.etagMatches`, and asserts the row id of every request, not only its status. AC: SV-10 to SV-24, SV-26; existing rows pass unchanged on the v5 source.
- [ ] TASK-0e: deploy carry-forward. `r2_deploy_meta` takes the deployed bindings (from the settings GET every deploy path already makes) and re-sends each `vpc_service` and `PAUSED`, plus a fresh `DEPLOY`; the deploy compare adds the binding set and `PAUSED`; `setup --force` that would lower `WORKER_VERSION` is refused while the settings carry a `vpc_service` binding or a non-empty `PAUSED`; the dry seam keeps these bindings in `script.json`; deploy waits for `X-Share-Deploy` 3x. AC: DY-01 to DY-05.
- [ ] TASK-0f: member config keys ride the key-keeping writer (DEC-34). Requires SPEC-010 G4 (`config_put`). Every writer a SPEC-009 path adds or touches (`setup --members`, `--no-members`, join's config write, `leave`) calls `config_put` with its owned set; no new whitelist writer. AC: a config holding `members=on`, `role=member`, `member_id=m-an-aaaaaaa1`, `member_mode=machine` keeps all four lines byte for byte across a `setup <host>` rerun and an `api-token --cmd '<cmd>'` write; TN-10.

### Phase 1: Tenant, lease, registry, add, join, ls, sync

Phase 1 starts only after SPEC-010 G1 to G5 have shipped: TASK-1c, 1e, 1h and 1i call `die_code`, the step journal, `profile_role` and `config_put`.

- [ ] TASK-1a: residual live samples on Console Labs, throwaway `share-e2e-*` names, cleanup asserted by name. (a) VPC Service create, get, list, update, delete over REST with an API token, and the token permission-group names that allow it; (b) a multipart deploy with a `vpc_service` binding entry, the settings GET shape of that binding, and that a deploy without it drops it; (c) the minter mints a token with Workers R2 Storage Bucket Item Write on one `share-e2e-*` bucket plus Zone Read, its S3 pair does `PUT If-None-Match`, `PUT /user/tokens/<id>` moves `expires_on`, `DELETE` revokes it; (d) the binding fetch with the member's cloudflared stopped, with Caddy stopped, and with a non-Caddy listener on the port: throw or status, and how long; (e) a deploy with 25 `vpc_service` bindings; (f) `GET .../connections` with one cloudflared: connector count vs `conns`; delete connections, then the tunnel; (g) a fresh remote-managed tunnel with only the catch-all over REST, and `GET .../token`; (h) R2 binding `put` with `onlyIf.etagMatches` on a stale etag returns null. AC: each answered in `docs/implementation-notes/multi-member.md` with the masked excerpt; (a), (b) or (c) failing stops Phase 1 and amends `## Design`; (e) failing lowers the cap to the measured value.
- [ ] TASK-1b: dry seams. `r2_api_dry` answers tunnels, configurations, connections, token, Connectivity Directory services and `/user/tokens` from state files under `.cf/`, each call one `API <METHOD> <path>` line in `r2-calls.log`, all failable through `SHARE_R2_DRY_FAIL` and `SHARE_R2_DRY_FAIL_TIMES`; `SHARE_TEST_MEMBER_IDS` and `SHARE_TEST_CODE` make ids and codes deterministic (as `SHARE_TEST_IDS`, L160); `SHARE_R2_DRY_WORKER` names a command (the suite sets `node tests/worker.mjs --dir <dry> --host <h>`) that answers dry redeem and probe requests, and `tests/worker.mjs` integration mode gains `--post <path> <body>` and `--bind M_<hex>=127.0.0.1:<port>`. AC: seam self-checks in a new `=== members: dry seams ===` section; every seam refuses outside `SHARE_TUNNEL=0` and a `.test` host, as `r2_api_dry` does (L3612).
- [ ] TASK-1c: admin context and lease. `cmd_member` dispatcher; tenant from `--tenant` or profile; the admin token from SPEC-010 G13's `admin_token_resolve` (`CLOUDFLARE_API_TOKEN`, else `admin_token_cmd`; gap G3, DEC-46), proven by settings GET 200; bucket name from the `BUCKET` binding; marker check; minter from `SHARE_MINTER_TOKEN` only; scope probes before the first write (each missing scope named); `lease_take`, `lease_renew` before each Cloudflare step, `lease_release`, takeover rules. The lease body names `verb`, `member` and `step`, rewritten by each `lease_renew` (DEC-36). Every refusal is a `die_code` code (DEC-35). AC: CC-01, CC-09, CC-10, CK-01, FG-10, WM-03, MB-04, OT-16; CC-09 also asserts the `lock/admin` body names the verb, member and step of the killed holder; every refusal in this task's tests, rerun with `SHARE_ERROR_JSON=1`, ends with one JSON line whose `code` is in `share state-fn codes`; with `CLOUDFLARE_API_TOKEN` unset and `admin_token_cmd` set to a fixture command, `member ls` runs the command once and proves admin, and with both unset it dies `admin_token_missing` before any bucket or API call (CC-13).
- [ ] TASK-1d: tenant T1 to T2 and back. `setup <h> --r2 --bucket B --members [--yes]`, `--no-members`, and the T2 refusals in teardown, migrate, `--no-r2`. T2 is config `members=on` OR marker `members:true`; the refusals read the marker; a disagreement sets `state.tier_drift` and reports `config_drift` with its repair line (DEC-33). Teardown on T2 refuses with `die_code members_present "<host> has members; remove every member first" "share member ls"` (gap G6, DEC-49). `--members` and `--no-members` run as the journaled verbs `setup-members` and `no-members` (SPEC-010 G2a), one `op_step` per write, so the Share Bar's Turn on members shows the steps and Stop then Resume continues (gap G7, DEC-50). AC: TN-01 to TN-09 (TN-09 with its marker-then-config die row), TN-11; TN-07 asserts the code `members_present` under `SHARE_ERROR_JSON=1`; the die-point loop (kill at each `op_step`, rerun, happy end state, empty `ops/`) for `setup-members` and `no-members`.
- [ ] TASK-1e: registry. `u/` reader and validator (a record failing validation is reported, never trusted), member_id generation unique against records, `u/purged.json`, live bindings and account services; `member_can`, the `case` table of `### Member status transitions` (DEC-29); `reg_status` (If-Match through `member_can`; re-read once on 412 and continue only if `member_can` still allows the move from the new status); the `prev_status` rule (DEC-41); `step`/`step_name` on every `...ing` write (DEC-31). AC: MB-03, MB-24, MB-25, FG-05 to FG-07, FG-13; `mm member_can: every (status, verb, actor) triple` iterates all 14 x 12 x 2 triples (13 stored statuses plus none) and matches the doc table, with `rm` and `sync` excepted from `member_busy`.
- [ ] TASK-1f: `member add` (both modes), the invite seal, the step table above. AC: MB-01, MB-02, MB-05, DP-add-1 to DP-add-9, Q-SEC-6 grep of argv and logs.
- [ ] TASK-1g: R7. Detector (the `member` row of SPEC-010's `profile_role`), `member_mode`, every row of the `r2on` table, the v:3 pointer writer, member add/rm/refresh of own machine links, refusals. AC: LK-01 to LK-07, LK-16 to LK-18, WM-01, WM-02, OT-05.
- [ ] TASK-1h: `join` and its bare resume, recorded in the `join` journal (SPEC-010 G2) and resumed from the journal step, never from file presence (DEC-31); the re-join on an R7 profile of the same member_id, and join's final write restoring `prev_status` (DEC-30); the invite and join refusal table, each row a `die_code` code (DEC-37). AC: MB-06, MB-07 (one code asserted per refusal), MB-26, MB-27, DP-join-1 to DP-join-6, CC-11, OT-04, OT-06.
- [ ] TASK-1i: `member ls` and `member sync` (with `--rebind`, expired-invite delete). `member ls` prints, per record in an `...ing`, `<name>: <status>, step <n> of <m> (<step_name>), lease held by <holder> (live)` or `(stale since <time>; rerun: share member <verb> <name>)` (DEC-36); `--json` adds `step`, `step_name`, `lease`, and `can[]` (gap G10, DEC-53); `drift[]` entries are codes (DEC-35). AC: MB-08, MB-20, MB-22, MB-23, MB-28, MB-29, OC-03, FG-05, FG-06.

### Phase 2: rm, leave, purge, tombstones, the member reconcile loop

- [ ] TASK-2a: admin revoke. `rm <id>` on a v:3 of another origin with the admin token proven: `t/<id>` (If-None-Match), DELETE pointer, proof GET 404, message "revoked; the bytes stay on <name>'s machine"; without the admin token refused; v:2 from a non-origin refused. AC: LK-08 to LK-10, LK-19, WM-04.
- [ ] TASK-2b: reconcile, every row of the table above, and the tombstone sweep in `member sync`. AC: RC-01 to RC-14, CC-06 to CC-08, FG-01 to FG-04, FG-11, FG-14, OC-02.
- [ ] TASK-2c: member serve loop. On R7, `cmd_serve` keeps `SHARE_API_TOKEN_OFF=1` for Access and runs `share prune --loop` hourly, which resolves the publisher token from the Keychain only and runs local expiry, own pointer expiry and reconcile; a locked Keychain logs one line and skips. AC: LK-11, LK-12, OT-02, Q-OPS-1.
- [ ] TASK-2d: `member rm` and `member purge`. AC: MB-13, MB-16, DP-rm-1 to DP-rm-8, LK-15, Q-SEC-5 (dry listing of every object kind empty for the member).
- [ ] TASK-2e: `leave`, `leave --local`, member `status` removal detection. Removal seen by `status`, join or the member loop (record `removed`, or the publisher token answering 401) is written to the `.health` cache, so `state.member.status` reads `removed` with no network call and the Share Bar shows "You were removed" with Clean up (gap G4, DEC-47). AC: MB-14, MB-15, MB-21 (also asserts `state.member.status` `removed` after `status`), DP-leave-1 to DP-leave-3, OT-03.

### Phase 3: pause, resume, rotate, invite, renew, adopt

- [ ] TASK-3a: `pause`, `resume`. AC: MB-10, MB-11, LK-14, CC-02, DP-pause-1, DP-pause-2.
- [ ] TASK-3b: `member invite`. AC: MB-09, DP-invite-1 to DP-invite-3.
- [ ] TASK-3c: `rotate`, ending in `invited` with `prev_status` kept (DEC-30). AC: MB-12, MB-26, DP-rotate-1 to DP-rotate-4, CC-03, OT-14; DP-rotate rows end with a re-join that asserts the record returns to the status rotate started from.
- [ ] TASK-3d: `renew` and expiry warnings. On R7, `state.token = {source, status, expires_on}` in SPEC-010's D5 shape, read from the `.health` cache that join, `status` and the member loop write (SPEC-010 G10; if G10 has not shipped, this task lands the cache writer for R7 only), so MB-19's warning reaches the Share Bar, not only `status` (DEC-39). AC: MB-18, MB-19 (also asserts `state.token.status` is `expiring` with `expires_on`), CK-04; `state` still writes nothing and makes no network call.
- [ ] TASK-3e: `adopt`. AC: MB-17, OC-07.
- [ ] TASK-3f: WebSocket and streaming through the binding (live, Console Labs). Pass: member `add <port>` renders `handle_path /<id>/*` to the port, the Worker forwards an `Upgrade` request for a v:3 `live` pointer and returns the 101 untouched, and `live` joins the v:3 opts; fail: the refusal stays and the result is recorded. AC: LK-02 in the branch taken; the live result in the implementation notes.

### Phase 4: min_cli, Share Bar, docs, live acceptance

- [ ] TASK-4a: `min_cli` enforcement. Every bucket write on a v0.10+ CLI reads the marker once per process; below `min_cli` it refuses writes with `die_code cli_below_min` ("upgrade share to <min_cli>; <host> requires it") and allows reads (DEC-35). AC: OC-04, FG-09; with `SHARE_ERROR_JSON=1` the last stderr line parses as JSON with `code` `cli_below_min`.

TASK-4b, the Share Bar, is twenty-three atomic tasks that build revision 8 (`## UI design`, `docs/design/share-bar-redesign.html`, `docs/design/share-bar-interactions.md`) in SwiftUI. Cites use the audit's form: `MM:` `MenuModel.swift`, `PB:` `Publish.swift`, `MO:` `MutationOutcome.swift`, all under `mac/Sources/ShareBarCore/`. Rule for every one of them: when a new `state` key is present the app uses it; when it is absent (an older CLI) the app falls back to today's derivation (`Health.of` MM:L31-39, `PublishChoice.isEligible` PB:L44-56, the expiry rule MM:L117-128); Swift mirrors display rules only, never classification (audit X5). Swift tests live in `mac/Tests/ShareBarCoreTests`; new fixtures in `mac/Tests/ShareBarCoreTests/Fixtures`. Package platform stays `.macOS(.v13)` (DEC-42). Every command the app runs is spawned with argv only; a token reaches a child through its environment only (Q-SEC-6). Phase 4 needs SPEC-010 G9, G10, G11, G13 and G14 shipped.

Every TASK-4b AC ends with the same two lines, written out in each task: `swift build --package-path mac`, `swift test --package-path mac` and `bash mac/build.sh 0.0.0` pass; and the shipped Share Bar keeps working against the new CLI (`bash mac/compat-check.sh v0.9.0` exits 0, built in TASK-4b1). A UI state named in an AC is verified by a screenshot of that state reached through a real interaction: `mac/shots.sh` (TASK-4b4) launches the built app against a fake CLI scenario and reaches the state with clicks, key presses or drags sent through the Accessibility API; a state set in code is not evidence (DEC-56). Screenshots land in `docs/verification/share-bar/<task>-<state>-<light|dark>.png` and are listed in `docs/verification/multi-member.md`.

- [ ] TASK-4b1: decode the new keys and the compat check. `Snapshot`, `ProfileState` and `Share` gain optional `role`, `tier`, `serve {phase, reason}`, `ops [{verb, step, of, name, alive, rerun, rollback}]`, `token {source, status, expires_on}`, `compat {cli, worker, status, min_cli}`, `member {id, name, mode, status, step, token_expires}`, and per row `link_state`, `reason`, `origin`, `views`; a `MemberList` type decodes `share member ls --json` with `can[]` (TASK-1i); a `Progress` type decodes SPEC-010's `{"progress":{verb, step, of, name}}` stderr line. Uses SPEC-010 G11's types where shipped; owns any key G11 has not landed. `mac/compat-check.sh <tag>` builds the `ShareBarCore` sources of a release tag in a temp package and decodes every new-CLI fixture with them. AC: swift test rows `decode: every new key present` (new fixture `state-full.json`), `decode: every new key absent` (the existing `state.json`, `profiles.json`, `profiles-tenant.json` decode to the same values as today), `decode: an unknown extra key is ignored`, `decode: member ls --json with can[]`, `decode: progress line`; `bash mac/compat-check.sh v0.9.0` decodes every fixture HOME's `profiles --json` and `state` output from the new CLI with no profile mapped to `.error` or to "Update Share Bar" (OC-06, Q-COMPAT-3); `swift build --package-path mac`, `swift test --package-path mac` and `bash mac/build.sh 0.0.0` pass; the shipped Share Bar keeps working against the new CLI.
- [ ] TASK-4b2: derivation in `ShareBarCore`, pure. `ProfileView` computes the serve sentence from `serve.phase` when present (`worker_down` reads `Worker not answering`, `failed` reads `Stopped: <reason copy>`, `elsewhere` reads the hosts line), else `Health.of`; publish eligibility from `role`, `member.status`, `token.status` and `compat.status` with a reason (`migrated` reads `Moved to another machine`, neutral; `paused`, `left`, `removed`, token `expired`/`invalid`, `cli_below_min` are ineligible with their copy), else today's rule; `LinkView` builds the meta line of `### Components & states` (owner in Team, where it lives with the v:3 word `<member>'s machine` (DEC-40), the state word or time left, views on cloud rows); `StorageField.member` renamed `cloudOnly` (source only, no wire key). AC: table-driven swift rows, one per `serve.phase`, one per `role`, one per ineligible reason, one per `link_state` for the meta line, plus the row with no `link_state` or `origin`; `StateMappingTests` and `PublishFormTests` pass unchanged on fixtures without the keys; `swift build --package-path mac`, `swift test --package-path mac` and `bash mac/build.sh 0.0.0` pass; the shipped Share Bar keeps working against the new CLI.
- [ ] TASK-4b3: `PopoverState` (gap G1, DEC-44). One reducer `reduce(state, event) -> (state, [effect])` over the states of `### Components & states` (`firstRun`, `list(scope, query)`, `issues`, `publishing(step, of)`, `dropTarget`, `undo(action, deadline)`, `menu(id)`, `quickLook(id)`); effects are values (`run(argv)`, `copy(url)`, `focus(id)`), never side effects, so a test can assert that an undone Remove never emits `run`. AC: one swift row per row of the transition table, plus `undo deadline emits run once`, `undo or ⌘Z emits no run`, `drop leave returns to the previous state`, `publish failure keeps the sentence and returns to list`, `⌃⌥S from issues lands in list with search focused`, and `the reducer's table equals the spec table` (a row iterates both); `swift build --package-path mac`, `swift test --package-path mac` and `bash mac/build.sh 0.0.0` pass; the shipped Share Bar keeps working against the new CLI.
- [ ] TASK-4b4: screenshot harness and fake CLI. `mac/Tests/fixtures/bin/share` is a fake CLI that answers `profiles --json`, `state`, `member ls --json` and every mutating verb from a scenario directory (`admin` with three tenants and twelve members, `member`, `calm`, `firstrun`, the prototype's four Scenario buttons, plus `cli-old`), prints `SHARE_PROGRESS` lines with a delay for journaled verbs, and appends each argv to `argv.log`; `mac/shots.sh <scenario> <step file>` builds the app, starts it with `SHARE_BIN` pointing at the fake (CLI.swift L27), replays the steps (click a named control, press keys, drag from Finder) through the Accessibility API, and captures the frontmost Share Bar window with `screencapture -l` in light and dark. AC: `bash mac/shots.sh calm open-popover` writes the popover state, verified by a screenshot of that state reached through a real interaction (a click on the status item); negative control: a step naming a missing control fails the run with the control's name and writes no image; a step file that removes a link leaves `rm <id>` in `argv.log`; `swift build --package-path mac`, `swift test --package-path mac` and `bash mac/build.sh 0.0.0` pass; the shipped Share Bar keeps working against the new CLI.
- [ ] TASK-4b5: tokens and state words. `Tokens.swift` with the three tiers of `### Design-system tokens` (dark overrides the semantic tier only); `StateWord` gives an SF Symbol and a word for every `link_state` and every member status. AC: swift rows `every link state has a symbol and a word`, `every member status has a symbol and a word`, `dark overrides only semantic tokens`, `every text token pair meets 4.5:1 and every glyph, chip and focus pair 3:1 in both appearances` (computed from the token values); `swift build --package-path mac`, `swift test --package-path mac` and `bash mac/build.sh 0.0.0` pass; the shipped Share Bar keeps working against the new CLI.
- [ ] TASK-4b6: the popover shell. `StatusItemController` replaces the `NSMenu` with an `NSPopover` holding an `NSHostingController` of `ShareBarView`, driven by `PopoverState`; the header (tenant button and its menu with "Manage tenants…", +, gear), 340 pt wide, the list region scrolling past 360 pt; the status item dot and accessible label; the defaults key `LegacyMenu` (the Advanced checkbox, TASK-4b15) builds today's `MenuModel` for one release (DEC-42). AC: swift rows `the view model lists header, search, scope, list, show all, footer in order` (from `state-full.json`) and `LegacyMenu builds today's MenuModel`; screens `calm popover` and `admin tenant menu open, current tenant checked`, each verified by a screenshot of that state reached through a real interaction; `swift build --package-path mac`, `swift test --package-path mac` and `bash mac/build.sh 0.0.0` pass; the shipped Share Bar keeps working against the new CLI.
- [ ] TASK-4b7: recent list, search, Mine and Team. The most recent live links, newest first, capped by General's count (5, 8, 12; default 8); expired rows never in the menu; Mine the default, Team adds the owner to the meta line, the choice remembered per tenant, the control hidden when every link is the viewer's; search filters name and owner (`No links match "<q>".`); an empty tenant reads `No links yet. Drop a file on the menu bar icon to share it.`; "Show all N links…" opens the All links window (TASK-4b20). AC: swift rows `mine hides others`, `team adds the owner`, `scope remembered per tenant`, `scope hidden when every link is own`, `search matches name and owner`, `cap follows General`, `expired never in the menu`; screens `admin Mine`, `admin Team`, `search with a match`, `search with no match`, `member scenario`, `calm without Mine and Team`, each verified by a screenshot of that state reached through a real interaction; `swift build --package-path mac`, `swift test --package-path mac` and `bash mac/build.sh 0.0.0` pass; the shipped Share Bar keeps working against the new CLI.
- [ ] TASK-4b8: Needs a look. An `Issues` model built from `serve`, `ops`, `token`, `member` and, on the admin's Members data, member records, one line per row of the interactions doc section 4 table in its order, each with exactly one action mapped to its command (Resume: the journal's `rerun`; Start: `share start`; Renew: `share member renew <me>` for an admin, `share api-token` for an owner, "Copy request" for a member; Open: Settings > Members with the member selected; Resume member: `share member resume <name>`; Remove: the remove sheet; Send a new code: `share member invite <name>`; Finish: the stopped verb; Clean up: `share leave --local`); lines grouped by tenant, current first with a `current` tag; the footer reads `All links answer` or `<n> need a look`; the status item dot and label carry the count; an invited member is never a line. AC: swift rows one per section 4 line, `invited is not a line`, `line order`, `current tenant first`, `each action maps to its argv`; with the fake CLI, pressing Resume on the interrupted line leaves the journal's `rerun` argv in `argv.log`; screens `footer all answer`, `footer 4 need a look`, `issues view with three tenants`, `issues view empty: Nothing needs a look.`, `status item with its dot`, each verified by a screenshot of that state reached through a real interaction; `swift build --package-path mac`, `swift test --package-path mac` and `bash mac/build.sh 0.0.0` pass; the shipped Share Bar keeps working against the new CLI.
- [ ] TASK-4b9: link actions and the row menu (gap G9, DEC-52). Click and Return per the `link_state` table of `### Components & states` (flash, the offline and paused warnings, expired and revoked never copy); the row menu shows only the items the table allows, anchored to More, the pointer or the row, opening upward when there is no room below and staying inside the popover, closing on scroll; Remove, Revoke and the Delete key enter `undo` for 6 s (held while Undo has focus; ⌘Z undoes), then run `share rm <id>` once (an admin's rm of another member's v:3 link is a revoke, TASK-2a: "The file stays on <machine>."); Show in Finder reveals the row's `pub/<id>`; Refresh runs `share refresh <id>` only on the install that added the link. AC: table-driven swift rows `row menu items per link_state and role`, `remove waits for the undo window`, `undo cancels the CLI call`, `hold while Undo is focused`, `revoke argv for another member's link`; with the fake CLI, an undone Remove leaves no `rm` in `argv.log` and a completed one leaves exactly one; screens `row menu on an own live link`, `row menu on another member's link as admin`, `undo footer after Remove`, `copy warning on an offline link`, each verified by a screenshot of that state reached through a real interaction; `swift build --package-path mac`, `swift test --package-path mac` and `bash mac/build.sh 0.0.0` pass; the shipped Share Bar keeps working against the new CLI.
- [ ] TASK-4b10: publish and drop in. + opens a file picker; a file dragged from outside onto the status item or the popover enters `dropTarget` with the overlay naming the host and the storage (General's default, `on this Mac` when the tenant has no cloud storage); release or a picked file runs `share add <file>` with `SHARE_PROGRESS=1`, and the placeholder row shows the add journal's step (SPEC-010 G9) with a progress bar; success copies the link and flashes the new row; failure shows the CLI sentence and `next`. AC: swift rows `progress lines move publishing(step, of)`, `a drop with no tenant is refused with the first-run panel`; with the fake CLI, a drop leaves `add <path>` in `argv.log`; screens `drop overlay during a drag from Finder`, `uploading row at step 2`, `new row flashed after publish`, each verified by a screenshot of that state reached through a real interaction; `swift build --package-path mac`, `swift test --package-path mac` and `bash mac/build.sh 0.0.0` pass; the shipped Share Bar keeps working against the new CLI.
- [ ] TASK-4b11: drag a row out. A `live`, `offline` or `paused` row drags as an `NSItemProvider` carrying the link URL as a URL and as plain text; the footer reads `Drop to paste the link to <name>` during the drag; `expired` and `revoked` rows do not drag; an internal drag never enters `dropTarget`. AC: swift rows `the drag item carries the URL as url and text`, `expired and revoked do not drag`, `an internal drag never enters dropTarget`; screens `footer hint during a drag out` and `the URL pasted in TextEdit after the drop`, each verified by a screenshot of that state reached through a real interaction (a harness drag); `swift build --package-path mac`, `swift test --package-path mac` and `bash mac/build.sh 0.0.0` pass; the shipped Share Bar keeps working against the new CLI.
- [ ] TASK-4b12: Quick Look. Space on a focused row opens a non-activating panel (up to 560 pt): Close, the name, Open in browser, Copy link (default button), a preview, the URL in SF Mono and the meta line; a row whose bytes are on this Mac previews `pub/<id>` through `QLPreviewView`; a port share shows `Live server` and what answers on its port; any other row (cloud, another member's machine) shows its glyph and meta with no network fetch (DEC-55); Space or Esc closes and returns focus to the row; Copy link closes and copies. AC: swift rows `preview source per row kind` and `close returns focus to the row id`; screens `Quick Look on a local PDF`, `on a folder`, `on a port share`, `on a cloud link`, each verified by a screenshot of that state reached through a real interaction (Space on a focused row); `swift build --package-path mac`, `swift test --package-path mac` and `bash mac/build.sh 0.0.0` pass; the shipped Share Bar keeps working against the new CLI.
- [ ] TASK-4b13: the global hotkey Control-Option-S. Registered with Carbon `RegisterEventHotKey` (no Accessibility permission); it opens the popover from any app in `list` with the search focused, from `issues` too, closing any open menu; a failed registration shows `Control-Option-S is in use by another app` under General's Shortcut and nothing else changes. AC: swift row `the hotkey event from issues lands in list with search focused` (reducer); negative control: a second registration of the same key reports in use; screen `popover opened by ⌃⌥S while Finder is frontmost, search focused`, verified by a screenshot of that state reached through a real interaction (the key pressed through the harness); `swift build --package-path mac`, `swift test --package-path mac` and `bash mac/build.sh 0.0.0` pass; the shipped Share Bar keeps working against the new CLI.
- [ ] TASK-4b14: the Settings window and General. One 620 pt window with icon tabs General, Tenants, Members (shown when any profile is a T2 tenant whose `role` is not `member`; `member ls` itself proves the admin token, and its refusal shows as a sentence in the tab), Advanced; arrows move tabs; the gear opens General, "Manage tenants…" opens Tenants with the current tenant selected. General: Open at login (`SMAppService`), Menu shows (Mine or Team), Recent links (5, 8, 12), After sharing (copy, notify), Notify me when (a machine serving my links goes offline, a link is about to expire, a member needs a look for admins), the shortcut; New links expire and Store new links write the CLI config through `share config ttl <v>` and `share config storage_default <v>` (SPEC-010 G14, DEC-57), Store new links shown only on tenants with cloud storage. AC: swift rows `Members tab hidden for a non-admin`, `General's expiry writes argv share config ttl 7d`; with the fake CLI, changing the expiry leaves that argv in `argv.log`; screens `General tab`, `Settings for a member without the Members tab`, each verified by a screenshot of that state reached through a real interaction; `swift build --package-path mac`, `swift test --package-path mac` and `bash mac/build.sh 0.0.0` pass; the shipped Share Bar keeps working against the new CLI.
- [ ] TASK-4b15: Advanced and the admin key (gap G3, DEC-46). CLI path (default from `CLI.locate`, shown with `share version`); Admin key source: From 1Password (an item picker; shows the item's name and vault, never its path or value; writes `share admin-token --cmd 'op read op://<vault>/<item>/credential'`), From a command (a text field; `share admin-token --cmd '<command>'`), Ask me each time (`share admin-token --clear`); Test runs `share admin-token --test --json` and shows what the token can do (tunnels, DNS, Workers, R2, Connectivity Directory), never the token; Show serve log in Finder; Use the classic menu (one release only), the `LegacyMenu` key; Copy share state as JSON. AC: swift rows `each source writes its argv`, `Test shows capabilities and never a token-shaped string`; with the fake CLI, each source change leaves its argv in `argv.log`; screens `Advanced with a 1Password item picked`, `with a command`, `with Ask me each time`, `Test passed`, `Test failed with the CLI sentence`, each verified by a screenshot of that state reached through a real interaction; `swift build --package-path mac`, `swift test --package-path mac` and `bash mac/build.sh 0.0.0` pass; the shipped Share Bar keeps working against the new CLI.
- [ ] TASK-4b16: dialogs (interactions doc 3b). One `ImpactSheet` (title, optional body, lines with a cross for what stops and a check for what keeps working, Cancel and one action button, destructive in red ink) whose counts come from `share state` rows, never from fixed copy: Stop serving counts this Mac's links against cloud and member links; Pause counts the member's machine links; Remove member offers keep or delete for cloud links; Roll back names its command. Also the code sheet (the code once, Copy code, Done, "Share Bar shows the code only now."), the invite sheet (name, where links live with one-line consequences, code expiry 1, 7 or 30 days), the refusal sheet (the CLI sentence and its next action as a button), and the ask-for-admin-key sheet: a secure field whose value is passed to that one command as `CLOUDFLARE_API_TOKEN` in its environment and dropped when the command exits. Esc closes every sheet but progress. AC: swift rows `stop serving counts from rows`, `pause counts the member's machine links`, `the asked key reaches the child environment only` (argv and the app's defaults hold no token), `Esc never closes progress`; screens `Stop serving confirm with counts`, `Pause confirm`, `Remove member with the cloud-links choice`, `invite sheet`, `code sheet`, `ask for the admin key`, each verified by a screenshot of that state reached through a real interaction; `swift build --package-path mac`, `swift test --package-path mac` and `bash mac/build.sh 0.0.0` pass; the shipped Share Bar keeps working against the new CLI.
- [ ] TASK-4b17: Tenants, list and detail. The source list (host, `<role> · <status word>`, a needs-a-look dot, + and - below) and the detail of `### Components & states`; Start serving (`share start`) and Stop serving (`share stop` after the impact sheet) shown per the interactions doc section 5 table; - opens the remove sheet per role: owner `share teardown --yes`, member `share leave`, removed member `share leave --local`, and an admin of a T2 tenant gets the refusal sheet "Remove every member first" with Open Members, which is also what the CLI's `members_present` code maps to if teardown runs anyway (gap G6, DEC-49); a member whose `member.status` is `removed` or whose `token.status` is `invalid` sees "You were removed from <host>" with Clean up (gap G4, DEC-47). AC: swift rows `buttons per role, tier and phase` (table-driven from section 5), `members_present maps to the refusal sheet`, `removed member shows Clean up`; with the fake CLI, Clean up leaves `leave --local` in `argv.log`; screens `admin tenant serving`, `owner tenant stopped with its reason`, `starting`, `refused removal of a T2 tenant`, `owner removal sheet`, `member: You were removed`, each verified by a screenshot of that state reached through a real interaction; `swift build --package-path mac`, `swift test --package-path mac` and `bash mac/build.sh 0.0.0` pass; the shipped Share Bar keeps working against the new CLI.
- [ ] TASK-4b18: Tenants, journaled flows (gaps G2, G5, G7, DEC-45, DEC-48, DEC-50). Add (+ in Tenants, and the first-run panel) opens the add sheet: Join a team runs `share join <host> <code>`, Set up a hostname runs `share setup <host>` (with Also turn on cloud storage, `share setup <host> --r2 --bucket share-<host>` after it); Turn on cloud storage (owner or admin, T0) and Turn on members (admin, T1) run the `setup-r2` and `setup-members` verbs; every one runs with `SHARE_PROGRESS=1` and shows the progress sheet from the journal's `step`, `of` and `name`; Stop sends SIGTERM, the journal keeps the step, and the tenant shows the interrupted callout; Resume runs the journal's `rerun` (bare `share join` for a join), Roll back its `rollback`. Step names shown are the journal's, through a copy table for known names that falls back to the raw name. AC: swift rows `progress sheet follows progress lines`, `Stop sends SIGTERM and leaves the callout`, `Resume runs rerun`, `Roll back runs rollback`, `the tier buttons are admin only`; with the fake CLI, a join stopped at step 4 then resumed leaves `join <host> <code>` then `join` in `argv.log`; screens `add sheet, join`, `add sheet, set up`, `progress at step 4 of 6`, `interrupted callout`, `cloud storage progress`, `members progress`, each verified by a screenshot of that state reached through a real interaction; `swift build --package-path mac`, `swift test --package-path mac` and `bash mac/build.sh 0.0.0` pass; the shipped Share Bar keeps working against the new CLI.
- [ ] TASK-4b19: Members (gap G10, DEC-53). Reads `share member ls --json` when the tab opens and after each member action, never on the 60 s poll (DEC-54); filters All, Needs a look and Removed with counts, and a search; the row of `### Components & states`; the row menu lists exactly the verbs in the member's `can[]` (Finish, Resume, Pause…, Send a new code, Rotate keys…, Renew key…, then Remove… or Delete record), mapped to `share member resume|pause|invite|rotate|renew|rm|purge <name>` through the existing `MutationQueue`, with the sheets of TASK-4b16 for pause, rotate, renew, remove and the code; Invite… opens the invite sheet and runs `share member add <name> --machine|--cloud --invite-ttl <n>d`; a running verb shows its step from the record, a stale lease Finish. A `member ls` failure shows its sentence in place of the list. AC: swift rows `row menu equals can[]` (every stored status), `each verb maps to its argv`, `filters count`, `member ls failure shows the sentence`; with the fake CLI, Pause then Resume leaves both argvs in `argv.log`; screens `Members all, 12 people`, `Needs a look filter`, `Removed filter`, `row menu of an active member`, `row menu of a stale pausing member`, `invite sheet then its code`, each verified by a screenshot of that state reached through a real interaction; `swift build --package-path mac`, `swift test --package-path mac` and `bash mac/build.sh 0.0.0` pass; the shipped Share Bar keeps working against the new CLI.
- [ ] TASK-4b20: the All links window (interactions doc 3a). Every link of the current tenant, expired included: tabs All, Live, Needs a look, Expired with counts; search over name, owner and machine, focused on open; columns Name (created time and state word), Owner, Lives on, Expires, Views (cloud rows only, blank otherwise), Copy; select with checkboxes and select all; the bar `<n> selected` with Copy links (one URL per line) and Remove (through `undo`, `share rm <id>...`, another member's link revoked); expired rows dimmed with Copy disabled. AC: swift rows `tab counts`, `views only on cloud rows`, `bulk copy joins URLs one per line`, `bulk remove argv revokes others' links`; with the fake CLI, a bulk Remove leaves one `rm` argv with every id; screens `All tab`, `Needs a look tab`, `Expired tab`, `three selected with the bar`, `search with no match`, each verified by a screenshot of that state reached through a real interaction; `swift build --package-path mac`, `swift test --package-path mac` and `bash mac/build.sh 0.0.0` pass; the shipped Share Bar keeps working against the new CLI.
- [ ] TASK-4b21: app states and first run (gap G8, DEC-51; interactions doc section 1). Loading (no `profiles` result yet), CLI missing (spawn fails: "Install the share command" with Copy install command), CLI too old (`compat.status` `cli_below_min` or an old help banner: "Update share to 0.10" with Copy upgrade command), No tenant (the first-run panel with Join a team with a code… and Set up my own hostname…, each opening the add sheet of TASK-4b18), Ready. AC: swift rows one per app state from its fixture; screens `loading`, `CLI missing`, `CLI too old`, `first run`, `join sheet opened from first run`, each verified by a screenshot of that state reached through a real interaction (the fake CLI's `firstrun` and `cli-old` scenarios, a missing `SHARE_BIN` path); `swift build --package-path mac`, `swift test --package-path mac` and `bash mac/build.sh 0.0.0` pass; the shipped Share Bar keeps working against the new CLI.
- [ ] TASK-4b22: keyboard path and VoiceOver (`### Accessibility targets`). Every key of that section in the popover, the row menu, Quick Look, Settings, the sheets and the All links window; focus restored by row id after every refresh; row labels are the name plus the meta line and expose actions; the status item label carries the count; the toast is a live region; Reduce Motion fades the drop overlay. AC: swift rows for the label builder (one per `link_state`), `focus restores by id after a refresh that reorders rows`, `status item label carries the count`; screens `focus ring on the third row after Arrow Down twice`, `row menu opened by Shift-F10`, each verified by a screenshot of that state reached through a real interaction; a VoiceOver and keyboard checklist run by hand and recorded in `docs/verification/multi-member.md`; `swift build --package-path mac`, `swift test --package-path mac` and `bash mac/build.sh 0.0.0` pass; the shipped Share Bar keeps working against the new CLI.
- [ ] TASK-4b23: errors and running ops. Mutations run with `SHARE_ERROR_JSON=1`; `MutationOutcome` reads the trailing JSON line (`{"error":{code, message, next}}`) and shows the sentence with `next` as a copyable line, else today's last `share: ` line (MO:L87-92); a progress line from another process's alive op shows `Working: <verb> (<step>/<of>)` in the footer; the Stop Waiting copy reads `The add stops where it is; share prune cleans up what it left.` (SPEC-010 G9). AC: `MutationOutcome` swift rows with and without the JSON line, and one per SPEC-009 code the app maps to a sheet (`members_present`, `member_busy`, `cli_below_min`, the join table); screens `publish failure with its next step`, `Working line for an add from the terminal`, each verified by a screenshot of that state reached through a real interaction; `swift build --package-path mac`, `swift test --package-path mac` and `bash mac/build.sh 0.0.0` pass; the shipped Share Bar keeps working against the new CLI.
- [ ] TASK-4c: docs. README, `docs/how-it-works.md`, `docs/setup.md` (member onboarding: one pasted line), `docs/SYSTEM-DESIGN.md` rev C as built (the delta table in `## Design`), ADR-0009 accepted, glossary `CONTEXT.md`, `docs/QUALITY.md` with the Q- entries. AC: the existing docs grep (`tests/share.sh` "tenant docs" section) extended to every member verb, flag and config key named here.
- [ ] TASK-4d: `tests/e2e-members.sh`, the live legs in `## Verification`, refusing any hostname, bucket, tunnel, service or token name without the `share-e2e-` prefix, with an EXIT trap that deletes by name and prints each leftover. AC: ML-1 to ML-12 green twice in a row.
- [ ] TASK-4e: STOP for Han, then the live acceptance on `s.console.so` with the owner's second machine as the first member (DEC-3), and `docs/verification/multi-member.md` with each negative control's red and green run. AC: every `## After state` item checked.

Task count: Phase 0: 6; Phase 1: 9; Phase 2: 5; Phase 3: 6; Phase 4: 27 (TASK-4a, TASK-4b1 to TASK-4b23, TASK-4c, TASK-4d, TASK-4e); 53 in all.

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
- Q-COMPAT-3 (new): the shipped Share Bar renders every profile the new CLI reports; `state` stays schema 1 with no new `state.state` value. Tested by: TASK-4b1 `mac/compat-check.sh`, OC-06, OC-08.
- Q-REL-4 (new): a member record only moves along a row of the transition table. Tested by: TASK-1e `member_can` iteration, MB-24, MB-25.
- Q-COST-1 (new): one bucket read per visitor request for a v:3 link and no new read for v:1 or v:2. Tested by: SV-24.
- Q-SCALE-1 (new): 20 machine members per tenant deploy and route. Tested by: TASK-1a(e), DY-04.
- Q-OPS-1 (new): a revoked link 404s at once and loses its Caddy handle within one hourly loop. Tested by: LK-11, ML-10.

## Acceptance Criteria

- [ ] All 53 tasks pass their individual acceptance criteria.
- [ ] SPEC-010 G1 to G5 shipped before the first Phase 1 task merged.
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
| TN-07 | `teardown` on a T2 origin with records; `migrate` | refused before any change; teardown's code is `members_present` (gap G6) |
| TN-08 | `setup --r2` rerun and `--alias` on T2 | bindings and `PAUSED` carried (DY-01) |
| TN-09 | die after the deploy, after the marker, before config | rerun converges; a dead same-host lease is taken over at once; die between marker and config: refusals still hold (teardown, migrate and `--no-r2` refuse, reading the marker) |
| TN-10 | a T2 origin config with `members=on` (and a member config with `role=member`, `member_id`, `member_mode`): `setup <host>` rerun, `api-token --cmd` | every one of those lines survives byte for byte (TASK-0f) |
| TN-11 | marker `members:true`, config without `members=on` (an older CLI's rerun dropped it) | `state.tier` `t2`, `state.tier_drift` true; `status` prints the `config_drift` repair line; teardown still refused |

### Member (brief member table)

| # | Scenario | Expected |
|---|---|---|
| MB-01 | `member add an --machine` | DP-add steps in order; record `invited` with `tunnel_id`, `vpc_service_id`, `token.id`, `invite.hash`; one invite line |
| MB-02 | `member add bo --cloud` | no tunnel, service or deploy calls; record `invited` mode cloud |
| MB-03 | name `A_n`, a 25-char name, a name held by an active record | refused before any write; an `adding` or `invited` record of the same name resumes with its member_id |
| MB-04 | `SHARE_MINTER_TOKEN` unset; minter lacking API Tokens Write; admin lacking Connectivity Directory Admin | refused before the lease |
| MB-05 | 21st machine member | refused naming the cap |
| MB-06 | `join s.console.so <code>` | DP-join steps; record `active` with `joined`; config `role=member` |
| MB-07 | join refusals: CLI below `min_cli`; redeem 404; redeem 410; redeem 503; record not `invited` or member_id differs; port busy; profile not R0 and not R7 of the same host; `mac` mismatch | each dies with its code (`cli_below_min`, `invite_unknown_or_used`, `invite_expired`, `invite_unavailable`, `member_changed`, `port_busy`, `profile_not_empty`, `invite_tampered`), asserted from the `SHARE_ERROR_JSON=1` line; nothing local remains except after a 200 redeem with a later refusal, which removes its own config and tokens |
| MB-08 | INVITED past `invite.expires` | `member ls` shows EXPIRED; `member sync` deletes the `i/` object |
| MB-09 | `member invite an` from INVITED and from EXPIRED, with `--port 8801` | old token deleted, connections deleted, new token, service port updated, old `i/` deleted, new `i/`, new code |
| MB-10 | `member pause an` | record `paused`; `PAUSED` holds an; v:3 503; an's cloud links 200; an's CLI refuses `add` |
| MB-11 | `member resume an` | record `active`; `PAUSED` without an; v:3 200 |
| MB-12 | `member rotate an` from ACTIVE and from PAUSED | new tunnel and service `-r1`; binding `M_<8hex>` names the new service; old ones deleted; record `invited` with `prev_status` `active` or `paused`; after the re-join the record is back to that status, so a PAUSED member stays paused |
| MB-13 | `member rm` from INVITED, EXPIRED, ACTIVE, PAUSED, LEFT, and from each `...ing` | REMOVED; v:3 pointers tombstoned; cloud links kept (or deleted with `--cloud-links delete`); no object left |
| MB-14 | `leave` on ACTIVE | own links rm'd (pointer, then bytes); service uninstalled; record `left` (If-Match); tokens forgotten; config dropped |
| MB-15 | `leave --local` | `r2-calls.log` has no line; service gone; tokens forgotten; rows and `pub/` moved to trash |
| MB-16 | `member purge` on REMOVED; on ACTIVE | record deleted and id in `u/purged.json`; refused |
| MB-17 | `adopt bo --token-id <id>`: own user's bucket-scoped token; another user's token; an account-wide token | ACTIVE cloud; refused; refused |
| MB-18 | `renew an --token-ttl 90d` | `PUT /user/tokens/<id>` with the same policies; token id unchanged; the member keeps working |
| MB-19 | token expiry 14 days away | `status` on the member and `member ls` warn; on R7 `state.token.status` is `expiring` with `expires_on` (DEC-39) |
| MB-20 | two connectors on a member tunnel | `member ls` flags "extra connector: rotate now" |
| MB-21 | member removed while asleep, then `status` | verify 401 or record `removed`: "this machine was removed from <host>; share leave --local" |
| MB-22 | record `active` while `PAUSED` holds the id; record `removed` while bound | `member ls` prints two drift lines, writes nothing |
| MB-23 | `member sync` on MB-22's state | record becomes `paused`; the removed-but-bound case is reported, not changed |
| MB-24 | record in `pausing` (step 2); admin runs `member rotate an`, then `member rm an`, then `member sync` | rotate refused `member_busy` naming `pause` and step 2 with `share member pause an`; rm proceeds; sync reports and writes no refusal |
| MB-25 | `member pause an` dies after `pausing`; the record is then rerun by `member pause an` twice | `prev_status` stays `active` across both reruns (never rewritten); cleared when `paused` lands |
| MB-26 | PAUSED member: `rotate`, then `member invite an` (a lost code), then `renew an`, then join with the newest code | record `invited` with `prev_status` `paused` after each admin verb (DEC-41); join ends `paused`; `prev_status` and `invite` dropped |
| MB-27 | join on an R7 profile: bundle `member_id` equals config; bundle names another member_id | tokens replaced in place, record restored; refused `member_changed` before any local write |
| MB-28 | admin verb killed at step 3 on another host | `member ls` prints the record's `step 3 of <m> (<step_name>)`, the lease holder, `(live)` while the holder runs, then `(stale since <time>; rerun: share member <verb> <name>)` |
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

RC-01 to RC-13 are rows 1 to 13 of the reconcile table, one test each, run on a member HOME with fixtures aged by the suite's `aged` helper. RC-14: on the origin, a v:3 pointer of any age, with or without a local row of the same id, is never deleted (the origin's reap list stays v:2).

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
| CC-04 | join while `member rm` runs | rm wins from any state; the member's probe fails; `status` reports removed |
| CC-05 | two machines add the same id | If-None-Match: one gets 412 and a new id |
| CC-06 | admin revoke racing the owner's reconcile | reconcile row 9 skips the young tombstone; no resurrection |
| CC-07 | owner `rm` racing admin revoke | the leftover tombstone is deleted by row 5 |
| CC-08 | the member loop racing the member's own add | add lock and the 10-minute rule keep the pointer |
| CC-09 | lease holder killed on another host | takeover after `LastModified` + 900 s; before it, `member ls` names the holder's verb, member and step from the lease body (DEC-36) |
| CC-10 | two takers of one stale lease | If-Match: one wins |
| CC-11 | two redeems of one code at once (`worker.mjs`, interleaved `get`) | exactly one 200 |
| CC-12 | admin verbs for two different members, sequential | independent; both bindings |
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
| SV-21 | v:3 with `cf-access-jwt-assertion`, `cf-access-authenticated-user-email`, cookie `a=1; CF_Authorization=x` | binding sees none of the three, sees `a=1` |
| SV-22 | binding answer without `X-Share-Served`; binding throws | 503 offline page each |
| SV-23 | binding answers `text/html`; `application/pdf` | CSP sandbox on the first only; `X-Share-Served` removed |
| SV-24 | count `BUCKET.get` per request for v:1, v:2, v:3 | 2, 1, 1 (unchanged for v:1 and v:2) |
| SV-25 | `state` on a member HOME with a revoked row and, with the member paused, a live v:3 row | `link_state` `revoked` with `reason` `revoked_by=<by>`; `paused`; every old row field equal to the pre-change output |
| SV-26 (worker.mjs) | every request of every existing and new row | `decide()` returns the named row id; every 404 carries the one body `no such link (it may have expired or been removed)`; no response header names the row |

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
- DEC-47 (gap G4): a member whose own record is `removed`, or whose publisher token answers 401, gets a display state "You were removed from <host>" with Clean up (`share leave --local`); `state.member.status` carries it from the `.health` cache, so `state` stays network free (TASK-2e, TASK-4b17). Rejected: showing a generic error (the member could not tell removal from an outage).
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

Audit A13 (R7 config stores the bucket as `member_bucket=`) is ranked later and is not folded here; TASK-1g keeps `bucket=` as `### The 28 r2on sites` says.

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
| OQ-8 | The Share Bar's Invite, Send a new code, Rotate keys and Renew also need the minter token, which ADR-0009 keeps in `SHARE_MINTER_TOKEN` only; gap G3 decided the admin token alone. Proposed: a `minter_token_cmd` key on DEC-46's rule; until decided, the Share Bar asks for the minter token per action and never stores it | owner decision, before TASK-4b19 |

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
