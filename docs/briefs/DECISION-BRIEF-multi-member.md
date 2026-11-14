# Decision brief: many members, one tenant hostname

Status: DRAFT r2 for owner review. Nothing is built. Grounded in `bin/share` at 4564c5c (v0.9.0 line). Companions: `docs/research/2026-11-13-current-state-machines.md` (the state map with line cites) and `docs/research/2026-11-13-multi-member-review-1.md` (33 findings; this revision answers every blocker and major, see the last section).

## Problem

A tenant is one hostname (`s.console.so`) with one origin machine. Teammates can publish only cloud links (R2), and only after the admin hand-makes a Cloudflare token for each in the dashboard. The owner wants:

| Want | Today |
|---|---|
| A teammate shares a file that stays on THEIR machine, under the same hostname | Impossible: one tunnel, one connector, one ingress rule; the Worker's pass-through is a plain `fetch(request)` to that one origin |
| No new subdomain per member | `--host` and a second tunnel both need a new hostname |
| The member never opens the Cloudflare dashboard | Every publisher needs a hand-made bucket-scoped token |
| Add, change, and remove a member and every link they own, with no half states | No member registry; admin vs member is not persisted; `by` is an unauthenticated `uname -n` |

## Verified current state (the parts this design changes)

1. One origin is baked in: one tunnel, ingress rule 0 to `127.0.0.1:<port>`, one connector token in one Keychain; `hosts=` is an allow-list, not a lease (L83, L4508).
2. The tenant Worker passes a v:2 machine pointer with a plain `fetch(request)` and never reads `by`, `expires`, or `own_host` (L2646, L2707).
3. The origin's reconcile deletes any valid **v:2** pointer with no local row after 10 minutes (L2971-2981). A v:3 pointer is not reaped even by v0.9 CLIs (`r2_take` keeps only `v == 2`, L3265).
4. `by` is the short `uname -n`, unauthenticated and forgeable. Today's rules: storage kind, the local `r2-own` file, and "any publisher may rm any cloud share" (L2828, L3347).
5. Joining writes nothing on Cloudflare; the admin token is env-only; only the origin profile redeploys the Worker; every deploy replaces the whole binding list (`keep_bindings` keeps only `secret_text`, L3766).
6. Caddy serves the whole `pub/` tree, listed or not (L1127-1132).
7. A record of an unknown version blocks the orphan sweep of every CLI that cannot read it (L3283-3295); `WORKER_RECORD_V` is dead code.
8. The hourly prune runs with `SHARE_API_TOKEN_OFF=1`, so no bucket reconcile ever runs unattended (L1181, L1206).

## Solution

```
 visitor ── https://s.console.so/<id>/<file>
              │
              ▼
 Worker share-s-console-so  (route s.console.so/*, version 5)
   GET m/<id>
     v:1 cloud record ─────────────────────────────────────────► R2 bytes
     v:2 pointer (the origin's links) ── pass() ──► tunnel CNAME ─► origin caddy           (unchanged)
     v:3 pointer {origin:"m-an-3f9a1c2d"}
        id in PAUSED ──────────────────────────────► 503 "paused by the tenant admin"
        binding M_3f9a1c2d present ── rewrite to http://<HOST><path>, strip Access headers
                                   ── env.M_3f9a1c2d.fetch() ─► VPC Service ─► An's tunnel ─► An's cloudflared ─► An's caddy 127.0.0.1
        no binding ─────────────────────────────────► 404
     any pointer past expires ──────────────────────► 404   (new)
   POST /_share/redeem  (one-time invite code, new) ─► returns the sealed invite, then deletes it

 bucket
   share.json              marker: gains "members": true, "min_cli": "0.10.0"
   u/<member_id>.json      member record (new)
   i/<sha256(code)>        sealed invite, one read, then deleted (new)
   lock/admin              admin lease (new)
   m/<id>                  v:1 cloud | v:2 origin pointer | v:3 member pointer (new)
   t/<id>                  tombstone of a link removed by someone else (new)
   o/<id>.<nonce>/...      cloud bytes (unchanged)

 Cloudflare, per machine member
   tunnel share-<host>-<8hex>  (no public hostname, no ingress)  ◄── connector token on the member's machine
   VPC Service share-<host>-<8hex> = tunnel + ipv4 127.0.0.1 + http_port <port>
   Worker binding M_<8hex> = that VPC Service
   publisher token "share <host> <member_id>" (bucket item write + zone read, expiry)
```

