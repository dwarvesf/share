# R2 backend: TASK-1 spike results

Spike ran on throwaway objects in the Dwarves LLC account: bucket
`share-spike-gy4op3` (plus `share-spike2-gy4op3` for the cross-bucket check),
Worker `share-spike-gy4op3` on custom domain `share-spike-gy4op3.d.foundation`,
an Access app, a service token, and five scoped API tokens minted through
`POST /user/tokens` by a token-admin credential. All deleted at the end.

Consequence up front: **(a) fails on the REST object path**, so per DEC-002 the
transport is `curl --aws-sigv4 "aws:amz:auto:s3"` against
`https://<account>.r2.cloudflarestorage.com/<bucket>/<key>`, access key = the API
token's id, secret = `sha256(token)` computed from stdin. Every "REST" answer
below is recorded because (c) and the rate limit also differ between the paths.

## (a) Permission groups, bucket-scoped token

Minted `POST /user/tokens` with
`policies:[{effect:"allow", permission_groups:[{id:"2efd5506f9c8494dacb1fa10a3e7d5b6"}], resources:{"com.cloudflare.edge.r2.bucket.<acct>_default_<bucket>":"*"}}]`
(`2efd5506f9c8494dacb1fa10a3e7d5b6` = "Workers R2 Storage Bucket Item Write";
docs say Write covers read, write, and list of objects; `6a018a9f2fc74eb6b293b0c548f38b39` = Item Read).

| Call | Answer |
|---|---|
| REST `PUT/GET/DELETE objects/<key>`, `GET objects?` | 403 on every one |
| REST `GET r2/buckets` | 403 `code 10000 "Authentication error"` |
| `GET workers/scripts/<w>/settings` | HTTP 403 (same for a missing script) |
| REST `POST r2/buckets` (bucket create) | 403 |
| S3 `PUT` `GET` `DELETE` `?list-type=2` on the spike bucket | 200/204, works |
| S3 any op on `share-spike2-gy4op3` | 403 on every one |
| S3 `PUT` with `If-None-Match: *` on an existing key | 412 |

So: the REST object path is unusable for publishers (it needs the account-wide
`Workers R2 Storage` scope that reaches `payout`, `invoice`, `dataroom-kyc-evidence-prod`); the S3 path is bucket-scoped correctly. `GET r2/buckets` answering 200 is also the account-wide-token detector for `share api-token` (a bucket token gets 403). Join detection holds: a publisher token gets HTTP 403, not 404, on `workers/scripts/<w>/settings` (round-3 warning settled). Token minting needs `API Tokens` edit: the Toolkit token gets 9109 on `POST /user/tokens`, `POST /accounts/<a>/tokens`, and `GET .../tokens/permission_groups`; `POST /accounts/<a>/tokens` is denied even for a token-admin credential, `POST /user/tokens` works.

## (b) List pagination

- REST `GET .../objects?per_page=1`: `result_info: {cursor, is_truncated, per_page}`; next page via `?per_page=N&cursor=<uri-encoded cursor>`. `result_info` was `null` only when the listing fit one page in earlier probing; with >1 page it carries the cursor.
- S3 `?list-type=2&max-keys=N&encoding-type=url`: `<IsTruncated>` + `<NextContinuationToken>`; next page via `continuation-token=<uri-encoded token>`; `<Key>` values come url-encoded when `encoding-type=url` (`m%2Fs1`, `a%25b.txt`).

## (c) Conditional writes

REST PUT ignores all of `If-None-Match: *`, `If-Match: <etag>`, `x-amz-if-none-match`, `?if_none_match=*` (every probe answered 200 and overwrote; the query param became a literal key `m/t2?if_none_match=*`). **S3 honors them**: `If-None-Match: *` on an existing key -> 412, `If-Match: "<etag>"` -> 200 with the real etag and 412 with a wrong one. `--access` and `refresh` keep their atomic publish on S3.

## (d) Key encoding

REST: PUT `objects/<urlenc(key)>` stores the decoded key; list returns raw keys (`a%b.txt`, `q?x.txt`, `h#y.txt`, `sp ace.txt`, `ünïcode.txt`, `100%.txt`, `dir/sub/f.txt` all round-tripped; `/` literal, `%`->`%25`, `?`->`%3F`, `#`->`%23`, space->`%20`, UTF-8->`%XX` bytes). S3: keys go literally in the request path; `?list-type=2&encoding-type=url` returns them encoded. `urlenc` semantics hold on both.
One REST bug found at cleanup: `DELETE objects/<enc>` on keys containing `?` or a query-looking string answered 200 but did not delete; S3 `DELETE` answered 204 and the object was gone. Another mark against the REST path.

