# Proof of done: TASK-1a live samples (SPEC-009)

Date: 2026-11-14
Branch: docs/members-live-samples
Spec: docs/specs/SPEC-009-multi-member.md, TASK-1a (a) to (h)
Answers: docs/implementation-notes/multi-member.md, `## TASK-1a live samples`

Run on the Console Labs account from the Mac Mini. Scripts lived in the session scratchpad and read credentials from 1Password into variables. Tokens went through `-H @<(printf ...)` and `-K <(printf ...)`, never argv, files or output. `<a>` is the account id, `<t>` a tunnel id, `<sid>` a VPC Service id; every hex run of 32 or more is masked as first8…last8.

Throwaway objects: tunnel `share-e2e-1642d005`, VPC Services `share-e2e-1642d005`, `share-e2e-1642d005-a`, `share-e2e-1642d005-e01` to `-e25`, Worker `share-e2e-1642d005` (workers.dev), user tokens `share-e2e-admin-59439714` and `share share-e2e-1642d005 m-e2e-48155d47`.

## Recorded run

```
Command: bash inventory.sh   (listing by name before the run)
Exit:    0
Excerpt: tunnels share-*: [{"name":"share-spike-vpc","status":"down"}]
         vpc services: HTTP 403 {"code":10000,"message":"Authentication error"}   (admin token, no Connectivity scope)
         workers share-*: ["share-spike-vpc"]
         r2 buckets: HTTP 403 {"code":10000}
         user tokens: total 43, share-*: ["share-spike-mint"]
Verdict: PASS (baseline: only the spike objects exist)
```

```
Command: bash mint_admin.sh   (minter POST /user/tokens, Connectivity Directory Admin + Tunnel Write + Workers Scripts Write + R2 Storage Write)
Exit:    0
Excerpt: POST /user/tokens share-e2e-admin-59439714 -> HTTP 200 {"success":true,"id":"4e6e7261…3fee8bf2","expires_on":"2026-11-15T16:14:37Z"}
         value stored in the login Keychain only, deleted at the end
Verdict: PASS
```

```
Command: bash g_a.sh   (g) tunnel + catch-all + token; (a) VPC Service lifecycle
Exit:    0
Excerpt: (g) POST .../cfd_tunnel {name, config_src:cloudflare} -> 200, remote_config true, status inactive
         (g) PUT .../configurations catch-all only -> 200 version 1; empty ingress -> 400 code 1056
         (g) GET .../token -> 200, a 240-char string, base64 JSON keys ["a","s","t"]
         (a) GET .../connectivity/directory/services, admin token -> 403 code 10000
         (a) POST .../services {type:http, name, host:{ipv4, network:{tunnel_id}}, http_port} -> 200 {"service_id":"01a1dad7-…","http_port":18765,"https_port":null,...}
         (a) same name again -> 400 code 5101 "Service name ... already exists"
         (a) GET by id -> 200; list -> 200 no result_info, ?name= ignored
         (a) PUT full body http_port 18766 -> 200; PUT {http_port} alone -> 400 code 5102 "missing field `host`"
         (a) DELETE -> 200; DELETE again -> 404 code 5104; GET deleted -> 404 code 5104
Verdict: PASS
```

```
Command: bash b2.sh; bash b3.sh; bash b4.sh   (b) multipart deploy with a vpc_service entry
Exit:    0
Excerpt: deploy WITH {"type":"vpc_service","name":"M_1642d005","service_id":"<sid>"}, admin token -> 403 code 10196 "Workers VPC binding configuration failed because your credentials are not authorized ..."
         deploy WITH, share-e2e-admin -> 200
         GET .../settings -> bindings [{"name":"HOST","text":"s.console.so","type":"plain_text"},{"name":"M_1642d005","service_id":"<sid>","type":"vpc_service"}]
         deploy WITHOUT the entry (keep_bindings ["secret_text"], absent, []) -> 200; settings ["HOST"]; runtime env ["HOST"] (3 of 3 tries each)
         deploy WITHOUT, admin token -> 200; settings at +0 s and +5 s ["HOST"]
         keep_bindings ["secret_text","vpc_service"], no entry -> settings ["HOST","M_1642d005"]
         one settings GET right after a deploy (b2) returned the pre-deploy list; not reproduced in b4
Verdict: PASS
```

```
Command: bash c.sh   (c) minter mints Bucket Item Write on one bucket + Zone Read; extend; revoke
Exit:    0
Excerpt: POST /user/tokens -> 200 {"name":"share share-e2e-1642d005 m-e2e-48155d47","status":"active","policies":[{"resources":{"com.cloudflare.edge.r2.bucket.e391840e…e998960c_default_share-e2e-1642d005":"*"},"pg":["Workers R2 Storage Bucket Item Write"]},{"resources":{"com.cloudflare.api.account.zone.08d14488…68143028":"*"},"pg":["Zone Read"]}]}
         value 53 chars (not shown); /user/tokens/verify -> {"status":"active"}
         GET /user/tokens?per_page=50 -> result_info {"page":1,"per_page":50,"total_pages":1,"count":45,"total_count":45}; the row matched by name, keys id,name,status,issued_on,modified_on,expires_on,not_before,last_used_on,policies
         PUT /user/tokens/<id> full body +1 d -> 200; PUT {expires_on} alone -> 200, policies kept 2; verify -> active, same secret
         DELETE -> 200; DELETE again -> 404 code 1003 "token not found"; verify after -> 401 code 1000
         S3 PUT If-None-Match:* -> curl 35 TLS handshake failure (R2 not enabled on the account)
Verdict: PASS for mint, find by name, extend, revoke. S3 leg not run here; covered by docs/verification/r2-e2e-2026-10-01-final.txt (same minter, bucket-scoped tokens, PUT m/<id> If-None-Match, 84/84 PASS)
```

