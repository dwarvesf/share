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
- `hits` on a member does not refuse a machine row. SPEC-007 row 13 pins member `hits` to one account call and no bucket read, and a refusal needs a `GET m/<id>`. The spec test wins over the round-2 build rule. The origin's `hits` of a cloud id reads `m/<id>` first, as row 27 asks. Batch 3 settles the open item (DEC-012): a 0 count on an id outside `r2-own` adds the machine-link line naming the origin's `hits`.
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

### TASK-5 (--alias, the alias rollback list)

- One alias per tenant. A rerun without `--alias` takes the config's `aliases=`, so a redeploy keeps the `ALIASES` binding; a different `--alias` beside a stored one is refused. `--alias` must sit in the tenant's zone (step 14 binds it with that zone's id).
- Step 3 accepts a marker naming the tenant host or the alias, with `aliases` empty or exactly `[<alias>]` (a rerun after step 12).
- Step 4 also accepts the alias's domain already bound to the tenant Worker (a rerun after step 14), and no domain at all (step 14 creates it).
- Step 7 checks Apps Edit (the `{}` probe) only when a gated cloud record exists. An app named `share <id> <host> <nonce>` is not refused: it is a gated cloud link added on the tenant after an earlier fold. Its id is listed in the rollback list as added since the fold.
- Step 10 runs inside the index lock (step 6 to step 11), so a concurrent add can wait out `access_gate`. Only apps whose PUT changed something are probed; a rerun probes nothing.
- Step 12 writes the marker with `If-Match` on the ETag read in step 3. On a fresh bucket the early `{"v":1,"host"}` marker's ETag is kept for it.
- Step 15 waits for three 301 answers in a row, like the other live checks. The step-15 and step-13 dies and the healthz die go through `tenant_die`, which prints the alias list when an alias is folded and `--no-r2` otherwise.
- Step 16 copies the alias profile's `r2-own` lines into this profile's file and leaves the alias profile's own file in place (nothing deleted; D4's teardown removes it).
- The rollback list puts the app destinations first, then the rebind (the round-2 rule), unlike the spec's D3 prose order. It names every cloud id (they answer at the alias again, not at the tenant host) and, apart, the gated ones added since the fold (no app on the alias). It is a list of exact calls, not a command: R1 runs it by hand, and row 30 applies it to the dry account in the suite.
- `--no-r2` now resolves the admin token and reads the marker before its alias refusal, so the refusal can print the list (a marker with `aliases` refuses too).
- A member's join reads the marker's `aliases` once and keeps each one only after `https://<alias>/healthz` answers 301 to the tenant three times; it stores them as `aliases=` in its r2 config. `access_delete` and the purge's by-name pass accept an app named for the host or any stored alias.
- Dry seams: `SHARE_R2_DRY_FAIL` (`API <METHOD> <path glob>`, `PUT <key>`, or `ALIAS-301`) fails one call with no state change; `.cf/script-<worker>.json` answers the settings of a second Worker; the Access dry answers `PUT access/apps/<uuid>`; the dry alias answers 301 once its domain names the tenant Worker and that Worker binds it.

### TASK-6 (one shared list)

