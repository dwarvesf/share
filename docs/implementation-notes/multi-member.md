# Implementation notes: multi-member (SPEC-009)

The delta from `docs/specs/SPEC-009-multi-member.md` that the builder needs. TASK-1a writes its live answers here too.

## Spec validation round 1: warnings for the builder

The criticals were folded into the spec (DEC-58 to DEC-73). These warnings were not; each is something the build's own tests should catch, or a choice the builder makes.

### Die points and retries
- Add DP rows the spec does not list: resume (TASK-3a); renew; invite at the VPC Service PUT, the record hash, the old `i/` delete and the `invited` write; rotate at the token re-mint, the new invite and the `rotation+1` write; rm with `--cloud-links delete` part done and at the `i/` delete; admin revoke between the `t/` write and the `m/` delete; `sync --rebind` at its deploy.
- `rotation` increments only when rotate starts from `active` or `paused`, never on a rerun from `rotating`. "Old" means every tunnel or service of this member whose name is not `-r<rotation>`.
- `r2_api_retry` retries POST on any 5xx. Never auto-retry a create (tunnel, service, token): a committed create that answered 500 leaves a second object. A rerun finds it by name. Add a dry seam that commits and then answers 500.
- Join: step 3 finding a status that is not `invited` with no 412 (for example `removing`) removes local config and tokens, as a 412 does. Step 6 hitting a 412 because the admin ran `member invite` from `joining` dies `member_changed`. A new `join <code>` retires a stale `ops/join.*`.

### Worker
- `decide()` cannot be pure for `V3_DOWN`, `V3_SERVED` and the `REDEEM_*` rows: split it into `decide` before I/O (an intent row) and a pure `settle(intent, outcome)`, so SV-26 asserts both.
- Row 15 needs a fetch timeout (an `AbortSignal`); pick the value from TASK-1a(d)'s measurement and record it here.
- The claimed `i/` body keeps `expires`, so `member sync` can sweep a claim left without its delete.

### CLI
- After TASK-0b, `add` ignores a `caddy_reload` failure (`|| true`), so a new link would answer 404 with no message. Warn when the reload fails.
- The 20-member cap: count non-`removed` machine records plus bound `M_*` bindings, whichever is larger. TASK-1a(e) should deploy at 20 and at 25 and route one request through each binding, not deploy only.
- `--no-members` leaves REMOVED `u/` records, `u/purged.json`, `t/` and `i/` objects. Either sweep them in `--no-members` after its refusals pass, or say in the docs that they stay.
- `sync --rebind` finds services only. A tunnel or token whose record is gone is found only by the e2e listings; consider a `member ls` drift code for account objects named `share-<host-dashes>-*` with no record.
- `sync --rebind` and a `removing` record forged back to `active` mid-rm: rebind prints the list and needs `--yes`.

### Security hygiene
- Minter least privilege: MB-04 refuses a minter missing scope but not one with extra scope. Read the minter's own policies and refuse anything beyond API Tokens Read and Write.
- `share join <host> -` reading the code from stdin would keep the code out of shell history; the Share Bar would then pass it on stdin. Optional for v1 (invariant 7 now names the code as an exception).

