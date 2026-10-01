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