- `list_rows` builds the display rows for `ls` and `state`: the local index (typed at read time, `by` from a migrated row's `by=` or `r2_by`), then the bucket through `list_bucket` in a subshell, so any die there becomes `cloud_error` and the local rows still print. Bucket rows live only in that list; `rows()`, `index.tsv`, the Caddyfile, and stage paths never see them. Fields are split by `\x1f`, because bash `read` merges empty tab-separated fields.
- On the origin, `ls` reads the bucket a second time after its prune (the prune runs in a subshell). A member's `ls` reuses the read its prune made.
- `ls` prints `<tag>  <type>  by=<by>  <link>` on the link line (`cloud`, `machine`, or `live`); the detail line keeps its old shape. A member's machine row says `served by the tenant's origin`, and `access=gated` for a gated pointer. A shadowed id lists its local row once. An expired pointer is not listed.
- A cloud record's stored `type` rides into its row as a `type=` token (a record's own `opts` may not carry `type=`, `prefix=`, or `by=`). A record with no valid `type` is typed by its name's extension, and a name with no extension is a `folder`.
- The `v:2` display reader keeps a record only when every field passes (`expires` as `^[0-9]{1,11}$`, `added` as a date, `name` and `by` free of control bytes, `opts` only `noindex`, `live`, `gated`, `type` from the table, an optional `own_host` as a hostname). Pointers now carry `own_host` for a `--host` row (round-2 rule), so a member lists that link at its own name.
- A local folder whose `index.html` is share's generated listing (its first line holds `<title>index</title>`) types as `folder`, not `site`. `type_of` is fork-free (`nocasematch`), so the 500-row `state` stays under its budget.
- `state` (and `profiles --json` through it) reads the bucket only with a stored token: the Keychain item or the 600 file, or the test seam `SHARE_R2_TOKEN`; a profile with `api_token_cmd` or `r2_token_cmd`, or only an environment token, gets `cloud_error` and no command runs. It fetches the newest 25 non-local keys by `LastModified` and reports the rest as `cloud_more`. `SHARE_STATE_BRIEF` (the text `profiles`) reads no bucket.
- New `state` keys: `shares[].storage`, `.type`, `.by`; top-level `r2`, `storage_default` (R2-on origin), `cloud_error`, `cloud_more`. A member's gated pointer reports `access: "gated"`, its live pointer `kind: "live"`.
- Not built: `state` does not report `shadowed` ids (a round-1 warning). It would need a GET of every key the newest-25 rule skips; the origin's `ls` and `prune` already print the shadow line.
- Row 28 checks the rendered Caddyfile and `index.tsv`, not a running Caddy: the dry tenant harness does not serve. The suite's other sections cover the Caddyfile-to-running-config path. The key `m/../share.json` comes from a new dry seam, `SHARE_R2_DRY_LIST_EXTRA`, since a directory-backed bucket cannot hold it.
- Row 1 extends the existing byte-identity run with `profiles --json` and compares after removing the listing additions (the `ls` tag column, the new `state` keys). The named dry setup and the member leg of row 1 are covered by rows 15 and 17 rather than a second `origin/main` run.

## TASK-7a: tar flag measurement (2026-10-01)

Archives built byte by byte (Python `tarfile`, ustar) and by each tar, then listed and extracted on this Mac with bsdtar 3.5.3 (libarchive 3.7.4) and GNU tar 1.35 (Homebrew `gnu-tar`, installed for the measurement):

| Member | `tar -tvf` (bsdtar / GNU) | `tar -xf` (bsdtar / GNU) |
|---|---|---|
| regular file, directory | `-rw-r--r--`, `drwxr-xr-x` on both; the name is the last field | extracted |
| symlink `doc/l -> /var/empty/target` | `l...  ./doc/l -> /var/empty/target` on both | extracted as a symlink on both (exit 0): nothing stops it |
| hardlink to a sibling | `h... ./doc/b.txt link to ./doc/a.txt` on both, for an archive from either tar and for a hand-built one | extracted with a link count of 2 on both |
| hardlink to `/var/empty/target` | bsdtar: `link to /var/empty/target`; GNU: strips the `/` with a warning | both fail to link (exit 1 / 2) and leave the directory |
| absolute member `/tmp/x` | listed as `/tmp/x` on both (GNU warns on stderr) | both strip the leading `/` and extract `tmp/x` inside the target (exit 0) |
| `./doc/../../x` | listed as is on both | bsdtar refuses (`Path contains '..'`, exit 1); GNU refuses the member (exit 2) |
| `./doc/.env` | listed as is | extracted |
| FIFO | `p...` on both | not tried |
| an archive bsdtar makes on macOS | read by GNU tar, it holds `._*` AppleDouble members (and `LIBARCHIVE.xattr` headers) | `COPYFILE_DISABLE=1` with `--no-mac-metadata --no-xattrs` removes them |

Build rules taken from it:

- The pre-scan reads `tar -tf` (names) and `tar -tvf` (types) and refuses the whole import on any line whose mode does not start with `-` or `d`, any ` link to ` or ` -> `, an absolute name, a `..` segment, or a segment starting with `.`; a different line count between the two listings (a name with a newline) refuses too. The listing columns differ between the two tars, so only the first mode character and those two markers are read from `-tv`.
- Extraction flags: bsdtar `--no-same-owner --no-same-permissions --no-xattrs --no-acls --no-fflags --no-mac-metadata`; GNU tar `--no-same-owner --no-same-permissions --no-xattrs --no-acls --no-selinux` (it has no `--no-fflags`). Both sets extract the plain tree unchanged. The flavor comes from `tar --version`.
- After extraction, `find` refuses anything but files and directories and any file with a link count above 1 (the second line of defence for a hardlink the listing missed).
- For TASK-7b: `migrate` builds each tar with `COPYFILE_DISABLE=1` and `--no-mac-metadata --no-xattrs` on bsdtar, or the target's dotfile refusal trips on `._*` members.

### TASK-7a (import, setup --token-stdin)

- `import` takes an optional eighth argument, `<files>:<sha256>`, the round-1 manifest rule: the file count and a sha256 over each file's sha256 and path, sorted (`import_manifest`). A mismatch refuses the import. TASK-7b sends the same digest of `pub/<id>`.
- `import` refuses on a profile that reads a bucket (an R2-on origin or an r2 profile): pointers are not written on that path, and `migrate` moves R2-off tenants only.
- The archive's root must hold exactly the row's name, as `pub/<id>/<name>` does, so the row never points at a path the tar did not bring.
- The candidate row also passes `rows_in`, so an `access=` without its `access_rule=` (or a bad rule) is refused. A gated row keeps its app id; no Access call is made.
- The spool and the stage go through the EXIT trap. Caddy reloads only when the profile is serving; a stopped or `not_setup` profile renders at its next start.
- `refresh` of a row whose `by=` is another machine and whose `src` starts with `<by>:` dies naming that machine.
- `setup --token-stdin` reads one line into the process's own `CLOUDFLARE_API_TOKEN` before any branch runs, so it works for the tunnel setup migrate calls and for `--r2`. An empty line dies before any call. The test drives `--r2` because the suite has no dry seam for the tunnel setup's API path.