### Mechanisms

1. **Member registry in the bucket.** `u/<member_id>.json`: name, mode (`machine` or `cloud`), status, tunnel id, VPC Service id, token ids and expiry (never secrets), port, timestamps. `member_id` = `m-<name>-<8 hex>`, checked unique against every record, purged id, and live binding. `by` stays as display only.
2. **The deploy is authoritative; the registry is a journal.** Routing lives in the Worker deploy: one VPC binding per machine member and a `PAUSED` var. Every deploy body (member verbs, `setup --r2` reruns, alias steps, version bumps) is built from the registry plus the marker, so no path can drop a binding. The deploy compare gains the binding set and `PAUSED`. Members can write `u/` records (the bucket token cannot stop them), so admin-set status flows only deploy-to-record: `member ls` reports drift, `member sync` repairs it.
3. **Admin verbs run from any machine.** They need the admin token and the tenant host; everything else comes from the marker and registry. Losing the origin machine no longer locks the admin out.
4. **Admin lease.** Every admin verb takes `lock/admin` (`If-None-Match: *`, holder and expiry inside; a stale lease past expiry is taken over with `If-Match`). Two shells can no longer lose a binding.
5. **One write order for every status change:** record intent (`status=<verb>ing`, If-Match) → Cloudflare change → record final. A die leaves an `...ing` status that the rerun resumes.
6. **Pointer v:3** `{v:3,id,storage:"machine",origin,name,by,added,expires,opts,type}`. The origin keeps writing v:2, so a v4 Worker and old CLIs keep working for its links.
7. **Caddy serves listed rows only.** One `handle /<id>/*` per live, non-revoked row instead of the whole `pub/` tree, on the origin and on members. Unlisted bytes are unreachable, and a forged pointer cannot re-serve a revoked row.
8. **Tombstones never delete bytes.** When someone other than the owner removes a link, they write `t/<id>` and delete the pointer. The owner's reconcile marks its row `revoked` (Caddy stops serving it, `ls` shows "removed by <who>"), then deletes the tombstone. Bytes go only on the owner's own `rm` or the row's expiry. A forged tombstone can pause a link, never destroy it, and the owner sees it.
9. **Member reconcile runs unattended.** On a member machine the hourly loop runs prune and reconcile with the Keychain publisher token, own origin only. The origin keeps today's behavior.
10. **Credentials minted by the tool, invites redeemed once.** `member add` mints with a separate minter token, seals the member's two tokens into `i/<sha256(code)>` (encrypted with a key derived from the code), and prints a short code. `join <code>` redeems it through the Worker, which checks the expiry by server time, returns the sealed bytes, and deletes the object. A code pasted in chat is useless after the join or the expiry.
11. **Worker v5 duties.** Enforce `expires` on every pointer; count hits for v:3 links (the origin keeps its Caddy log); strip `cf-access-jwt-assertion` and Access cookies before a binding fetch; serve `/_share/redeem`; offline page stays generic (no member name).

## State machines

### Tenant

```
 [T0 tunnel, R2 off] ─setup --r2─► [T1 R2 on] ─setup --r2 --members─► [T2 members on]
        ▲                │  ▲              │                              │
        └────--no-r2─────┘  └─--no-members─┘ (refused while any member    │
                                             record is not REMOVED)       │
 T2 ─teardown─► refused while member records exist ("member rm each, then teardown")
 T2 ─migrate─► refused (R3 is refused today)
 T2 ─setup --r2 rerun, --alias, CLI upgrade─► T2 (deploy body rebuilt from the registry)
 T2 ─setup --force with an older CLI─► refused while members exist (a downgrade would drop every binding)
```

| From | Event | Guard | To | Writes, in order |
|---|---|---|---|---|
| T1 | `setup <h> --r2 --bucket B --members` | admin token with every scope in Credentials, probed before any write; Workers VPC answers on the account; every local row has a pointer; marker names host; the owner confirms that every publisher runs `min_cli` or newer | T2 | lease · Worker v5 (PASS, PAUSED=`[]`, no bindings) and healthz pair · marker `members:true`, `min_cli` (If-Match) · config `members=on` · lease released |
| T2 | same command | none | T2 | converges; each step skipped when in place |
| T2 | `setup <h> --no-members` | every record REMOVED or purged | T1 | marker keys dropped; Worker redeployed without PAUSED; config key dropped |
| T2 | `setup <h> --no-r2` | refused: "--no-members first" | T2 | none |