## (e) Minimal custom-domain scopes

Minted scoped tokens and exercised `PUT /accounts/<a>/workers/domains`:

| Token scopes | Result |
|---|---|
| Workers Scripts Write (account) + Workers Routes Write + Zone Read (zone) | 200 |
| Workers Scripts Write (account) + Zone Read (zone) | 200 (Routes not needed) |
| Workers Scripts Write + Routes + Zone Read, all zone-scoped | 403 (account scope on the scripts group is required) |
| Workers Scripts Write (account) alone | 200, and it also covers `PUT workers/scripts/<w>`, `POST .../subdomain`, `GET workers/domains`, `GET workers/scripts/<w>/settings`, `GET zones?name=` |
| that token on `GET zones/<z>/dns_records` | 403 (needs DNS: Read on the zone) |

Minimal admin set: **Workers Scripts: Edit (account) + DNS: Read (zone)**. DNS: Edit and Workers Routes: Edit are not needed.

## (f) Analytics Engine query

`SELECT SUM(_sample_interval) AS hits, COUNT(DISTINCT blob2) AS visitors, MAX(timestamp) AS last FROM <dataset> FORMAT JSON` works as written; answer `{"hits":"1124","visitors":"2","last":"2026-09-30 09:21:35"}`. The SQL envelope is `{meta, data, rows}`, not `.result`; `MAX(timestamp)` is a `YYYY-MM-DD HH:MM:SS` string.

## (g) Access app on a Worker custom domain

App `self_hosted`, destinations `share-spike-gy4op3.d.foundation/ab12cd{,/*}`: an unauthenticated GET `https://<host>/ab12cd/` answered `302 https://dwarves.cloudflareaccess.com/cdn-cgi/access/login/<host>?kid=<aud>&...` with `kid` exactly the app's `aud` (`9106cc86...`). Same as the tunnel backend. One edge case found: an app whose only policy is `non_identity` (service token) answers 403, not 302, to an unauthenticated browser request, share's gated adds always carry an interactive include (email/group/domain), so the 302 gate probe holds.

## (h) Edge and Worker view of odd paths

Probed `https://<host><path>` with `--path-as-is`; the Worker echoes `request.url` and `new URL(request.url).pathname`:

| Sent | `request.url` path | `new URL().pathname` |
|---|---|---|
| `/x/..%2Fabc123/f` | `/x/..%2Fabc123/f` | `/x/..%2Fabc123/f` |
| `/%2fabc123/f` | `/%2fabc123/f` | `/%2fabc123/f` |
| `/x/..%5Cabc123/f` | `/x/..%5Cabc123/f` | `/x/..%5Cabc123/f` |
| `/x/%2e%2e/abc123/f` | `/x/%2e%2e/abc123/f` | `/abc123/f` |
| `/x/..\abc123/f` | `/x/..\abc123/f` | `/abc123/f` |
| `/./abc123/f` | `/./abc123/f` | `/abc123/f` |
| `//abc123/f`, `/abc123//f` | unchanged | unchanged |
| `/%61bc123/f`, `/abc123/a%2Ehtml` | unchanged | unchanged |
| `/abc123/%01`, `/abc123/f%0a` | unchanged | unchanged |
| `/abc123/%zz` | edge answers 400 itself, the Worker never runs | |
| `/ABC123/f`, `?next=%2Fhome` | unchanged / query untouched | unchanged |