### Sustainability
- `member ls` reads recorded `expires_on`, not live validity. Add drift codes `token_expiring` and `token_missing` from the current minter's `GET /user/tokens`, and feed them to the Share Bar's Needs a look.
- The minter token needs an owner and a runbook line in `docs/setup.md` (TASK-4c): which user mints, its own expiry, what to do when that user leaves (DEC-73's `--token-unreachable`, then `rotate`).
- A Workers VPC regression looks like a sleeping member (both answer the generic 503). `member ls` could flag a bound service whose connectors are above 0 while a probe of a known link answers 503.
- The beta is free today (ADR-0009). Record the post-beta cost line and the "cloud members only" fallback as a procedure in the docs.
- The hourly member loop with a locked Keychain only logs a line. Surface `loop_stalled` in `status` when the last good reconcile is over 24 h old.

### Share Bar
- `shadowed` and `gate_missing` have no row in the UI `link_state` table: treat both as `live` for click, drag and menu, with their state word in the meta line.
- The All links window's bulk Remove appends one entry to `pending` (DEC-70), with every id in one `rm` argv.

### Other
- TASK-4b23 attributes the Stop Waiting copy to SPEC-010 G9; SPEC-010 says G11 owns it. Use G11's string.
- Phase 0's "a sample that disagrees lands as a Worker v6 fix in Phase 1" also covers a CLI fix in carry-forward (TASK-0e), which needs no Worker bump.

## Phase 0 build (SG-03: TASK-0a to 0f)

Built on main at f28cb13 (SPEC-010 Phase 1 shipped). TASK-1a (SG-01) had landed, so the binding shape, the 10 s fetch timer and the carry-forward deltas above are built in, not guessed.

### AC to test map

| AC row | Test (label prefix `mm` in tests/share.sh, `v5` in tests/worker.mjs) |
|---|---|
| TASK-0a, OT-19 | `mm OT-19: share version equals the newest CHANGELOG heading` |
| SV-01 | `mm SV-01: unlisted bytes answer 404` (NC-2) |
| SV-02 | `mm SV-02: a listed snapshot: /<id>/ 200, /<id> redirects, /<id>/f 200` |
| SV-03 | `mm SV-03: a revoked row answers 404 and leaves the Caddyfile` |
| SV-04 | `mm SV-04: live and --host rows render as before` |
| SV-05 | `mm SV-05: every Caddy answer carries X-Share-Served: caddy` |
| SPEC-008 compat row 1 | `row 1: every artifact byte-identical but the listing additions` (Caddyfile normalized) plus `row 1: the Caddyfile changes only by listed rows, the 404 catch-all and X-Share-Served` |
| SV-06 | `mm SV-06: a v:3 pointer never blocks the orphan sweep` (NC-12) |
| SV-07 | `mm SV-07: ls and state show a v:3 row with its origin` |
| SV-08 | `mm SV-08: a malformed v:3 is skipped as forged` |
| SV-09 | `mm SV-09: a tombstoned id is never picked` (NC-16) |
| OC-01 | `mm OC-01: the origin's reap list stays v:2` |
| OC-06, OC-08, state_schema_ok | `mm SV-07` also runs `state_schema_ok`; `origin` is additive |
| RC-14, FG-16 | `mm FG-16: rows_in reads revoked_by= only in its charset` |
| SV-10 to SV-24, SV-26 to SV-28, FG-12, OC-05, OT-07, OT-13, OT-18 | `v5 <id>: ...` rows in tests/worker.mjs |
| DY-01 to DY-05 | `mm DY-0n: ...` |
| TASK-0f, TN-10 | `mm TN-10: member keys survive a setup rerun and api-token --cmd` |

### Build delta

- B1 (TASK-0b): a `--host` snapshot row also gets its `/<id>` handle on the main site, as today's whole-tree handle gave it, so SV-04 holds ("unchanged"). An expired row gets no handle at render time (invariant 4); the hourly prune still trashes it.
- B2 (TASK-0b): `rows_in` keeps a row with `revoked`; a `revoked_by=` value outside `[A-Za-z0-9._@:-]{1,64}` is rewritten to `revoked_by=unknown` (FG-16), so the row stays visible to `ls`, `rm` and `prune` and still renders no handle. (First built as a drop; the advisor showed a dropped row's bytes could never be removed.)
- B3 (TASK-0b): `X-Share-Served: caddy` is a `header` line in every site block, the 404 catch-all site included, so an unlisted path and a foreign Host carry it too.
- B4 (TASK-0c): `state` emits `origin` only on a v:3 row, as the full member_id (`m-an-3f9a1c2d`). Why: DEC-71 matches the last 8 hex of `origin` to the members cache suffix, and an empty key on every row would change SPEC-008 compat row 1, which this sub-goal may change only for the Caddyfile. `ls` prints `origin=<name>` (the name part), as ML-5 expects.
- B5 (TASK-0c): the origin now lists v:3 rows from the bucket (before, it listed no machine record from the bucket: its index was their truth). It still lists no v:2 from the bucket.
- B6 (TASK-0c): `link_state` waits for SPEC-010 G7 (gate table fallback). `revoked` and the members-cache values land with G7 and TASK-1i.
- B7 (TASK-0e): the nonce check of the TASK-1a delta compares the settings `DEPLOY` value with the `X-Share-Deploy` the Worker serves, re-reading both up to 3 times. It runs only when the settings carry something to carry (a `vpc_service`, `MEMBERS` or `PAUSED`), so T0 and T1 reruns make no extra call. Why: a local "last nonce" file breaks when another admin machine deploys in between, and nonces carry no order.
- B9 (advisor critical): the listed-rows Caddyfile also serves `/_probe-*` and `/_migrate-probe-*` from the root of `pub/`. `live_check` and migrate's verify write those files with no row; without the handle every named `setup`, `setup --r2` and `migrate` died at its live check. The suite's fake curl answered 200 for any URL, so only a real-Caddy row (`mm SV-01: the CLI's own probe files ...`) catches it.
- B10: the Caddy catch-all answers the Worker's 404 body, so an unlisted path on the origin reads like a Worker 404 (DEC-38). A file missing under a listed id still gets Caddy's empty 404; the v:3 pointer already says the id exists, so that leaks nothing new.
- B11: the member fetch passes the timer's signal both in the `Request` and as `fetch`'s second argument (TASK-1a(d) sampled the second form). The test binding reads the second argument, so SV-11 is no longer vacuous (Node's `Request` always has a signal).
- B12: a member answer keeps an allowlist of headers (`accept-ranges`, `content-length`, `content-range`, `content-encoding`, `content-disposition`, `content-language`, `etag`, `last-modified`, `location` on a checked 3xx only, `date`, `vary`). The denylist of the spec row let `WWW-Authenticate`, HSTS and `Link` through.
- B13: a redeem body declared over 128 bytes is refused unread (400).
- B14: `r2_carry_services` drops a binding only on 404 with code 5104 (the sampled "service gone"); any other 404 dies. `r2_carry_fresh` accepts two settings reads that agree when `/healthz` is not answered by a share Worker, so a rerun that repairs a missing route is not blocked.
- B15: the deploy nonce global is `r2_deploy_nonce`; `r2_nonce()` stays the upload-prefix function.
- Open (TASK-1d): the freshness check skips a settings read with nothing to carry, so a stale empty read right after `setup --members` would drop `MEMBERS`. TASK-1d builds its body after the lease; it should also compare the settings `DEPLOY` with the nonce it last deployed before it trusts an empty carry.
- Open: render-time expiry covers listed snapshot handles only; live and `--host` rows keep today's rule (served until prune), as SV-04 asks for "unchanged".
- B8 (TASK-0e): before a deploy that carries a `vpc_service` binding, a GET by `service_id` drops a binding whose service is gone (404) and names it; any other answer dies before the deploy. This adds `GET .../connectivity/directory/services/<id>` to the dry seam (one file per service under `.cf/services/`); TASK-1b grows the rest.

## TASK-1a live samples

Run 2026-11-14 on the Console Labs account from the Mac Mini, cloudflared 2026.10.7, Caddy from Homebrew. Every object had a throwaway `share-e2e-` name and is deleted (proof: `docs/verification/members-live-samples.md`). Scripts stayed in the session scratchpad. They read credentials from 1Password into variables and pass tokens through `-H @<(printf ...)` and `-K <(printf ...)`, never argv. `<a>` is the account id, `<t>` a tunnel id, `<sid>` a VPC Service id. Excerpts are masked.

The admin token `cf-console-labs-token` holds no Connectivity Directory or R2 scope. The samples used a throwaway user token `share-e2e-admin-<8hex>`, minted by the minter with Connectivity Directory Admin, Cloudflare Tunnel Write, Workers Scripts Write and Workers R2 Storage Write on the account. It was deleted at the end. This also shows the minter is as strong as its user: it can mint any scope that user holds. A leaked `minter_token_cmd` output is an account-admin leak, a risk row the spec's failure modes lack.

### Answers at a glance

| Q | Closes | Verdict | Design consequence |
|---|---|---|---|
| (a) VPC Service REST | OQ-1 | pass | permission group `Connectivity Directory Admin`; PUT needs the whole body; one service per tunnel, ipv4 and port |
| (b) binding entry, settings shape, drop | OQ-2 | pass | every T2 deploy needs Connectivity scope; a deploy without the entry drops it |
| (c) bucket-scoped mint, extend, revoke | OQ-3 | pass; S3 leg inferred from the 2026-09-30 run | 50 user tokens per user, shared by everything the minting user holds: about 8 member tokens fit today |
| (d) binding fetch with the origin down | OQ-4 | pass | a down origin throws in under 1 s; a hung listener hangs, so row 15 needs `AbortSignal.timeout` |
| (e) 25 bindings | OQ-5 | pass | the binding cap can rise to 25, but the minter's token slots bind first; delete a service only after a deploy drops its binding |
| (f) connections | (Grounding row) | pass | connector count = entries of `GET .../connections`; the tunnel object's `connections` counts conns |
| (g) tunnel with the catch-all, token | (Grounding row) | pass | as specified |
| (h) R2 `put` with a stale `etagMatches` | OQ-7 (stays open) | `null` on local workerd; live not sampled | R2 is not enabled on Console Labs; OQ-7 stays open until a live leg runs there |

### Blocker for later sub-goals: R2 is off on Console Labs

- `POST /accounts/<a>/r2/buckets` with an R2-write token answers 403 `{"code":10042,"message":"Please enable R2 through the Cloudflare Dashboard."}`.
- `s.console.so` today is a proxied CNAME to a tunnel. Console Labs has no `share-*` Worker, no Worker route on `console.so`, and no bucket. The spec's Problem line uses it as the R2 example, but it is a plain tunnel tenant.
- `tests/e2e-members.sh` (ML-1 runs `setup --r2 --members`) and TASK-4e both need R2 on this account. Turning R2 on is a dashboard purchase only the owner can make. SG-11 and SG-12 cannot run until then.

### Spec deltas these samples force

Each row overrides the spec line it names. They are recorded in the megadir DECISIONS.md so the owning sub-goal folds them.

| Delta | Spec line it changes | Owner |
|---|---|---|
| Row 15 sets a timeout on the binding fetch (an `AbortController`, cleared when the headers arrive, 10 s); SV-22 gains a hang row | `### API changes` row 15 (no timeout today) | SG-03 (TASK-0d) |
| Carry-forward resends a `vpc_service` binding only while its service exists; a missing one is dropped and reported, never resent | `## Solution` and TASK-0e "re-sends each `vpc_service`" | SG-03 (TASK-0e), SG-05 (TASK-1f1) |
| A deploy body built from a settings GET checks that the GET's `DEPLOY` value equals the nonce of the last deploy this tenant saw, else it re-reads | TASK-0e, DEC-62 | SG-03 (TASK-0e) |
| The Connectivity Directory scope is needed by every T2 deploy path, `setup --r2` reruns included, not only member verbs | TASK-1c1 scope probes, TASK-1d | SG-05 (TASK-1c1, TASK-1d) |
| `member add`, `invite`, `rotate` and `adopt` read the minter's `result_info.total_count` and refuse before minting at 50; `member ls` shows the free slots | TASK-1f1, Q-SCALE-1, MB-05 (cap 20) | SG-05 |
| OQ-7 needs a live leg: two concurrent redeems on one `i/` object, exactly one 200 | `## Verification` ML table (no such leg) | SG-11 (TASK-4d) |

### (a) VPC Service create, get, list, update, delete

- Scope: the current admin token gets `GET /accounts/<a>/connectivity/directory/services` -> 403 `{"code":10000,"message":"Authentication error"}`. The permission group is `Connectivity Directory Admin` (account scope). `Connectivity Directory Read` and `Connectivity Directory Bind` also exist; whether Bind alone allows a deploy was not sampled. OQ-1 closed: the admin token needs `Connectivity Directory Admin`. The API names the tunnel group `Cloudflare Tunnel Write`; spec:263 calls it Tunnel Edit, the dashboard's word. A scope probe names the API string.
- Create: `POST /accounts/<a>/connectivity/directory/services` with `{"type":"http","name":"share-e2e-1642d005-a","host":{"ipv4":"127.0.0.1","network":{"tunnel_id":"<t>"}},"http_port":18765}` -> 200:
  `{"result":{"service_id":"01a1dad7-...","type":"http","name":"share-e2e-1642d005-a","http_port":18765,"https_port":null,"host":{"ipv4":"127.0.0.1","ipv6":null,"hostname":null,"network":{"tunnel_id":"<t>"},"resolver_network":null},"created_at":"...","updated_at":"..."},"success":true}`. The id field is `service_id`, not `id`.
- Same name again -> 400 `{"code":5101,"message":"request contained invalid parameters: Service name 'share-e2e-1642d005-a' already exists"}`. Names are unique per account, so find by name is unambiguous.
- Same tunnel, ipv4 and port under another name -> 400 `{"code":5101,"message":"... Service already exists for port https:18781 on 127.0.0.1"}`. The same port on another tunnel is accepted (the spike service and this one both used 18765). Rotate makes a new tunnel, so its new service never collides with the old one.
- `GET .../services/<sid>` -> 200, the same object.
- List: `GET .../services` returns every service (27 seen) and no `result_info`. `?name=<n>` is ignored (both services came back). `?per_page=10&page=2` returns the next 10. TASK-1f1 finds by name by paging with `per_page` and `page` until a page is short.
- Update: `PUT .../services/<sid>` with the whole create body and `http_port` 18766 -> 200, `http_port` 18766. A partial body `{"http_port":18767}` -> 400 `{"code":5102,"message":"invalid json: bad json data: missing field \`host\` ..."}`. `invite --port` sends the whole body.
- Delete: `DELETE .../services/<sid>` -> 200 `{"result":null,"success":true}`. Again -> 404 `{"code":5104,"message":"Service (ID: \"...\") not found"}`. `GET` of a deleted id -> 404 5104. An idempotent delete treats 404 5104 as done.

### (b) the multipart `vpc_service` binding

- Metadata part (the same multipart PUT as `r2_deploy`): `{"main_module":"w.js","compatibility_date":"2026-09-30","bindings":[{"type":"plain_text","name":"HOST","text":"s.console.so"},{"type":"vpc_service","name":"M_1642d005","service_id":"<sid>"}],"keep_bindings":["secret_text"]}`.
- With the current admin token (Workers Scripts Write, no Connectivity scope) -> 403 `{"code":10196,"message":"Workers VPC binding configuration failed because your credentials are not authorized for the requested VPC resource. ..."}`. With `share-e2e-admin` -> 200. Every deploy that sends a `vpc_service` entry needs the Connectivity scope, the TASK-0e carry-forward included. A `setup --r2` rerun on T2 therefore needs it too. TASK-1c1 probes only member verbs, so `setup`'s T2 path needs the same probe (see Spec deltas).
- `GET /accounts/<a>/workers/scripts/<w>/settings` -> `.result.bindings`: `[{"name":"HOST","text":"s.console.so","type":"plain_text"},{"name":"M_1642d005","service_id":"<sid>","type":"vpc_service"}]`. The shape matches the deploy entry, so carry-forward can resend the entry as read. The current admin token can read it (200).
- A deploy without the entry drops it. Settings and the runtime `Object.keys(env)` both read `["HOST"]`, with `keep_bindings` `["secret_text"]`, absent, or `[]`. A token without the Connectivity scope can drop the binding (200).
- One settings GET made right after a deploy returned the pre-deploy binding list once (b2), and a repeat at +0 s did not (b4). Cause unknown. The `X-Share-Deploy` wait proves what the runtime serves, not what the settings API returns. A stale read during carry-forward could resend a binding that `rm` dropped, and then every deploy fails 10180 (see (e)). The plain-text `DEPLOY` value is in the settings GET, so the builder can compare it to the last nonce (see Spec deltas).
- Not used, recorded: `keep_bindings: ["secret_text","vpc_service"]` with no entry keeps every existing `vpc_service` binding, even from a token without the Connectivity scope. It cannot drop one binding, so the spec's explicit carry-forward stays.

### (c) the minter mints a bucket-scoped member token

- `POST /user/tokens` with the minter: `{"name":"share share-e2e-1642d005 m-e2e-48155d47","expires_on":"<+2h>","policies":[{"effect":"allow","resources":{"com.cloudflare.edge.r2.bucket.<a>_default_share-e2e-1642d005":"*"},"permission_groups":[{"id":"<Workers R2 Storage Bucket Item Write>"}]},{"effect":"allow","resources":{"com.cloudflare.api.account.zone.<zone>":"*"},"permission_groups":[{"id":"<Zone Read>"}]}]}` -> 200, `status` `active`. The value is 53 chars. bin/share checks no token length, so nothing changes.
- `GET /user/tokens/verify` with the new token -> `{"status":"active"}`.
- `PUT /user/tokens/<id>` with name, policies and `expires_on` +1 day -> 200, `expires_on` moved. `PUT` with `{"expires_on":...}` alone -> 200, `expires_on` moved, both policies kept. Verify after the PUTs: `active`, same secret. `renew` may send either body.
- `DELETE /user/tokens/<id>` -> 200 `{"result":{"id":"..."}}`. Again -> 404 `{"code":1003,"message":"token not found"}`. Verify after delete -> 401 `{"code":1000,"message":"Invalid API Token"}`.
- Find by name (D3, TASK-1f1): `GET /user/tokens?per_page=50&page=<n>` with the minter. Each row has `id, name, status, issued_on, modified_on, expires_on, not_before, last_used_on, policies`, never the value. `result_info` has `page, per_page, total_pages, count, total_count`. Match `.name == "share <host> <member_id>"` and read `id` and `expires_on` from the row. `GET /user/tokens/<id>` returns the same row without the value.
- Limit: Cloudflare allows 50 user API tokens per user (developers.cloudflare.com/fundamentals/api/reference/limits; documented, no mint at the limit was made). The limit counts every token the minting user holds, for every tenant and for the user's own use. The minter user holds 42 after cleanup, so about 8 member tokens fit. That is below the 20-member cap. A dedicated Cloudflare user as the minter gets the full 50. Proposed for SG-05: `member add`, `invite` and `rotate` read `result_info.total_count` before minting and die with a code naming the limit at 50; `member ls` shows the free slots. Moving members to account-owned tokens (500 per account) is the upgrade the spikes named.
- S3 leg not run here: R2 is not enabled on Console Labs (`POST /accounts/<a>/r2/buckets` -> 403 `{"code":10042,"message":"Please enable R2 through the Cloudflare Dashboard."}`; the S3 host fails the TLS handshake). The same minter's bucket-scoped tokens (Bucket Item Write on one bucket plus Zone Read, plus account groups) did `PUT m/<id>` with `If-None-Match: *` live on the Dwarves account on 2026-09-30, `docs/verification/r2-e2e-2026-10-01-final.txt` (84/84). Those tokens also held account groups, on another account, so the S3 leg for the exact member shape is an inference, not a sample. OQ-3 is closed for the mint; the first S3 write with a member token (SG-11 ML-2, ML-4) confirms the rest.

### (d) the binding fetch when the origin is down

Worker: `env.M_<8hex>.fetch(new Request("http://s.console.so/x", {redirect:"manual"}))` from a workers.dev Worker. Times are the Worker-side `Date.now()` difference.

| Origin state | Result | Time |
|---|---|---|
| Caddy and cloudflared up | 200, `X-Share-Served: caddy`, body passes; Caddy's 404 passes as 404 | 162 to 376 ms |
| Caddy stopped, cloudflared up | throws `Error: ProxyError: connection_refused` | 108 to 624 ms |
| python `http.server` on the port | 200 or 404 from `SimpleHTTP`, no `X-Share-Served` | 163 to 345 ms |
| cloudflared stopped, Caddy up | throws `Error: ProxyError: destination_not_found` for the first ~20 s, then `Error: ProxyError: destination_unavailable` | 13 to 512 ms |
| both down | throws `destination_unavailable` | 13 ms |
| a listener that accepts and never answers | no answer; the client gave up at 120 s | > 120 s |
| the same, with `{signal: AbortSignal.timeout(5000)}` | throws `TimeoutError: The operation was aborted due to timeout` | 5000 ms (10000 with 10 s) |

- Every down state throws fast, so SV-22's "throw" fixture matches the live shape. A foreign listener answers without `X-Share-Served`, which row 15 already treats as offline.
- Row 15 needs the timeout: pick `AbortSignal.timeout(10000)` on the binding fetch, passed as the second `fetch` argument. Decision: 10 s, because every healthy answer took under 0.5 s and every down state under 1 s. Not sampled: `AbortSignal.timeout` keeps running after the headers arrive, and a fired abort also cancels a body still streaming. A large file must not die at 10 s, so row 15 uses an `AbortController` with a timer that it clears once the response headers resolve.
- Caddy matches on Host: a site block for `http://127.0.0.1:<port>` answered the binding's `Host: s.console.so` with an empty 200 and no `X-Share-Served`. The spec's `write_caddyfile` serves `http://<host>:<port>` plus loopback, so it matches; the header check makes a mismatch fail closed (503) anyway.

### (e) 25 bindings on one Worker

- 25 VPC Services on one tunnel (ports 18782 to 18806; one port each, see (a)) were created in 12 s.
- Deploy with 20 `vpc_service` bindings -> 200 in 884 ms; settings count 20; 20 of 20 routed 200 with `X-Share-Served: caddy`.
- Deploy with 25 -> 200 in 997 ms; settings count 25; 25 of 25 routed. OQ-5 closed: 25 works. The CLI cap may rise to 25; above 25 stays unmeasured.
- Delete order (new): `DELETE` of a service still bound to the deployed Worker -> 200, and the Worker kept routing through it right after. The next deploy naming that `service_id` -> 400 `{"code":10180,"message":"VPC Service '<sid>' not found. ..."}`. So:
  - `member rm` deploys without the binding first, then deletes the service. `rotate` deploys with `M_<8hex>` rebound to the new service first (spec:390), then deletes the old service.
  - Carry-forward resends a binding only if its service still exists, or a deleted service blocks every deploy on the tenant; `sync --rebind` drops such a binding. SG-05 or SG-07 adds a die-point row for a service deleted outside the CLI.

### (f) connections and tunnel delete

- With one cloudflared: `GET /accounts/<a>/cfd_tunnel/<t>/connections` -> `.result` has 1 entry `{id, client_id:null, version:"2026.10.7", run_at, conns:[4 items], ...}`. Each `conns` item has `client_id, client_version, colo_name, id, is_pending_reconnect, opened_at, origin_ip, uuid`. Connector count = `.result | length` (1). `conns` length = 4.
- `GET .../cfd_tunnel/<t>` and `GET .../cfd_tunnel?name=<n>` report `"connections": 4` and `"status":"healthy"`. That field counts conns, not connectors, so `extra_connector` must read `/connections`.
- 60 s after cloudflared stopped, `/connections` returned 0 entries. Earlier reads were not taken, so the list may hold a stale entry for up to a minute. Only one connector was sampled; MB-20's two-connector case is not.
- `DELETE .../cfd_tunnel/<t>` while cloudflared is connected -> 400 `{"code":1022,"message":"This tunnel has active connections. Please stop all cloudflared replicas, or wait a few minutes for connections to close, then try again."}`. After stopping cloudflared: `DELETE .../connections` -> 200, then `GET .../connections` -> 0 entries, and `DELETE .../cfd_tunnel/<t>` -> 200 with `deleted_at`.
- `DELETE` of a tunnel that a VPC Service still names -> 200. The service stays and names a deleted tunnel. The removal order is: deploy without the binding, delete the service, delete connections, delete the tunnel.

### (g) a remote-managed tunnel with only the catch-all

- `POST /accounts/<a>/cfd_tunnel` `{"name":"share-e2e-1642d005","config_src":"cloudflare"}` -> 200 `{"id":"<t>","name":"share-e2e-1642d005","status":"inactive","remote_config":true,"config_src":"cloudflare",...}`. Result keys: `account_tag, config_src, connections, conns_active_at, conns_inactive_at, created_at, deleted_at, id, metadata, name, remote_config, status, tun_type`.
- `PUT .../cfd_tunnel/<t>/configurations` `{"config":{"ingress":[{"service":"http_status:404"}]}}` -> 200 `{"version":1,"config":{"ingress":[{"service":"http_status:404"}],"warp-routing":{"enabled":false}}}`. An empty `ingress` -> 400 `{"code":1056,"message":"Bad Configuration: Validation failed: The config file doesn't contain any ingress rules"}`.
- `GET .../cfd_tunnel/<t>/token` -> 200, `.result` a 240-char string, base64 of JSON with keys `a, s, t`. `cloudflared tunnel --no-autoupdate run` read it from the `TUNNEL_TOKEN` environment variable (never argv) and registered in about 4 s.
- `GET .../cfd_tunnel?name=<n>&is_deleted=false` -> 1 row; `result_info.per_page` 1000.

### (h) R2 `put` with a stale `onlyIf.etagMatches`

- Not sampled live: R2 is not enabled on Console Labs (see (c)).
- Local sample on workerd through `wrangler dev --local` (wrangler 4.133.0; compatibility date lowered to 2026-09-23, the newest that binary supports): `put(k,"one")`; `put(k,"two",{onlyIf:{etagMatches:<first etag>}})` -> an `R2Object`; `put(k,"three",{onlyIf:{etagMatches:<first etag>}})` -> `null`; the body stays `two`. Excerpt: `{"matching_put":"R2Object etag b8a9f715…","stale_put":"null","final_body":"two"}`.
- This matches the documented contract and the redeem claim (row 3), on the simulator only. OQ-7 stays open. The live check needs R2 on Console Labs and a new leg in `tests/e2e-members.sh` (see Spec deltas). That leg runs on the throwaway T2 tenant, before the first real one (SG-12).

## Phase 1 build (SG-05: TASK-1b to 1i)

Built on main at f8aba46 (SPEC-010 Phase 1 and Phase 2 shipped, so every row of the gate table holds). Dry seams only; no live Cloudflare call.

### Build delta

- P1 (tests): the Phase 1 rows live in `tests/members.sh`, sourced by `tests/share.sh` before the Worker section. Why: the suite file is 5,100 lines and takes 9 minutes; a sourced file can also run alone under a short harness while the build iterates. Labels stay `mm <id>: ...`.
- P2 (TASK-1b): the dry account answers by the bearer token: `.cf/tokens/<user>/` holds each minter user's tokens, `<user>` a checksum of the token the call carries, so a second minter (MB-34, MB-37) sees its own list. A minted value is `msec-<n>-<user>`, so the Q-SEC-6 grep has a fixed shape to look for.
- P3 (TASK-1b): new seam knobs beside `SHARE_R2_DRY_FAIL`: `SHARE_R2_DRY_DENY` (a glob over `API <METHOD> <path>` answering 403 10000, for the scope probes), `SHARE_R2_DRY_COMMIT_FAIL` (the call is applied, then answers 500: the "committed create that answered 500" warning above), and `SHARE_R2_DRY_PAUSE` now also matches `API <METHOD> <path>` globs (a die point at any Cloudflare step).
- P4 (TASK-1c1): the later-phase verbs (`rm`, `purge`, `pause`, `resume`, `invite`, `rotate`, `renew`, `adopt`) are in the dispatcher: each resolves the admin context and, where DEC-80 names it, the minter, then dies `share member <verb> is not built in this version`. Why: TASK-1c1's AC runs `member renew` to prove the minter command runs once; building renew itself is TASK-3e's. No code is added for the stub, so removing it later bumps nothing.
- P5 (TASK-1d): `--members` needs R2 on already (`bucket=` equal to `--bucket`); from T0 it refuses with the `setup <h> --r2 --bucket B` line first. `min_cli` in the marker is the CLI's own `SHARE_VERSION`, because the constant 0.10.0 in the data model would put the very CLI that wrote it below its own minimum until the release bump.
- P6 (TASK-1d): the marker reaches `state` through a new `.health` key `marker` (`{members, at}`), written by every verb that reads `share.json` (setup --r2, --members, --no-members, member verbs). `profile_role` reads it, so `tier` is `t2` when config `members=on` OR the cached marker says `members:true`, and `state.tier_drift` is true when they disagree (TN-11). `state` stays network free.
- P7 (TASK-1d, CC-14): the pause verb is TASK-3a's, so CC-14 runs both orders with `member add` as the concurrent deploy path; the end deploy holds the new binding. SG-08 adds the pause variant.
- P8 (TASK-1f2): the HMAC is computed in bash over `shasum -a 256` (ipad and opad from the derived key, the message on stdin), because `openssl dgst -hmac <key>` and `-macopt` put the key in argv (Q-SEC-6). The cipher's passphrase rides `-pass fd:3` from a process substitution, never a here-string (bash 3.2 writes a here-string to a temp file).
