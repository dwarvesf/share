# One hostname per tenant: implementation notes

The delta from SPEC-008 for the builder. Spike answers (TASK-1a, TASK-1b, TASK-7a's tar step) land here too.

## Validation warnings carried to the build

Round 1 warnings the spec did not fold. Each one is a build rule unless a task's spike answer overrides it.

| Warning | Build rule | Task |
|---|---|---|
| Every request to an R2-on tenant runs the Worker plus one bucket read; dev-server HMR multiplies both | measure live-link request volume in L3; if it matters, memo "machine or miss" per id in the Cache API for a few seconds; add a Worker-requests or Class B threshold to the vps-mon catalog | TASK-3, TASK-9a |
| The route fails closed at the Workers request limit, taking machine links down | TASK-1b(k) reads the plan; on a free plan set the route to fail open (Caddy 404s cloud ids, edge Access still gates) | TASK-1b, TASK-4 |
| A publisher token reaching its `expires_on` silently blocks local adds on an R2-on origin | `api-token --check` warns 14 days ahead; vps-mon expiry coverage for the origin token | TASK-2, TASK-11a |
| `setup --r2` holds no index lock while pointers backfill | take the index lock from step 6 through step 11, so a concurrent local add waits and then writes its pointer | TASK-4 |
| A dry trace exists for one negative control only | write the dry trace for each control into the verification record as it goes red | TASK-10 |
| A tar truncated at a member boundary can publish a partial tree | `migrate` sends a per-id file count and sha256 manifest; `import` verifies it before publishing; the rerun skip compares the manifest | TASK-7a, TASK-7b |
| A member could take a machine link's URL by deleting its pointer and writing a cloud record (accepted trust, SPEC-007 DEC-011) | `state` reports `shadowed` ids so Share Bar can show them | TASK-6 |
| The migrate switch token can be broad if TASK-1b(i) picks the Toolkit token | prefer a run-scoped one-day token for the switch | TASK-11b |
| The Worker's `//` and low-escape 400s now cover live dev-server paths too | document it in how-it-works; scope them to cloud ids only if a real dev server needs `//` | TASK-3, TASK-10 |
| `brew pin` is no downgrade | the D1 and P1 rollback is an install of the previous tag from the tap's git history | TASK-11a, TASK-11b |
| After P2 nothing watches `s.han.ws` | add `s.han.ws/healthz` to vps-mon in TASK-11b | TASK-11b |
| After P2, a local restore on the Air (rows from `index.migrated`, trees from `migrated/`) has no command | rehearse the manual restore once in R2 and write it into the verification record | TASK-9b |
| `--alias` adds permanent surface for a one-time fold | keep the alias code small and covered; it retires with the alias rollback and `--no-r2` | TASK-5 |

Round 2 warnings, same rule:

| Warning | Build rule | Task |
|---|---|---|
| A D3 rollback breaks cloud links added after the fold | the alias rollback list prints the cloud ids added since the fold, so Han re-adds or warns first | TASK-5 |
| Teammates still joined at `f.d.foundation` are not told | D4 lists the bucket's `by` values and tells each to rejoin at `s.d.foundation` | TASK-11a |
| `migrate` holds no index lock; an add on the old origin mid-run is never moved | hold the index lock from step 1 to step 5, or re-diff the index before retiring and stop on new rows | TASK-7b |
| `migrate` on a laptop can sleep mid-retire | run under `caffeinate -i` on macOS; make the retire idempotent on rerun | TASK-7b |
| The 2 GiB import cap has no override | the preflight lists over-cap ids; add `--max-bytes` | TASK-7b |
| A fresh-bucket `setup --r2` can die between pointers and the marker | write `share.json` before step 9 when the bucket is new; add a fresh-bucket variant of row 11 | TASK-4 |
| A slow R2 adds up to 2 s to every machine request | add a failure-mode line with Worker wall-time as the signal; consider a lower read cap after L3 measures it | TASK-3 |
| A DELETE-then-PUT rebind can leave NXDOMAIN cached past the API gap | TASK-1b(f) measures through a public resolver queried during the gap | TASK-1b |
| A die at steps 9 or 10 with `--alias` leaves `v:2` pointers that block a v0.8.0 member's sweep | that die names the rerun or the pointer cleanup | TASK-5 |
| The Mini carries both tenants; a reboot stalled at the login window takes both down | vps-mon `healthz` on both hostnames is the signal; state it in the failure table of the ADR | TASK-10, TASK-11b |
| `hits` of a machine row on a member is unspecified; members see `--host` rows at the wrong URL | `hits` on a member refuses a machine row; pointers carry an `own_host` display field | TASK-2b, TASK-6 |
| The member purge is undefined on a tenant (route, not custom domain; machine rows refused on members) | a member purge refuses while the Worker binds `PASS="1"`; the origin runs `--no-r2` first; tenant purge order is route, pointers, records, script, bucket | TASK-4 |
| The migrate gated check needs Access read; the old origin's tunnel name may be missing | step 4 uses the old origin's stored Access token; preflight reads `tunnel_name` from the API by `tunnel_id` when the key is absent | TASK-7b |
| bsdtar lists a hardlink as a regular mode with `link to`; archive flags can pin files | the pre-scan rejects any `link to`; extract with no file flags or xattrs; row 18 gains a sibling hardlink and an absolute one | TASK-7a |
| Pointers expose every machine link's URL to every member | `docs/setup.md` says so in the onboarding | TASK-10 |
| The D3 rollback rebinds before restoring app destinations | restore destinations first, then rebind | TASK-5 |

## TASK-1a: edge spike (2026-10-01)

Throwaway objects on the Dwarves account, all created with the Toolkit admin token: hostname `share-e2e-spk584462.d.foundation` (proxied CNAME to tunnel `share-e2e-spk584462`), a route Worker of the same name on `<host>/*`, a service token, and one Access app on `<host>/gated{,/*}` with a `non_identity` service-token policy plus an email include (so an unauthenticated browser gets 302, not 403). The origin ran on the Mini: `cloudflared tunnel run` (token from the environment) to Caddy on 127.0.0.1:28990, which proxied to a node echo server that logged every request it received and spoke a WebSocket echo. The spike Worker answered 418 `REENTERED` for any request carrying `x-spike-pass`, answered `/__w` itself, fetched `https://<HOST>/healthz` on `/__hz`, and otherwise ran `fetch(request)`; `?mark=1` cloned the request with `x-spike-pass: 1` first, and `x-spike-raw: 1` returned the subrequest's status and headers as JSON. Every probe used `curl --doh-url https://1.1.1.1/dns-query`.

| Q | Command (shape) | Observed |
|---|---|---|
| (a) | `GET https://<host>/abc123/f?x=1` | 200 with `x-spike-worker: 1` and `x-origin: 1`; the origin logged the request with `cf-worker: d.foundation` |
| (a) | `GET https://<host>/abc123/f?mark=1` | 200 from the origin, which logged `x-spike-pass: 1`; no 418, so the subrequest skipped the route Worker |
| (a) | `GET https://<host>/__hz` (Worker fetches `https://<HOST>/healthz` with `x-spike-pass`, `AbortSignal.timeout(3000)`) | `{"status":200,"body":"ok","reentered":null}`; the origin logged `GET /healthz` |
| (b) | unauthenticated `GET /gated/x`, `/gated/__w`, `/gated` | 302 to `https://dwarves.cloudflareaccess.com/cdn-cgi/access/login/<host>?kid=<AUD>`, `kid` equal to the app's AUD; no `x-spike-worker` header on any; the origin log stayed empty, and `/gated/__w` (answered by the Worker itself) also got the 302, so Access runs before the route Worker |
| (b) | `GET /gated/__w` with `CF-Access-Client-Id`/`-Secret` | 200 from the Worker, `{"worker":true,"jwt":true,"cookie":true}`: the admitted request carries `Cf-Access-Jwt-Assertion` and a `CF_Authorization` cookie |
| (b) | the same with a wrong secret | 302 to the login flow, never admitted |
| (c) | `GET /gated/x` with the service token | 200 from the origin; the origin logged `jwt=1` and `cookie` present: `fetch(request)` forwards the JWT and the cookie |
| (d) | `POST /live/api` with 100000 random bytes; `PUT`; `DELETE` | 200 each; the origin logged `POST body=100000`, `PUT body=1`, `DELETE` |
| (d) | node 22 `new WebSocket("wss://<host>/live/ws")`, send `ping1` | `["hello-from-origin","echo:ping1"]`; the origin logged `UPGRADE /live/ws cfworker=d.foundation`; the Worker returned the 101 response object as is |
| (d) | the same on `/gated/ws` without, then with, the service token | without: handshake refused (non-101); with: echo works, the origin logged `jwt=1` |
| (e) | Caddy up, `/dead/x` proxied to a closed port (Caddy answers `502`, `Server: Caddy`, empty body, checked locally) | the Worker's subrequest sees `502` with Cloudflare's own HTML page (`<title>d.foundation \| 502: Bad gateway</title>`), `server: cloudflare`, `retry-after: 60`, no `cf-cache-status` |
| (e) | Caddy `respond "caddy 502 with body" 502` | the same Cloudflare 502 page; Cloudflare replaces every origin 502, body or not |
| (e) | Caddy stopped, cloudflared up | `502`, the same Cloudflare page and headers as above; `/__hz` got `502 error code: 502` |
| (e) | cloudflared stopped | `530` (`error code: 1033`, the Cloudflare Tunnel error page) to both the pass-through and `/__hz`; `retry-after` present, no `cf-cache-status`; the client saw the 530 through the Worker |
| (e) | Caddy `respond "caddy 503" 503`; Caddy `respond 404`; the node origin's own `503` | `503` with body `caddy 503` and `cf-cache-status: DYNAMIC`; `404` with `cf-cache-status: DYNAMIC`; `503` with `cf-cache-status: DYNAMIC` and `via: 1.1 Caddy` |

Answers:

- (a) holds: a route Worker's `fetch(request)` and its `fetch("https://<HOST>/healthz")` both reach the tunnel origin and never re-enter the Worker. Approach (A) stands.
- (b) holds: Access answers an unauthenticated gated path with its 302 before the route Worker runs; an admitted request reaches the Worker with `Cf-Access-Jwt-Assertion`.
- (c) holds: the pass-through keeps the JWT header and the `CF_Authorization` cookie.
- (d) holds: POST, PUT, DELETE with bodies and a WebSocket upgrade pass through; `return r` on a 101 is enough.
- (e) the pass-through sees 530 with the connector down and 502 with the connector up but nothing answering. An origin's own 502 never reaches the Worker: Cloudflare swaps it for its own page, so a Caddy 502 and an edge 502 look the same and both get the offline page (as the spec wants). The header that tells an origin answer apart is `cf-cache-status`: present on every response the origin produced (503, 404, 200), absent on every edge-generated error (502, 530). `via: 1.1 Caddy` appears only on responses Caddy proxied, so it is not a general marker. Build rule for TASK-3: offline page when the status is 530, 520 to 527, or 502; or 503 without `cf-cache-status`. Not measured: 520 to 527 and an edge-generated 503 (no way to force them with a tunnel origin); the rule keys them on the same header.

Side findings for later tasks:

- A route object carries `request_limit_fail_open` (default `false`); `PUT zones/<z>/workers/routes/<id>` with `true` was accepted and read back. TASK-1b(k) uses this.
- After the DNS record was deleted, the authoritative server answered NXDOMAIN at once, while 1.1.1.1 still served its cached proxied A records (the edge answered 530) until the TTL ran out.

Cleanup, checked through the API afterwards: route 0, Worker settings 404, DNS records for the name 0, Access apps and service tokens named `share-e2e-spk*` 0, tunnels named `share-e2e-spk*` (not deleted) 0, no spike process left on the Mini; `dig @david.ns.cloudflare.com <host>` NXDOMAIN.

## TASK-1b: account spike (2026-10-01)

Throwaway objects: a token `share-e2e-spk13b60d-admin` minted through `op://Toolkit/cf-tokens-admin` (`POST /user/tokens`, one-day `expires_on`) with the tenant admin set (account: Workers Scripts Edit, Workers R2 Storage Edit, Access Apps and Policies Edit, Access Organizations Read; zone `d.foundation`: Zone Read, DNS Read, Workers Routes Edit); Workers `share-e2e-spk13b60d-a` and `-b` (each answers `w1` or `w2`); custom domain `share-e2e-spk13b60d.d.foundation`; one Access app; on the personal account one tunnel and one CNAME `share-e2e-spk13b60d.han.ws`. The minted token ran the deploys, the first bind, the refused in-place PUT, the DELETE then PUT of the first pass, and every (g) call; the Toolkit token ran the `override_existing_origin` passes, the timed DELETE then PUT, (i), and the cleanup. Edge probes: node 22 `fetch` every 100 ms with keep-alive (about 160 ms per sample), plus `dig` against 1.1.1.1 and the zone's authoritative server every 200 ms during the first pass.

| Q | Command (shape) | Observed |
|---|---|---|
| (f) | `PUT accounts/<a>/workers/domains {hostname, service:"-b", zone_id, environment:"production"}` while the hostname is bound to `-a` | refused: `success:false`, code `100116`, "Hostname ... already in use by other custom domain. Either delete it, try a different hostname, or use the option 'override_existing_origin' to override."; the binding stays on `-a` |
| (f) | the same PUT with `"override_existing_origin":true`, three times (`-a` to `-b`, back, again) | `success:true`, same domain id, `service` switched; 308 samples over 50 s, 0 non-200; the new Worker answered 1.1 s, 1.1 s, and 3.6 s after the PUT returned |
| (f) | `DELETE workers/domains/<id>`, then the plain PUT to `-a` | DELETE 200, PUT 200 (same domain id came back); the old Worker kept answering about 1.1 s after the DELETE returned, then 4 samples of `522` over 0.7 s, then `w1`; total failed window under 1 s; 210 samples, 4 non-200 |
| (f) | `dig @1.1.1.1` and `dig @<ns>.ns.cloudflare.com` on the hostname during the first DELETE then PUT | `NOERROR` on every sample, never `NXDOMAIN`: the domain's DNS record outlives the API gap, so no negative cache forms |
| (g) | `POST access/apps` with destinations `<host>/ab12cd{,/*}`, then `PUT access/apps/<uuid>` with the full `GET` result plus two destinations on `x.<host>` | `success:true`; `aud` and `id` unchanged; four destinations; `self_hosted_domains` follows the destinations; policies unchanged (only their `updated_at` moved) |
| (g) | `PUT access/apps/<uuid>` with only `name`, `type`, `destinations` | `success:true`, `aud` unchanged, the policy kept, but `app_launcher_visible` went from `false` back to the default `true`: a PUT resets every field it omits |
| (h) | the Toolkit token's id from `GET /user/tokens/verify`, its policies through the minter (`GET /user/tokens/<id>`) | token `all-wuandkin-admin`, no expiry, four accounts; on the Dwarves account: Workers Scripts Write, Workers R2 Storage Write, Workers Routes Write, DNS Read and Write, Zone Read, Access: Apps and Policies Write, Access: Organizations Read, Cloudflare Tunnel Write, Account Analytics Read (zone groups on `zone.*`). TASK-1a already used it for the route POST, PUT, DELETE and the Access app POST, DELETE |
| (i) | with the Toolkit token on the personal account: `POST cfd_tunnel`, `PUT .../configurations`, `GET .../token`, `POST zones/<han.ws>/dns_records` CNAME, `PUT` of that record, both DELETEs | every call `success:true`; the same token policy covers the personal account with Cloudflare Tunnel Write and DNS Write |
| (k) | `GET accounts/<a>/subscriptions` on both accounts; `GET zones/<z>/workers/routes` | Dwarves LLC: `Workers Paid`, `R2 Paid`; Han Ngo: `Workers Paid`, `R2 Paid`, Analytics Engine; both zones `Free Website`. Every route object carries `request_limit_fail_open` (both existing routes `false`); TASK-1a set it to `true` with a route PUT and read it back |

Answers:

- (f) The plain PUT never rebinds. `PUT workers/domains` with `override_existing_origin: true` rebinds in place with no failed request at a 160 ms sample rate, so step 14 uses it and no gap exists to bound. DELETE then PUT costs under 1 s of 522 and never NXDOMAIN; it stays the fallback only if the override flag ever stops working.
- (g) A PUT keeps the AUD, the id, and the policies when it sends the full `GET` result. It resets any omitted field to its default, so step 10, step 16, and the alias rollback must PUT the full read-back with only `destinations` changed.
- (h) Yes. The Toolkit token holds Workers Routes Edit and Access Apps Edit on the Dwarves account, plus every other scope of the tenant admin set. The admin role uses it. It is broad (four accounts, no expiry); the minted one-day token with only the tenant admin set also ran every (f) and (g) call, so the run-scoped fallback in the token table works.
- (i) Yes. The Toolkit token edits tunnels and DNS on the personal account. The round-1 warning still prefers a run-scoped one-day token for the migrate switch (TASK-11b).
- (k) Both accounts are on Workers Paid, so no daily request limit applies and the route never hits the free plan's failure mode. TASK-4 sets `request_limit_fail_open: true` on the route anyway: it costs nothing on a paid plan and keeps machine links up if an account ever drops to free.

Cleanup, checked through the API afterwards on both accounts: Workers, custom domains, Access apps, service tokens, tunnels, routes, and DNS records with names starting `share-e2e-spk` all 0; buckets starting `share-e2e` 0; user tokens starting `share-e2e-spk` 0 and the minted token's id answers 404; `dig` at each zone's authoritative server answers NXDOMAIN for both throwaway names.

## Build deltas

Deviations from the spec, per task. A task with none is not listed.

### TASK-2a (per-link storage on the origin)

- An origin with R2 on is a tunnel profile whose config holds `bucket=`; the process flag `r2on` keys every bucket call (`r2_call`), the dry log (`dry_log` writes `r2-calls.log`, so one log orders bucket PUTs, probes, and Access calls), `rand_id`'s bucket leg, and `api-token`'s publisher refusals. `backend` stays the tunnel, so a cloud add on the origin runs `cmd_add_r2` unchanged; `share_url` reads `r2_link_base` whenever it is set, and the origin keeps its own `r2-own` file.
- `--cloud` with a port or `--host` dies with `--cloud: live links and --host stay on the origin's tunnel` on every tunnel profile, R2 on or off, before the R2-off line. `--cloud --local` is the usage line. A bad `storage_default` dies naming the config.
- A local add on an R2-on origin runs `r2_token_check` before `rand_id`, so no token means no stage, no id, no write.
- The pointer PUT retries a 412 with a fresh `rand_id` up to five ids, then dies. The `type` is `site` for a live link, else the source's type.
- Cloud records written by `cmd_add_r2` now carry `type` too (the spec's "new cloud records store `type` at add time"); `v:1` readers ignore it.
- `rm` deletes the pointer only after a `GET m/<id>` shows `v:2` with `storage:"machine"`: a cloud record on the same id (a shadow) is never deleted from the origin. Token modes: `rm` and bare `prune` use the soft resolver; `ls`'s listing prune only an environment token; serve's hourly prune never. An admin token from the environment counts as no token there (its `r2_publisher_check` refusal is probed in a subshell), so a listing never dies on it.
- `api-token` on an R2-on origin: `--cmd`, the paste, and `--check` run `r2_publisher_check`; the paste names the bucket scope beside the prefilled Access form; `access_preflight` stays required. Not built yet: the 14-day `expires_on` warning (round-1 warning), left for TASK-11a's token work.
- Test seams: `SHARE_R2_DRY_PUT=500` (every PUT answers 500), `SHARE_R2_DRY_PUT=race-once` (the first conditional PUT of an `m/` key finds a peer's record written just before it, so `If-None-Match: *` answers 412), and `SHARE_R2_DRY_PAUSE` now drops `.paused` in the dry bucket, so row 4 inspects `pub/` while the pointer PUT is held instead of racing a watcher.
- Left for TASK-2b: on the origin, `rm`, `refresh`, and `hits` of a cloud id still read the local index only (`no share with id`).

### TASK-2b (dispatch, reconcile, sweep, origin cloud expiry)

- Fixes TASK-2a's leftover: on an origin with R2 on, `rm`, `refresh`, and `hits` of an id with no local row take the r2 path. A local row wins on a shadowed id.
- The bucket reader is `r2_read`: one mktemp file per process (`r2_snap_file`), read through `crows`; it never assigns or writes `$index`. `r2_snapshot` (members) is `r2_read` plus the old `index` rebind. `cmd_rm_r2` and `r2_prune` read and rewrite the reader's file only. Keys outside `^m/[0-9a-f]{6}$` are dropped before any GET, on members too.
- `hits` on a member does not refuse a machine row. SPEC-007 row 13 pins member `hits` to one account call and no bucket read, and a refusal needs a `GET m/<id>`. The spec test wins over the round-2 build rule; a member's `hits` of a machine id prints the Analytics count (0: the Worker counts no pass-through). The origin's `hits` of a cloud id reads `m/<id>` first, as row 27 asks.
- A member's `rm` and `refresh` of a machine row die after the read that identifies the row (the snapshot for `rm`, `GET m/<id>` for `refresh`) and before any write.
- No add lock existed. `r2_pointer_put` now takes `.lock-add-<id>` before the pointer PUT; `cmd_add` releases it after the row write, the EXIT trap on a die. The reconcile skips an id whose lock names a live pid.
- The origin's interactive pass runs in a subshell before the local expiry: cloud expiry, the orphan sweep (bare prune only, as SPEC-007), then the reconcile. A bucket failure prints one line and the local expiry still runs. The reconcile skips expired local rows (the local prune's) and prints its shadow and backfill lines on stderr. `access_sweep` runs once, in `cmd_prune`.
- `r2_record_raw` reads the cloud shape as `v:1` exactly instead of `v <= WORKER_RECORD_V`, so TASK-3's bump to 2 keeps a `v:2` record without `storage:"machine"` unreadable for the sweep.
- A member's bare prune and `ls` delete a machine pointer whose `expires` is past (pointer rule 3).
- The 14-day warning: `api-token` (`--check`, the paste, `--cmd`) on an r2 member and on an R2-on origin reads `expires_on` from `/user/tokens/verify` and warns at 14 days or fewer, or once expired. Not on every add (`r2_key_id` in the config skips the verify call there). Test seam: `SHARE_R2_DRY_EXPIRES`.


### TASK-3 (Worker v3, r2_healthz)

- The method rule: with `PASS` empty the Worker keeps SPEC-007's early 405 for any method but GET and HEAD, so SPEC-007 rows 17 to 19 and 28 run unchanged. With `PASS` set, the 405 applies only to what the Worker answers itself (`/healthz`, a cloud record, after its record and JWT checks); a pass-through takes any method.
- The record branches read `v == 1` with no `storage` key as a cloud record and `v == 2` with `storage == "machine"` as a pointer; everything else (a missing `v` included, which SPEC-007's `v > 1` test let through) answers 404 and never passes through.
- The offline page also answers a thrown `fetch`. Its body is plain text with `Content-Type: text/plain; charset=utf-8`.
- Hits: a pass-through is marked in a `WeakSet` and the outer handler returns it untouched, so no data point is written and a 101 keeps its `webSocket`.
- `r2_healthz` reads one header file for both the live call and the dry seam (`SHARE_R2_DRY_HEALTHZ=tunnel-down` and `503-bare` write the 503 a tenant Worker sends with and without its headers), and strips the status line's carriage return.
- `tests/worker.mjs`'s stub origin returns a real `Response` whose `headers` throw on `set`, `append`, and `delete`. Node unrefs `AbortSignal.timeout`'s timer, so the hang case keeps the event loop alive with its own timer.
- Not measured or built: the slow-R2 2 s cap has no test row (only the throw); the Cache API memo and the Worker-wall-time failure line from the round-1 and round-2 warnings wait for L3's numbers (TASK-9a).

### TASK-4 (setup --r2, --no-r2, no alias)

- `--alias` is not parsed yet (TASK-5); `setup <host> --r2` takes `--bucket`, `--storage-default`, and `--force` (a Worker version downgrade, as SPEC-007). A rerun keeps the stored `storage_default` unless the flag is given.
- Step 1 adds two refusals: a profile whose config holds another bucket (`--no-r2` first), and an origin that is not serving (`share start` first), since step 15 probes a file through the tunnel. The dry seam skips the probe and logs `TUNNEL-PROBE`.
- Step 3 keeps SPEC-007 step 7 (`GET access/organizations`) so the tenant Worker's `TEAM` binding serves gated cloud links; it runs after the routes read.
- Step 5 refuses any route whose host part (a glob) matches the tenant host and names another script, narrower patterns included, not only `<host>/*` and wider ones.
- Step 6 runs only on an existing bucket; on a new one the bucket POST and the `{"v":1,"host"}` marker PUT come before the Worker deploy and every pointer (the round-2 fresh-bucket rule). The index lock is held from step 6 through step 11. Residual: an add that read its config before step 11 writes no pointer; the next reconcile writes it.
- Step 9 skips an id that already holds this origin's machine pointer (the rerun's convergence); a 412 on any other id dies before the route.
- Step 13 PUTs `request_limit_fail_open: true` onto an existing route of this Worker that lacks it; a rerun with the flag set attaches nothing.
- The step-15 die names the leg (Worker or tunnel) and the `--no-r2` rollback.
- `write_config` (a tunnel setup rerun on the origin) keeps the four tenant keys, so a rerun never turns R2 off in the config while the route stays.
- `--no-r2` refuses while the config's `aliases=` is set; the marker's `aliases` and the printed rollback list wait for TASK-5.
- SPEC-007's admin path now reads `zones/<z>/workers/routes` before its DNS read; a 403 there passes (round-3 rule), any other non-200 dies. A member purge refuses a Worker that binds `PASS="1"` (round-2 rule). The origin-side purge of a tenant (route, pointers, records, script, bucket) is not built.
- Round-3 rule on a marker field that v0.8.0's admin setup refuses: v0.8.0 checks the marker with one test (`.v == 1 and .host == <host>`) for both roles, so any field that fails its admin path fails its join too. None was added; D1's check that every machine holding the admin token runs the release stays the guard.
- Dry seam: `zones/<z>/workers/routes` GET, POST, PUT, DELETE on `.cf/routes.json`; `SHARE_R2_DRY_ROUTES=deny` answers 403; the dry `/healthz` answers through a route as well as a custom domain and adds `x-share-tunnel: 1` for a `PASS` Worker.