workerd keeps `request.url` raw and `new URL()` resolves `%2e%2e`, `\`, `/./`; node 22's `new Request(u).url` resolves them at construction (tests must not assert the raw regex fires on `new Request` input for `%2e%2e`; the resolved pathname is what the record lookup sees, and the JWT check is the gated-share backstop for literal `\`).

## (i) `curl --parallel` per-transfer `-w`

Works on macOS system curl 8.7.1 and Ubuntu 22.04 curl 7.81.0:
`-K` config with `output = "/dev/null"` + `url = "..."` per transfer;
`-w '%{http_code} %{url}\n'` prints one line per completed transfer
(order is completion order, not config order). One `-o` on the command line
covers only the first URL, so each transfer needs its own `output=` line.

## (j) Rate limits

- Account API (`api.cloudflare.com`): response headers `ratelimit-policy: "rtwo_gw_apigw";q=1200;w=300` and `ratelimit: r=<remaining>` -> 1200 requests per 300 s on the R2 gateway. Per-token vs per-owner not separately measured (the second token could not read the path); moot under S3.
- S3 endpoint (`<acct>.r2.cloudflarestorage.com`): 200 rapid GETs at 25 parallel, all 200, no rate headers, no `SlowDown`. Every object call (list, `m/` read, `o/` PUT, DELETE) runs there, so `ls` never consumes the account-API budget at any share count; the earlier N+1 concern applies only to the 1-3 account-API calls a verb still makes (Access, workers settings, one SQL call for `hits`).

## (k) `custom_metadata`

`x-amz-meta-<name>: <v>` on the S3 PUT populates `custom_metadata` (verified in the REST list: `{"app":"share","ver":"1"}`). The one-call-listing upgrade path exists if ever needed; the record-per-share design does not need it.

## (l) `Cf-Access-Jwt-Assertion` at the Worker

Service-token auth (`CF-Access-Client-Id`/`CF-Access-Client-Secret`, `non_identity` policy): the request reaches the Worker with `Cf-Access-Jwt-Assertion`; the JWT's `aud` is the app's AUD as a **string** (`9106cc86...`, the check must accept string and array), `iss` is `https://dwarves.cloudflareaccess.com`, `kid` is in the header and present at `https://<team>/cdn-cgi/access/certs` (two keys published). A wrong secret answers 302 to the login flow, never admitted. A path outside the app's destinations reaches the Worker with no JWT.

## Pricing re-read (spec cost section)

R2 pricing page confirms the free tier (10 GB-month, 1 M Class A, 10 M Class B ops per month) and the billed rates the spec cites (Class A $4.50/million, Class B $0.36/million, storage $0.015/GB-month). The spec's "under $1/month at 5 GB and 1k views/day" holds.

## Spike cleanup

All spike objects deleted (see below): buckets `share-spike-gy4op3` and `share-spike2-gy4op3`, Worker `share-spike-gy4op3`, its five custom domains (`share-spike{,2,3,4,5}-gy4op3.d.foundation`), Access app `0354f535-cdcf-461a-9ec8-20b88d90f044`, service token `7fa29d65-d0c1-4465-8911-b531a0ad877a`, user tokens `share-spike-gy4op3-pub` and `share-spike-e-t{1,2,3,4}`. Verified: `GET` on each object answers 404/empty afterwards; no `share-spike*` DNS record or Access app name remains.

## Build deltas

Deviations from the spec, per task. A task with none is not listed.

### TASK-6 (snapshot, rand_id, r2-own)

- The live record fetch walks its own key map and looks each answer up by `%{filename_effective}`, not `%{url}`. A key curl printed no line for is retried alone through `r2_call`, so a curl that dies early fails the snapshot instead of listing fewer shares. `filename_effective` prints per transfer under `--parallel` on curl 8.7.1, failed transfers included.
- The dry seam fetches records one `r2_call GET` at a time; the parallel path runs only live.
- `r2_record_row` also drops a record whose `expires` is outside `0 <= expires < 1e11` (a forged `1e300` would break bash arithmetic in `ls`), whose `added` holds a control byte, or whose `opts` already carry `prefix=` or `by=` (the row appends its own).
- `r2_own_get` also requires the stored prefix to name the same id.
- `rand_id` on r2 skips an id whose `o/<id>.` listing holds any key (round-3 warning), besides the `GET m/<id>` check.
- Row 25e's `add` half passed on the `add` stub; TASK-9 made it a real check (see below).
- Test hooks `r2-rows`, `r2-id`, `r2-own get|put|drop` sit beside the TASK-5 hooks in the dispatcher.

### TASK-7 (admin setup, dry only)