```
Command: bash b.sh   (R2 bucket for (c) and (h))
Exit:    0
Excerpt: POST /accounts/<a>/r2/buckets -> 403 {"code":10042,"message":"Please enable R2 through the Cloudflare Dashboard."}
Verdict: BLOCKED (R2 is not enabled on Console Labs)
```

```
Command: bash def.sh; bash d2.sh; bash d6.sh   (d) binding fetch with the origin down; (f) connections shape
Exit:    0
Excerpt: all up -> 200 served=caddy 162 to 199 ms; Caddy 404 passes as 404
         Caddy stopped -> throw "Error: ProxyError: connection_refused" 108 to 624 ms
         python http.server -> 200 / 404, server SimpleHTTP, served=null
         cloudflared stopped -> throw "ProxyError: destination_not_found" 226 to 512 ms; at +20 s and +60 s "ProxyError: destination_unavailable" 19 to 25 ms
         both down -> throw destination_unavailable 13 ms
         accept-and-never-answer listener -> no answer, client timeout at 120 s
         same with AbortSignal.timeout(5000) / (10000) -> "TimeoutError: The operation was aborted due to timeout" at 5000 / 10000 ms
         (f) GET .../connections, one cloudflared -> 1 entry, conns 4, conn keys client_id,client_version,colo_name,id,is_pending_reconnect,opened_at,origin_ip,uuid
         (f) GET .../cfd_tunnel/<t> -> {"status":"healthy","connections":4}; ?name= -> connections 4
         (f) GET .../connections after cloudflared stopped -> 0 entries
Verdict: PASS
```

```
Command: bash e.sh   (e) 25 vpc_service bindings on one Worker
Exit:    0
Excerpt: 25 services on one tunnel, ports 18782 to 18806, created in 12 s
         (same tunnel, ipv4 and port twice -> 400 code 5101 "Service already exists for port https:18781 on 127.0.0.1")
         list ?per_page=10 -> 10; &page=2 -> 10 starting at -e15; no params -> 27; result_info null
         deploy 20 bindings -> 200 884 ms; settings 20; routed 20 x 200 served=caddy, 0 other
         deploy 25 bindings -> 200 997 ms; settings 25; routed 25 x 200 served=caddy, 0 other
         DELETE a service still bound -> 200; route through it right after -> 200 served=caddy
         redeploy naming the deleted service -> 400 code 10180 "VPC Service '<sid>' not found"
         24 remaining services deleted -> 200 each (the first: 404, already deleted)
Verdict: PASS
```

```
Command: wrangler dev --local (workerd, wrangler 4.133.0) + GET /h   (h) R2 put with a stale onlyIf.etagMatches
Exit:    0
Excerpt: {"first_etag":"f97c5d29…4906ab82","matching_put":"R2Object etag b8a9f715…6c820a61","stale_put":"null","final_body":"two"}
Verdict: PASS on the local runtime; the live production sample is BLOCKED by R2 being off and moves to the first R2 run on Console Labs (SG-11)
```

```
Command: bash cleanup.sh   (f) teardown order, then delete every share-e2e-* and spike object by name
Exit:    0
Excerpt: DELETE .../cfd_tunnel/<t> while connected -> 400 code 1022 "This tunnel has active connections ..."
         DELETE .../connections -> 200; GET .../connections -> 0
         DELETE Worker share-e2e-1642d005 -> 200; DELETE Worker share-spike-vpc -> 200
         DELETE .../cfd_tunnel/<t> while a VPC Service still names it -> 200
         DELETE service share-e2e-1642d005 -> 200; DELETE service share-spike-vpc -> 200
         DELETE connections + tunnel share-spike-vpc -> 200, deleted_at 2026-11-14T16:30:44Z
         DELETE user token share-spike-mint -> 200
Verdict: PASS
```

```
Command: bash final.sh   (listing by name after the run; then the throwaway admin token goes)
Exit:    0
Excerpt: vpc services named share-e2e-*|share-spike-* -> []   (listed with share-e2e-admin before its delete)
         DELETE user token share-e2e-admin-* -> 200; Keychain item share-e2e-admin left: no
         tunnels named share-e2e-*|share-spike-* -> []
         workers named share-e2e-*|share-spike-* -> []
         user tokens named share-e2e-*|share-spike-*|share share-e2e-* -> [] (total 42)
         r2 buckets -> 403 (R2 not enabled; no bucket was ever created)
Verdict: PASS (no share-e2e- object and no spike leftover on Console Labs)
```

No process of the run is left: `pgrep` after each script found no cloudflared, Caddy, python or wrangler process started by it.

## UAT

Live on Console Labs, 2026-11-14: (a), (b), (d), (e), (f), (g) ran against production Cloudflare and are accepted. (c) ran live for mint, find, extend and revoke; its S3 leg is accepted on the 2026-09-30 live run. (h) ran on the local workerd runtime only and is accepted as provisional; the live check is owed by SG-11.

## Rollback

Nothing to roll back in the repo: the change is documentation only. On Cloudflare every object this run made is deleted. The spike objects (`share-spike-vpc` tunnel, VPC Service and Worker, user token `share-spike-mint`) are deleted by the owner's approval (D11) and cannot be restored; the spike record `docs/research/2026-11-13-multi-member-spikes.md` holds their shapes.