### Member

```
                 member add                       join <code>
   (none) ─────────────────► [INVITED] ───────────────────────► [ACTIVE] ◄──resume── [PAUSED]
                               │  ▲                                │  │ └──pause──────►  │
            invite expires ──► │  │ member invite (new code,       │  │                  │
            (Worker clock)     ▼  │  old tokens deleted)           │  └─rotate─► [ACTIVE] (same id, links, files;
                           [EXPIRED]                               │            connectors dropped; join with new code)
                                                                   │
                         member rm (from any state below) ◄────────┤
   [INVITED] [EXPIRED] [ACTIVE] [PAUSED] [LEFT] ──► [REMOVING] ──► [REMOVED] ──member purge──► (none)
                                                                   │
   [ACTIVE] ──leave──► [LEFT]  (own links and local service gone; cloud side waits for member rm)
   any local profile ──leave --local──► no local member config (no bucket calls; for a removed or offline member)

   adopt: an existing cloud-only publisher (R5 today) ──member adopt <name> --token-id──► [ACTIVE, mode=cloud]

   runtime only, never stored: ONLINE / OFFLINE (the member's own `status`, and `member ls` probing a test link)
```

| From | Event | Actor | Guard | To | Writes, in order (a rerun resumes from the record's `...ing` status) |
|---|---|---|---|---|---|
| none | `member add <name> [--machine\|--cloud] [--invite-ttl 7d] [--token-ttl 90d]` | admin | T2; lease; scopes probed; name `[a-z0-9-]{2,24}` not used by a non-REMOVED record (an INVITED record of the same name resumes instead) | INVITED | 1 `u/<id>` status=adding (If-None-Match) · 2 publisher token named `share <host> <member_id>` (found by name on rerun; if its secret was never sealed, delete and re-mint) · 3 machine: tunnel created (no ingress), connector token fetched · 4 machine: VPC Service created · 5 machine: Worker redeployed from the registry with `M_<8hex>` · 6 sealed invite `i/<sha256(code)>` with server-side expiry · 7 record status=invited · 8 code printed once |
| INVITED | `join <code>` | member | CLI >= `min_cli`; redeem answers 200; record says invited and matches; port free | ACTIVE | 1 redeem (Worker deletes `i/`) · 2 record status=joining (If-Match; a concurrent admin verb makes this fail before anything local exists) · 3 local config `role=member`, `member_id`, `mode` · 4 tokens into Keychain · 5 machine: Caddy and cloudflared service started · 6 probe link added and fetched through the Worker 3x200, then removed · 7 record status=active, `joined` |
| INVITED | invite expiry passes | Worker clock | not redeemed | EXPIRED | none; the next admin verb that reads the record shows it |
| INVITED, EXPIRED | `member invite <name>` | admin | lease | INVITED | old publisher token deleted, tunnel connections deleted, new token, new sealed invite, new code |
| ACTIVE | `member pause <name>` | admin | lease | PAUSED | record status=pausing · redeploy with id in PAUSED (machine links 503) · record status=paused. Cloud links keep serving; the member's CLI refuses new adds while the record says paused |
| PAUSED | `member resume <name>` | admin | lease | ACTIVE | record status=resuming · redeploy without the id in PAUSED · record status=active |
| ACTIVE, PAUSED | `member rotate <name>` | admin | lease | same | record status=rotating · new publisher token · tunnel connections deleted (a leaked connector drops) · tunnel token rotated · old publisher token deleted · sealed invite and code · record back to its status. Links stay pointed at the same id; the member's machine is offline until it runs `join <code>` |
| any but REMOVED | `member rm <name> [--cloud-links keep\|delete]` | admin | lease | REMOVED | 1 record status=removing · 2 redeploy without `M_<8hex>` and without the id in PAUSED (machine links 404 at once) · 3 delete the VPC Service · 4 delete tunnel connections, then the tunnel · 5 delete the publisher token · 6 each v:3 pointer of this origin: write `t/<id>`, delete pointer; cloud links of this member per the flag (default keep until expiry) · 7 record status=removed |
| ACTIVE | `leave` | member | token resolves | LEFT | 1 `rm` every own link (pointer, then bytes) · 2 stop and uninstall the service · 3 record status=left (If-Match) · 4 forget tokens, drop local config |
| any | `leave --local` | member | none | (local only) | stop and uninstall the service, forget tokens, drop config; no bucket call. For a member removed while its machine was off |
| REMOVED | `member purge <name>` | admin | lease | none | delete `u/<id>`; the id stays reserved in `u/purged` so it is never reissued |
| R5 publisher | `member adopt <name> --token-id <id>` | admin | lease; token exists and is bucket-scoped | ACTIVE, mode=cloud | `u/<id>` with the token id; existing v:1 records keep `by` (adopt lists them for confirmation) |
| any | publisher token expiry approaches | clock | 14 days left | same | `status` and `member ls` warn; renew with `member renew <name>` (extends `expires_on` in place; verify the API in spike O2) or `rotate` |
| ACTIVE | Worker sees 2+ connectors on a member tunnel | `member ls` / member `status` | | same | flagged "extra connector: rotate now" |

### Link (one id)

```
 (none) ─PUT m/<id> v:3 If-None-Match──► [RESERVED] ─stage + row + Caddy handle──► [LIVE]
           412: new id (5 tries)            │ die: own reconcile reaps the pointer after 10 min
                                            ▼
 [LIVE] ⇄ OFFLINE (runtime: member machine down, generic 503 page)
 [LIVE] ─member paused──► [PAUSED 503] ─resume──► [LIVE]
 [LIVE] ─refresh (owner install)──► [LIVE]
 [LIVE] ─expires passes──► [EXPIRED: Worker 404] ─owner's hourly prune──► (none)
 [LIVE] ─rm (owner)──► (none): pointer deleted, proof GET 404, bytes and row trashed
 [LIVE] ─rm (admin / other publisher)──► [REVOKED]: t/<id> + pointer deleted
          ─owner's hourly reconcile──► row marked revoked, Caddy handle dropped, t/<id> deleted
          ─owner rm──► (none)        ─row expiry──► (none)
 [LIVE] ─member rm──► [REVOKED] for every v:3 link of that origin (the machine may never come back: leave --local cleans it)
```

| From | Event | Actor | Guard | To | Writes |
|---|---|---|---|---|---|
| none | `add <file>` | active machine member | record active; token resolves; id free in `m/`, `o/`, `t/` | LIVE | pointer v:3 If-None-Match under `add-<id>` lock · stage · publish · row · Caddy handle |
| none | `add <port>` | active machine member | spike O1 shows WebSocket and streaming through the binding | LIVE (live) | as above, row `live` |
| none | `add --cloud <file>` | active member, either mode | record active | LIVE (cloud) | v:1 path unchanged; record gains `origin` |
| none | `add --access ...` | member | | refused | "gated links are added by the admin" (the member token has no Access scopes) |
| none | `add --host ...` | member | | refused | as today |
| LIVE | `refresh` | owner install | own row | LIVE | unchanged |
| LIVE | `rm` | owner | | none | DELETE pointer · proof GET 404 · bytes and row trashed |
| LIVE | `rm` | admin, or any publisher on a cloud link (unchanged rule) | | REVOKED | `t/<id>` (If-None-Match) · DELETE pointer · proof GET 404 |
| REVOKED | owner reconcile | member hourly loop | | REVOKED (local) | row flagged, handle dropped, `t/<id>` deleted |
| LIVE | expiry | Worker | | EXPIRED | none |
| EXPIRED | prune | owner (hourly), or admin/origin | | none | pointer deleted; owner trashes bytes and row |

### Reconcile (every install, own origin only)

| Local row | `m/<id>` | `t/<id>` | Action |
|---|---|---|---|
| no | own pointer, older than 10 min, no live add lock | any | DELETE pointer |
| no | other origin's pointer | any | nothing |
| yes, live | own pointer | absent | nothing |
| yes, live | own pointer | present | delete the tombstone (stale or forged; the pointer proves the link is wanted) and report it |
| yes, live | absent | present | flag row revoked, drop the Caddy handle, delete the tombstone, report "removed by <who>" |
| yes, live | absent | absent | write pointer If-None-Match |
| yes, revoked | any | any | nothing (bytes wait for the owner's `rm` or the row's expiry) |
| yes | other record (cloud, other origin) | absent | "shadowed; rm one of them", nothing deleted |
| yes | other record | present | flag row revoked (the id was reissued after a removal) |

Tombstones are never swept by age while their origin's record is not REMOVED; the owner deletes its own. Tombstones of REMOVED or purged origins are swept by `LastModified` (server clock), 30 days.

## Who may do what

| Actor | Own machine link | Other member's link | Cloud link | Member verbs | Tenant setup |
|---|---|---|---|---|---|
| admin (admin token, any machine) | n/a unless also the origin | rm (revokes) | rm | all | all |
| origin machine (no admin token) | add, rm, refresh | no | add, rm, refresh own | none | none |
| member, active | add, rm, refresh | no (CLI refuses) | add; rm any (today's rule); refresh own | `leave`, `status` | none |
| member, paused / left / removed | no | no | no | `leave`, `leave --local` | none |
| visitor | GET/HEAD; gated links need the Access login | | | | |

The bucket token cannot tell members apart: any publisher can write any key. ADR-0007 accepted that for named teammates; this design keeps that limit and makes the worst case visible and recoverable (a forged tombstone revokes a link the owner can see and re-add; a forged pointer cannot serve a revoked or unlisted row; a forged record cannot change routing). Worker-mediated writes with tool keys (plan B) are the upgrade before anyone outside the team publishes.

## Credentials

| Credential | Minted by | Scope | Lives | Revoked by |
|---|---|---|---|---|
| admin token | owner, once | Workers Scripts Edit, Workers R2 Storage Edit, Zone Read, DNS Read, Cloudflare Tunnel Edit, Connectivity Directory Admin, Access Apps Edit (gated links) | env, from 1Password | owner |
| minter token | owner, once | Account API Tokens Write only; mints account-owned member tokens (they survive the admin's user leaving) | separate 1Password item, read only by member add / invite / rotate / renew | owner |
| member publisher token | `member add`, `invite`, `rotate` | R2 bucket item write on the share bucket + Zone Read; expiry `--token-ttl` | member Keychain | `member rm`, `rotate`, `invite` |
| member connector token | `member add`, `rotate` (machine) | runs that one tunnel | member Keychain | `rotate` (connections dropped first), tunnel delete in `member rm` |
| invite code | `member add`, `invite`, `rotate` | unseals one invite, once, before its expiry | shown once to the admin | redeem, expiry |

Trust, stated in `join` output and ADR-0009: an account admin with Connectivity Directory Admin could bind more services to a member's tunnel and reach whatever that machine reaches. Recommended: run share as a dedicated user, or behind a host firewall. `member ls` lists every VPC Service on each member tunnel.

## Rejected

| Option | Why not |
|---|---|
| One tunnel, many connectors | Cloudflare spreads requests across a tunnel's connectors; links fail at random |
| A hidden origin hostname per member with an Access service token | A real DNS name per member; the owner asked for no new subdomain |
| Routing table read from the bucket per request | One more R2 GET per passed request, and members can write the bucket; the deploy is the safer source |
| Destructive tombstones (owner trashes bytes on a tombstone) | Any token holder could delete files on every machine; review-1 blocker 1 |
| Invite blob holding raw tokens | A pasted blob stays valid forever; the connector token never expires; review-1 major 6 |
| Plan B now (Worker accepts writes with tool keys) | A write path and R2 write credentials inside the Worker; not needed while publishers are named teammates |
| `cf1:network` binding with private hostname routes | Fewer redeploys, but the docs do not confirm routing to a loopback service; revisit after the spike |

## Cut from v1 (after live use)

`member move` (rm and re-add, or rotate on the new machine, covers it), an `edit` verb, `teardown --cascade`, a public per-member health leg, gated links by members, member `hits`.

## Open questions

| # | Question | How it closes |
|---|---|---|
| O1 | A VPC Service on a member tunnel to `127.0.0.1:<port>` (plain HTTP): does it reach Caddy from a Free-plan Worker, which Host does Caddy see, does streaming and WebSocket pass, what latency? | Spike on Console Labs: the Mini as origin, a second machine as member |
| O2 | Can a minter token create account-owned tokens scoped to one R2 bucket, and can `expires_on` be extended in place? | Spike against the tokens API |
| O3 | Default for a removed member's cloud links: keep until expiry (proposed) or delete? | Owner |
| O4 | Workers VPC is beta. Ship members behind `--members` on beta? | Owner |
| O5 | Which machine runs the first member: a teammate's server, or a second machine of the owner's for the live acceptance? | Owner |
| O6 | Redeem gives the Worker its first bucket write (one DELETE of `i/<hash>` per redeem). The code is 20 base32 characters (100 bits), so a publisher who lists `i/` cannot brute-force the sealed bytes. Accept this narrow write, or keep invites as a blob sent over 1Password and drop redeem? | Owner; proposed: accept, and record it in ADR-0009 |

## Build order

1. Spikes O1 and O2. If O1 fails, ship only the credential half (tool-minted tokens, redeem-once invites, cloud-only members) and stop.
2. ADR-0009 (members, the trust limit, the deploy-is-authoritative rule) and SPEC-009 from this brief.
3. Groundwork that helps with no members: Caddy serves listed rows only; pointer readers accept v:3; records with `storage:"machine"` of any version no longer block the orphan sweep; Worker v5 enforces pointer expiry; deploy body built from config plus registry on every path.
4. Tenant T1 to T2; admin lease; registry; `member add`, redeem, `join`, `member ls`, `member sync`.
5. `member rm`, `leave`, `leave --local`, `purge`, tombstones and the member reconcile loop.
6. `pause`, `resume`, `rotate`, `invite`, `renew`, `adopt`.
7. Docs, Share Bar member column, `min_cli` notice for teammates.

## Test plan (the shape; SPEC-009 carries the rows)

- Every transition row is one test, on the existing seams (`SHARE_TUNNEL=0`, `r2-dry`, the `*-calls.log` logs).
- Every multi-step verb gets a die-injection test per step: kill after step N, rerun, assert convergence and no orphan token, tunnel, VPC Service, binding, pointer, or invite.
- Concurrency: two admin verbs at once (lease holds; no binding lost); `join` racing `rotate` and `rm`.
- Negative controls: a member reconcile never touches another origin's pointer; a forged tombstone never deletes bytes; a forged pointer never serves a revoked or unlisted row; a forged `u/` record never changes routing; a removed member's link 404s after one redeploy; a paused member's link 503s; a redeemed code fails a second time.
- Live acceptance on `s.console.so` with two machines: add, refresh, rm from both sides; pause, resume, rotate, rm, leave; the visitor's answer checked at every state.

## Exit criteria

- Every state-table row has a passing test; every die point has a convergence test.
- Live acceptance passes on `s.console.so` with two machines.
- A member reaches ACTIVE from a code alone, without opening the Cloudflare dashboard.
- After `member rm`, an API listing shows no tunnel, VPC Service, binding, token, sealed invite, or pointer of that member.

## Review-1 disposition

| Findings | Disposition |
|---|---|
| 1 (destructive tombstones), 11, 13, 33 | Fixed: mechanisms 7 and 8, reconcile table |
| 2 (VPC Service) | Fixed: Cloudflare objects list, member add, rm, exit criteria |
| 3 (add does not converge) | Fixed: resume on the same name, token found by name, re-mint when unsealed |
| 4, 5, 29 (concurrency, drift, deploy paths) | Fixed: mechanisms 2, 4, 5 |
| 6 (invite leak) | Fixed: redeem-once code, connections dropped on rotate and invite, extra-connector flag |
| 7, 32 (scope) | Cut: move, edit, cascade, health leg |
| 8 (gated) | Decided: members cannot add gated links in v1 |
| 9 (member role detector) | Spec work: SPEC-009 lists every `r2on` site (28) with its member behavior |
| 10 (admin availability) | Fixed: mechanism 3 |
| 12 (reconcile scheduling) | Fixed: mechanism 9 |
| 14 (old CLIs, R5 members) | Fixed: `min_cli`, T1-to-T2 guard, `member adopt` |
| 15 (admin token power) | Fixed: separate minter token, account-owned member tokens |
| 16, 17 (member LAN, same origin) | Stated in Credentials and ADR-0009; Access headers stripped |
| 18 to 28, 30, 31 (minor) | Folded into the tables, the spike list, and the T1 guard |