- No live Cloudflare call was made; rows 3, 4, and 20 run against the dry seam. The live leg stays TASK-14.
- Dry account API: `r2_api` wraps `cf_try` and, under `SHARE_R2_DRY`, answers from state files in `$SHARE_R2_DRY_DIR/.cf/` (`bucket`, `r2dev`, `bucket-domain`, `dns`, `domain.json`, `script.json`, `subdomain.json`, `team`). Knobs: `SHARE_R2_DRY_ROLE=deny`, `SHARE_R2_DRY_BUCKETDOM=deny`, `SHARE_R2_DRY_DOMAINS=500`, `SHARE_R2_DRY_SUBDOMAIN=stuck`, `SHARE_R2_DRY_HEALTHZ=down`. Log lines read `API <METHOD> <path>` and `HEALTHZ`. The dry LIST now skips every dot path, so `.cf` is never an object.
- Step 5's listing and the marker read and write go through S3 (`r2_call`), with the admin token's own S3 pair (key id from `GET /user/tokens/verify`). The REST object path is out per TASK-1(a), so the admin token needs Workers R2 Storage: Edit on the account.
- The zone lookup walks the hostname's labels through `r2_api`, as `cf_zone` does.
- Step 9 also redeploys when the deployed `VERSION` differs from the CLI's. Without it, a `--force` downgrade with an equal `SHA` skipped the deploy and then timed out at step 12.
- Round-3 warnings built in: `TEAM` must match `^[a-z0-9-]+\.cloudflareaccess\.com$`; a failed organizations read keeps the deployed `TEAM`; a `TEAM` change redeploys and prints the change; the metadata part goes through `-F metadata=<-` from a `printf` process substitution, so `SALT` never reaches an argv or a file.
- `--force` over a foreign DNS record adds `override_existing_dns_record: true` to the domain PUT.
- Step 10 runs on every setup, reruns included; it is idempotent.
- Step 12 counts a round only when the pair equals the CLI's; a stale edge answer resets the streak.
- The config gains `r2_endpoint=`, which `r2_url` reads. It never stores `r2_key_id`: the admin token's id must not become a publisher's key. `api_token_cmd` and `r2_token_cmd` lines are kept.
- Row 3's log order is asserted over two runs: a fresh bucket (404, so no domain or marker reads) and a rerun on the existing bucket (its reads precede the DNS read).
- A 401 or 403 on the script settings dies until TASK-8 lands join mode.

### TASK-8 (join mode)

- Join takes its token from `CLOUDFLARE_API_TOKEN`, as admin does, and does not store it. The ready line names `share api-token` as the next step. The `api-token` refusals for admin and account-wide tokens are not built yet.
- Step 5 for join: a 403 on the REST bucket read is accepted, because a bucket-scoped token gets 403 on every REST call (TASK-1(a)). The S3 listing and the `share.json` read then prove the bucket, and a missing marker dies naming the admin step. A 404 on the bucket read dies the same way.
- Join skips steps 4 and 6 to 11 and writes nothing on Cloudflare. Step 12 accepts any Worker pair and prints the mismatch line when the pair is not the CLI's.
- The healthz wait moved into `r2_wait_healthz admin|join`, shared by both roles.
- `SHARE_R2_DRY_BUCKETDOM=deny` also answers 403 on the bucket settings read.

### TASK-9 (add and its refusals)

- `add` resolves a publisher token source before any call (`r2_token_check`); the dry seam checks only that a source exists. The no-token block names `share api-token`.
- `add --access` on r2 is refused until TASK-12 builds the gated publish.
- `by=` is `this_host` lowercased, with characters outside `a-z0-9.-` dropped: a Mac named `Mac-mini` failed the `rows()` check and its own records vanished from `ls`.
- The printed link comes from the stage: a folder gets its slash, a rendered `.md` links its `.html`. `ls` has no stage, so it prints `/<id>/<name>`; the Worker 308s a folder to its slash, and a rendered `.md` lists by its source name.
- `stage_copy` makes no `pub/` on an r2 profile.
- The live, `--host`, `start`, `stop`, `serve`, and `service` refusals now print the spec's text.
- A 412 on the record PUT dies; the EXIT trap then reads `m/<id>`, sees another prefix, and deletes only this add's prefix.
- The dry log does not record headers, so row 5 proves `If-None-Match: *` by behavior: a record written while the add waits at its publish wins, and the add dies naming the taken id. Dropping the header turns five row 5 checks red.
- Row 25e's `add` half is a real check: with a token source, the add dies in `rand_id`'s prefix check and names it.
- The `share api-token` refusals for admin and account-wide tokens (DEC-007) stay open for TASK-12: `api-token` still runs the Access preflight on every profile, and its r2 branch lands with the gated work.

