# Implementation notes: multi-member (SPEC-009)

The delta from `docs/specs/SPEC-009-multi-member.md` that the builder needs. TASK-1a writes its live answers here too.

## Spec validation round 1: warnings for the builder

The criticals were folded into the spec (DEC-58 to DEC-73). These warnings were not; each is something the build's own tests should catch, or a choice the builder makes.

### Die points and retries
- Add DP rows the spec does not list: resume (TASK-3a); renew; invite at the VPC Service PUT, the record hash, the old `i/` delete and the `invited` write; rotate at the token re-mint, the new invite and the `rotation+1` write; rm with `--cloud-links delete` part done and at the `i/` delete; admin revoke between the `t/` write and the `m/` delete; `sync --rebind` at its deploy.
- `rotation` increments only when rotate starts from `active` or `paused`, never on a rerun from `rotating`. "Old" means every tunnel or service of this member whose name is not `-r<rotation>`.
- `r2_api_retry` retries POST on any 5xx. Never auto-retry a create (tunnel, service, token): a committed create that answered 500 leaves a second object. A rerun finds it by name. Add a dry seam that commits and then answers 500.
- Join: step 6 (the record, once step 3 of the old numbering) finding a status that is not `invited` with no 412 (for example `removing`) removes local config and tokens, as a 412 does. Step 9 (the final record write) hitting a 412 because the admin ran `member invite` from `joining` dies `member_changed`. A new `join <code>` retires a stale `ops/join.*`.

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
- P9 (TASK-1f3): `member add` writes the record's `step`/`step_name` before each step's Cloudflare call and its outcome (token id, tunnel id, service id, invite hash) after it, so `member ls` names the step a died add reached. The lease body and the journal name the same step.
- P10 (TASK-1f3): a member verb never changes the Worker's code: its deploy refuses `worker_mismatch` unless the deployed `VERSION SHA` pair equals this share's. Why: `r2_deploy` uploads this CLI's source, so an admin on an older or newer CLI would otherwise downgrade or upgrade the Worker as a side effect of `member add`. The admin reruns `setup --r2` first.
- P11 (TASK-1f3, OT-08): the Worker deploy retries a 5xx up to 3 times, on every deploy path (it is a whole-script PUT, so a retry is safe). The dry deploy now honors `SHARE_R2_DRY_FAIL` on the PUT (before, it wrote `script.json` whatever the answer).
- P12 (TASK-1f3): the sealed bundle also carries `min_cli` (from the marker) and `publisher_key_id` (the token id, the member's S3 access key, so the member needs no verify call). The member cannot read the marker before redeem, so `cli_below_min` is checked after the redeem and before any local write; MB-07 allows a refusal after a 200 redeem.
- P13 (TASK-1h): join's step 0 checks that need the bundle (mode, `caddy`, `cloudflared`, the invite port) run after the unseal and before any local write: before the redeem the member knows neither its mode nor its port. The code is spent by then; each copy names the admin's next command (OT-04's copy already says so). The 404 copy cannot name the member (unknown before redeem), so it says `<your name>` and names both `rotate` and `invite`.
- P14 (TASK-1h): the probe of step 5 accepts 200, and also the Worker's paused 503 when the record's `prev_status` is `paused` (a re-join after rotate or invite of a paused member, MB-26, MB-33): the deploy still pauses that member, so no 200 can come back.
- P15 (TASK-1h): `SHARE_JOIN_SERVICE=0` is a test seam: join skips the login service and starts serve in the background, as `share start` does without one (the suite's stub `launchctl` never starts serve). The keys go to the Keychain only; a member config gains `r2_key_id` and `token_expires` (DEC-79's local expiry) beside the spec's keys.
- P16 (TASK-1h): a join refusal after the record re-read is `member_changed` (the join table), never `member_not_allowed`: `reg_status` takes the caller's refusal code.
- P17 (TASK-1g): a member lists its own v:3 rows from its index only; the bucket adds other origins' v:3 rows. A member's `--cloud` record carries `origin`. Its own add reads its own record first (one GET): paused, pausing, left, removing or removed adds nothing (WM-01), and the read refreshes the `.health` `member` key `state.member.status` reads.
- P18 (TASK-1i): `member ls` shows `step <n> of <m>` with `<m>` from the verb's journal list; `--json` adds `of`, `expired` and `prev_status`. The token slot line prints only with `SHARE_MINTER_TOKEN` in the environment, because `ls` never runs `minter_token_cmd` (TASK-1c1). `member sync` takes the lease and journals as `member-sync`.
- P19 (TASK-1d): `--no-members` also refuses while any `vpc_service` binding is deployed, and while a `u/` record fails validation, since either may be a member; the docs say which objects stay (REMOVED records, `u/purged.json`, `t/`, `i/`).
- P20 (TASK-1d): a `setup --r2` rerun on T2 probes the services list (Connectivity Directory Admin) before any write, takes the lease before the deploy, rereads the settings under it (forced freshness check, closing the open LOW), and holds it through the nonce wait.
- P21: the dry seam's `GET /user/tokens/verify` answers the minter's own id when the CLI calls it as the minter (`api_who=minter`), so the minter's own policies can be read by name.
- P22: three dry-only test verbs, unlisted: `share r2-api [--minter] METHOD PATH [JSON]`, `share worker-call GET|POST ...`, and `state-fn reg-step|obj|invite-seal|invite-open|hmac|member-can|member-can-all` (the writing ones need `SHARE_STATE_FN_WRITE=1`).
- P23: the later verbs (`rm`, `purge`, `pause`, `resume`, `invite`, `rotate`, `renew`, `adopt`) already pass their record through `member_can`, so MB-24's `member_busy` refusal is real code; then they die "not built in this version".

- P24 (CC-01, advisor round): two `member add` runs on ONE profile do not wait on the lease: the step journal refuses the second at once with `op_running`. The lease serializes admins across profiles and machines, which is what CC-01's test drives (`mm CC-01 (one profile): ...` pins the single-profile answer).
- P25 (advisor round): `member add` runs its name, cap and token-count refusals again right after `lease_take`, on a fresh `reg_list` and settings read, and `--no-members` reruns its `members_present` refusals under the lease. Why: an add on another machine that held the lease while these refusals ran would otherwise yield two records of one name, a 21st member, or a T1 tenant with a live member. The spec's "refusals first; lease" order holds for the first pass.
- P26 (advisor round): `SHARE_TEST_CODE` and `SHARE_TEST_MEMBER_IDS` are honored only with `SHARE_R2_DRY=1`, and the `r2-api` and `worker-call` test verbs refuse without it, so an exported test variable can never fix a live invite code or print a live token.
- P27: the code for a tenant with members off is `members_off`, not `tenant_not_t2`: the suite's code-table check reads codes as `[a-z_]+`, so a digit split the name.
- P28: SPEC-008's TN-10 fixture (SG-03) put `role=member` in an origin config; with TASK-1g that profile is a member and `setup` refuses it ("share leave first"), so the fixture keeps `members=on`, `member_id` and `member_mode` without `role=member`. TN-10's intent (unowned keys survive) is unchanged.
- P29: `reg_jq_valid` requires integer `step` and `rotation` and ISO-like `added`, `updated` and `joined`; `migrate` on a T2 origin dies `members_present` (before, the older R2-on refusal with no code).

### Open questions for the operator

- Q1: TASK-1g's "proof GET 404" on a member's own `rm` is read as "the pointer is gone": `cmd_rm` makes no Worker fetch today. Confirm, or SG-07 adds a fetch through the Worker after the DELETE.
- Q2: MB-26's rotate, invite and renew steps are later verbs; the test builds the state they leave (`invited`, `prev_status` `paused`) and proves join's half. SG-08 adds the admin half.

### AC to test map (Phase 1)

| AC row | Test (`mm` labels in tests/members.sh) |
|---|---|
| TASK-1b seams | `mm seam: ...` (22 rows), `=== members: dry seams ===` |
| CC-13 | `mm CC-13: ...` (4 rows) |
| WM-03 | `mm WM-03: ...` |
| MB-04, OT-16 | `mm MB-04: ...` (2), `mm MB-04, OT-16: ...` |
| OT-15 | `mm OT-15: ...`, `mm OT-15, OT-06: ...` |
| TASK-1c1 JSON line, minter command | every refusal row reads `mx_jcode` (the last line is the JSON line, its code in `state-fn codes`); `mm TASK-1c1: member renew runs minter_token_cmd once` |
| CC-09, CC-10, CC-15, CK-01, FG-10 | `mm CC-09: ...` (2), `mm CC-10: ...`, `mm CC-15: ...`, `mm CK-01: ...`, `mm FG-10: ...` |
| TN-01 to TN-09, TN-11, TN-12, CC-14 | `mm TN-0n: ...`, `mm TN-11: ...`, `mm TN-12: ...`, `mm CC-14 (setup-first|add-first): ...`; the die-point loops `mm TN-09: setup-members ...`, `mm TN-09: no-members ...` |
| member_can iteration | `mm member_can: every (status, verb, actor, mode) tuple matches the doc table` (the expectation is parsed from the spec's table) |
| MB-03, MB-24, MB-25, FG-05 to FG-07, FG-13 | `mm MB-03: ...`, `mm MB-24: ...`, `mm MB-25: ...`, `mm FG-13: ...`; FG-05 and FG-06 under `member ls`; FG-07 is `deploy_unbound_record_live` in `mb_report` |
| TASK-1f1, FG-15 | `mm TASK-1f1: ...` (6), `mm TASK-1f1, FG-15: ...` |
| TASK-1f2 | `mm TASK-1f2: ...` (4); the Q-SEC-6 grep is `=== members: no token ... (Q-SEC-6) ===` |
| MB-01, MB-02, MB-05, CC-01, CC-12, CK-03, DP-add-1 to 9 | `mm MB-01: ...` (4), `mm MB-02: ...`, `mm MB-05: ...` (2), `mm CC-01: ...` (2), `mm CC-12: ...`, `mm CK-03: ...` (4), `mm DP-add-1 to DP-add-9: ...`, `mm DP-add-3: ...`, `mm DP-add-9: ...`, `mm OT-08: ...` |
| LK-01 to LK-07, LK-13, LK-17, LK-18, WM-01, WM-02, CC-05, OT-05, RC-15, SV-25 | `mm LK-0n: ...`, `mm LK-13: ...`, `mm LK-17, CC-05: ...`, `mm LK-18: ...`, `mm WM-01: ...` (3), `mm WM-02: ...`, `mm OT-05, OT-04: ...`, `mm RC-15: ...`, `mm SV-25: ...` |
| MB-06, MB-07, MB-26, MB-27, MB-32, DP-join-1 to 6, FG-08, OT-04, OT-06 | `mm MB-06: ...` (3), `mm MB-07: ...` (8, FG-08 among them), `mm MB-26: ...`, `mm MB-27: ...` (2), `mm MB-32: ...`, `mm DP-join-n: ...`, `mm OT-06: ...` |
| CC-11 | `v5 SV-15: two concurrent redeems of one object: exactly one 200` (tests/worker.mjs) |
| MB-08, MB-20, MB-22, MB-23, MB-28, MB-29, MB-33, MB-35, OC-03, FG-05, FG-06 | `mm MB-08: ...` (2), `mm MB-20: ...`, `mm MB-22: ...` (2), `mm MB-23: ...`, `mm DEC-75: ...`, `mm MB-28: ...` (2), `mm MB-29: ...`, `mm MB-33: ...` (2), `mm MB-35: ...` (3), `mm OC-03: ...`, `mm FG-05, FG-06 (NC-9): ...` |
| Q-SEC-6 | `mm Q-SEC-6: ...` (3) |
| NC-7, NC-9, NC-11 | red runs on mutants of bin/share: CC-01, FG-05 (NC-9), DP-join-3 (NC-11) fail; green in the suite (`docs/verification/members-core.md`) |

## Phase 2 build (SG-07: TASK-2a to 2e)

Built on main at f8042fa. Dry seams only; nothing live.

### Build delta

- P30 (TASK-2a): the admin revoke lives in `cmd_rm_r2`'s no-cloud-row branch (`r2_rm_machine`, `member_revoke`): an id whose pointer is a v:3 of another origin is revoked only after `member_context` proves the admin token, so the admin S3 pair writes `t/` and deletes `m/`. With no admin token the refusal is the new code `revoke_needs_admin`, before any write. Why a code: the Share Bar maps it (TASK-4b9). A member's own pointer with no local row, and an origin's v:2 with no local row on the origin, keep today's `no share with id`.
- P31 (TASK-2a): "refused before any call" (LK-09) is read as before any write: the CLI must read `m/<id>` (through the listing it already makes) to learn that the id is another member's v:3.
- P32 (TASK-2b): `r2_reconcile` keeps the origin's code path byte for byte (DEC-17: the origin never reads `t/`), and adds a member path for R7 (`r2_reconcile_member`) that walks the 13-row table. It lists `t/` after `r2_read` listed `m/` (DEC-64), and reads a tombstone body only for the ids a row needs (`by` for the report, `origin` for row 5).
- P33 (TASK-2c): `share prune --loop` is the serve loop's verb on R7; elsewhere it is a bare prune. On R7 it reads the publisher token from the Keychain item only (never `api_token_cmd`, never the environment), runs local expiry, own pointer expiry, the reconcile, and one read of its own record into the `.health` cache. `SHARE_API_TOKEN_OFF=1` still holds for Access: `r2_token_ok` lets the loop's Keychain token through only for bucket calls. Serve spawns the loop under `env -u CLOUDFLARE_API_TOKEN`; under the dry seam the loop logs `LOOP env_token=<0|1>` so the suite proves it (NC-loop below). The dispatcher passed no argument to `cmd_prune` before; it now passes `--loop`.
- P34 (TASK-2d): `member rm` finds tunnels by listing every live tunnel of the account (`mb_tunnels_of`) and VPC Services by the paged list, matching `share-<host-dashes>-<8hex>(-r<n>)?`, so a forged `rotation` cannot hide a rotated tunnel; the record's ids are never used (FG-15). Steps: 1 lease, 2 removing, 3 deploy, 4 service, 5 connections, 6 tunnel, 7 token, 8 tombstones (and cloud links with `--cloud-links delete`), 9 invite, 10 removed. Step 3 runs for a cloud member too (it skips when nothing changes). The invite step deletes the record's `i/` and every `i/` whose envelope names this member_id.
- P35 (TASK-2d, DEC-78): after the token delete, the record's `token.id` is set to `""`, so a rerun that finds no token says `already deleted` instead of `token not reachable`. The lookup by name still runs on every rerun; a forged empty id changes only that display line.
- P36 (TASK-2d): `member purge` takes the lease, adds the id to `u/purged.json` (If-Match, else If-None-Match, 3 tries), then deletes the record, so a die between the two leaves the id reserved. It needs no minter (DEC-80 lists none for purge). `member rm` of a removed member refuses `member_not_allowed` naming purge.
- P37 (TASK-2e): `leave` deletes every own pointer the bucket lists (own-origin v:3, `r2_machine`), each proven gone by a GET, before any bytes go; then the service, the record `left`, the keys, the config, and the whole profile root to the Trash (rows, `pub/`, logs). Why not `cmd_rm` per row: it trashes the bytes and the row before the pointer, so a die between them left an orphan pointer no machine reaps after the member is gone (found by DP-leave-1). MB-14's "pointer, then bytes" holds. The member's cloud links stay until they expire, as `member rm --cloud-links keep` does (DEC-1). `leave --local` makes no bucket call; the record and pointers stay for the admin's `member rm`.
- P38 (TASK-2e): member `status` reads its own record once with the publisher pair (`member_status_check`, the same `member_record_read` the loop uses) and writes what it saw to `.health`. A 404 (record gone, for example purged) prints `your member record is gone from <host>; ask the admin` and leaves `state.member.status` alone: a deleted record is a bucket write any publisher can forge, so only a record read as `removed` sets `removed` (DEC-79's rule, applied to 404 as well). A 401 or 403 writes the token verdict `invalid`; `token_state` then reads `expired` when the local `token_expires` is past (DEC-79).
- P39 (the open review TODO, teardown without the admin token): decided as a fix, not a doc note. `t2_refuse` with no settings read (no admin token) now lists `u/` with the bucket pair it already holds and refuses while any record is not `removed` or fails validation. Residual: a forger who also deletes every `u/` record still passes; the admin token closes it (TN-12). The spec's Review finding stays as written (the spec file is outside this sub-goal's Touches).
- P40 (test seam): `SHARE_R2_DRY_AUTH=401` makes every dry bucket call answer 401 (a deleted or expired publisher token).

### Open questions for the operator

- Q3: TASK-2e's Share Bar copy ("You were removed" with Clean up) is TASK-4b17's; this sub-goal lands only `state.member.status` and the `status` lines it reads.
- Q4: MB-30's last clause (after the admin's `renew` the member publishes again with no re-join) needs `member renew` (TASK-3e, SG-08). Not attempted here.

### AC to test map (Phase 2)

| AC row | Test (`mm` labels in tests/members.sh) |
|---|---|
| LK-08, LK-09, LK-10, LK-19, WM-04 | `mm LK-08: ...` (2), `mm LK-09: ...`, `mm LK-10: ...`, `mm LK-19: ...`, `mm WM-04: ...` |
| LK-11, LK-12, Q-OPS-1 | `mm LK-11, Q-OPS-1: ...`, `mm LK-11: ...` (2), `mm LK-12, CK-05: ...`, `mm LK-12: ...` |
| RC-01 to RC-15, LK-16, CK-06 | `mm RC-01: ...` to `mm RC-13: ...` (one each), `mm RC-03, RC-04, LK-16, CK-06: ...`, `mm RC-14: ...`, `mm RC-15: ...` (prune --loop; ls and prune in Phase 1) |
| CC-06, CC-07, CC-08 | `mm CC-06: ...` (3 orders), `mm CC-06, DEC-64: ...`, `mm RC-05, CC-07: ...`, `mm CC-08: ...` |
| CK-02, member sync sweep | `mm CK-02, TASK-2b: ...` |
| FG-01 to FG-04, FG-11, FG-14, FG-16, OC-02 | `mm RC-08, FG-01: ...`, `mm RC-10, FG-02: ...`, `mm FG-03, FG-11: ...`, `mm RC-12, FG-04: ...`, `mm FG-14: ...`, `mm FG-16: ...`, `mm OC-02: ...` |
| TASK-2c, CK-05, OT-02 | `mm TASK-2c: ...` (loop reads its record), `mm OT-02, TASK-2c: ...`, `mm TASK-2c, Q-OPS-1: serve ... env -u CLOUDFLARE_API_TOKEN (NC-loop)` |
| MB-13, Q-SEC-5, OT-11, OT-17, LK-15 | `mm TASK-2d: ...` (order), `mm MB-13, Q-SEC-5 (NC-10): ...`, `mm MB-13: ...` (2), `mm OT-17, DEC-1: ...`, `mm OT-17: ...`, `mm OT-11: ...`, `mm LK-15: ...` |
| MB-16, MB-34 | `mm MB-16: ...` (3), `mm MB-34: ...` (2) |
| FG-15, OT-09 | `mm FG-15, OT-09: ...` |
| DP-rm-1 to DP-rm-8 | `mm DP-rm-1 to DP-rm-8: ...` (kills at steps 1 to 10) |
| CC-04, OT-08, OT-12 | `mm CC-04: ...`, `mm OT-08: a deploy failing 3 times ...`, `mm OT-12: ...` |
| MB-14, MB-15, DP-leave-1 to -3 | `mm MB-14: ...`, `mm MB-15: ...`, `mm DP-leave-1: ...`, `mm DP-leave-2: ...`, `mm DP-leave-3: ...`, `mm TASK-2e: leave on a profile that is not a member ...` |
| MB-21, MB-30, MB-31, OT-03 | `mm MB-21 (a): ...`, `mm MB-21 (b), MB-31, OT-03: ...`, `mm OT-03: ...`, `mm MB-30: ...`, `mm TASK-2e: a record gone (404) ...` |
| review TODO (teardown) | `mm TN-12 (no admin token): ...` |
| NC-1, NC-8, NC-10, NC-14, NC-loop | red runs on mutants of bin/share; green in the suite (`docs/verification/members-rm-reconcile.md`) |

## Audit spec gaps (SG-18): join step 2 split

The delta from the audit-to-spec trace, row 18. Decision record: SPEC-009 DEC-81.

| Decision the spec left open | Choice | Why |
|---|---|---|
| Step names and count | `1 redeem`, `2 unseal`, `3 api-key`, `4 conn-key`, `5 config`, `6 record`, `7 service`, `8 probe`, `9 active` | one write per `op_step`, so `status` names which write a die cut |
| Cloud members at step 4 | the step is journaled and does nothing | a fixed step table keeps `of` and the names the Share Bar shows the same for both modes |
| Resume threshold | `op_prev_step` below 6 refuses `invite_unavailable`; 6 and above resumes (needs `role=member`) | the unsealed bundle is in memory only; from step 6 the config on disk holds what later steps read |
| A cut at step 5 where the config landed but the journal still says 5 | refuses | the journal cannot tell "before" from "after" the write; the admin's new invite recovers it, since a re-join replaces both keys in place |
| Keys a refused cut leaves (steps 4 and 5) | left in the Keychain | bare join has no config, so no host name to forget them by; the re-join replaces them |
| Record `step` of a `joining` record | 6 | it is the journal step, so `member ls` and the journal agree |
| Spec tables | `seq-join`, the status table row `join step 6`, TASK-1h, the DP-join rows, NC-11, and the `join step 3` grep in `mm member_can` all renumbered | the member_can test reads the spec row by its label |