### TASK-10 (ls, refresh, rm, prune, orphan sweep)

- Gated rows wait for TASK-12. `rm` of a gated r2 row is refused. `ls` and `prune` keep every expired gated row and print the waiting line, because no Access-capable path exists yet. Row 10's "prune with an Access-capable token" half and row 9's gated lost-DELETE case move to TASK-12.
- `rm` ignores the DELETE answer and lets the fresh `GET m/<id>` decide. A DELETE that answered 000 but committed still completes; one that did not commit dies before any object delete.
- The `ls` prune drops each removed row from the snapshot file, so the listing never shows a share it just removed.
- The orphan sweep reuses the snapshot's record fetch. Each 200 body also passes a raw check (a JSON object, a string `prefix`, a numeric `v` no higher than `WORKER_RECORD_V`), independent of the filtered row. The first body that fails names its key and skips the sweep. No second `m/` read runs.
- The orphan age compares R2's `LastModified` against the local clock minus 24 h, as ISO strings. An object without `LastModified` counts as fresh. Expiry uses the local clock too; the round-3 `Date`-header idea was not taken, since the Worker enforces expiry per request and prune only cleans up.
- `r2_list` also returns each key's `LastModified`, and skips a decoded key that holds a control byte: a decoded newline would otherwise split into a second line naming another key.
- The dry LIST emits `LastModified` from the file's mtime.
- `refresh` reads the record fresh with `GET m/<id>` for its etag, never the snapshot. The new record keeps the old one's fields and swaps `prefix`, and `src` is rewritten from `r2-own`.
- The integration Worker is a mode of `tests/worker.mjs`: `--dir <dry bucket> --host <host> <path>...` loads the dry bucket into the in-memory `BUCKET` and prints one `<code> <path>` line per path. It replaces the `node:http` server plus curl: the same Worker logic runs, with no port.
- Row 25c: with no cross-install lock, both prunes may issue DELETEs. The suite asserts both exit 0, nothing is left, and at least one reports the removal.
- Negative controls, red then restored: the sweep ignoring unreadable records (three row 24 checks), the refresh PUT without `If-Match` (six row 25a checks), and `rm` without the fresh GET (two row 9 checks).

### TASK-11 (hits, status, state, profiles)

- `hits` on r2 checks the id against `^[0-9a-f]{6}$` and needs no record: it skips the snapshot and sends one SQL call. The account id comes from the config's `r2_endpoint`. The token is the full `api_token_resolve`, because Account Analytics: Read is account-wide and the bucket-scoped publisher token lacks it. `last` converts the UTC `MAX(timestamp)` to local time, as the tunnel `hits` prints. The live SQL call goes through `cf_try` with a JSON content type and the SQL as the body; TASK-14 confirms the live answer.
- The dry account seam answers `POST .../analytics_engine/sql` from `$SHARE_R2_DRY_DIR/.cf/sql.json` and logs the query on a `SQL <query>` line.
- `status` prints `r2 backend: https://<host>/`, then `worker: up (<pair>)` or `worker: DOWN: <code>`. It adds the version-mismatch line whenever the pair differs, newer or older. It prints `orphan sweep blocked by <key>` and the count of expired gated shares, then `ls` without its prune. The `X-Share-Gate` status line waits for TASK-12's Worker change.
- `state` on r2: `state` is `serving` once a hostname is set, `ready` comes from one `/healthz` probe with a 2 s cap (`r2_healthz` takes the cap), shares come in snapshot order (the tunnel reverses its append order; a snapshot has none), and `skipped` is never set. `r2_snapshot` writes its temp file under the root, so an r2 `state` creates the root directory if missing.
- `profiles --json` does not exist on either side; Share Bar reads `share state` only. The r2 `state` JSON was decoded with Share Bar's own `Snapshot` type, compiled from `mac/Sources/ShareBarCore/Snapshot.swift`; unknown keys (`backend`, `access_pending`) are ignored. No Swift change was needed. Share Bar will show an r2 profile as serving and may offer Stop, which the CLI refuses.
- `profiles` passes `SHARE_STATE_BRIEF=1` to every child `state`; tunnel `state` ignores it.
- Negative controls, red then restored: `hits` without the id check (the injected id reaches the SQL), and `profiles` without the brief flag (an `m/` list is logged).
