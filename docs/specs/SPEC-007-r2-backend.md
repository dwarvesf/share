# SPEC-007: R2 storage backend per profile

Status: DRAFT
Lane: full (external provider, authz on the publish path, a new public surface, credentials for several people)
Depth: deep. Unsampled until TASK-1: the REST object path under a bucket-scoped token, conditional writes, list pagination, custom-domain scopes, `curl --parallel` per-transfer status, the edge and Worker URL views. Every build task that consumes one of them depends on TASK-1.
References: `bin/share` `cmd_setup`, `cmd_add`, `stage_copy`, `stage_publish`, `rows`, `row`, `rand_id`, `cmd_rm`, `cmd_prune`, `cmd_hits`, `cmd_state`, `cmd_profiles`, `cmd_teardown`, `access_*`, `api_token_resolve`, `cf_try`, `release_locks`; SPEC-004 (Access gate), SPEC-005 (profiles), ADR-0002 (a mode is fixed at setup), ADR-0005, ADR-0006.

## Problem

Every link of a profile lives on one machine. When the Mac Mini sleeps, reboots, or loses its uplink, every Dwarves link answers Cloudflare 530. Only someone with a shell on that machine can publish, so a teammate who wants to share a report asks Han. A profile needs a backend that serves from Cloudflare itself and accepts uploads from several people, while the per-link Access gate keeps its guarantees and existing installs change by zero bytes.

## Context (research, 2026-09-30)

Read-only probes of the Dwarves LLC account with the Toolkit token (through 1Password Connect; no value, key, or account id is quoted here). Commands and excerpts: `## Grounding`.

| Item | State |
|---|---|
| R2 | enabled; 15 buckets, location APAC |
| Public buckets | only `brand-assets` (custom domain `assets.d.foundation`, not probed further); the other 14 have no custom domain and r2.dev off |
| Workers | 44 scripts, `df-*` naming; custom domains in use (`dataroom.d.foundation`, `memo.d.foundation`, `status.d.foundation`, ...) |
| workers.dev defaults | an existing script (`monitor`) reads `enabled: true, previews_enabled: true`: a new share Worker must turn both off, or `<script>.<sub>.workers.dev` serves content outside the Access app's hostname |
| Analytics Engine | enabled; one dataset; the SQL API answers |
| D1 | enabled; 5 databases |
| `s.d.foundation` | a live tunnel profile (`share-s-d-foundation`, proxied CNAME) with one gated share's Access app |
| R2 object REST path | `GET /accounts/<a>/r2/buckets/<b>/objects?prefix=` answers 200 with a JSON array; items carry `key`, `etag`, `size`, `last_modified`, `http_metadata`, `custom_metadata`, `storage_class`; a missing key answers 404 JSON; `result_info` was `null` on a one-item page |
| wrangler's own upload path | `wrangler r2 object put` (4.133.0) calls `PUT /accounts/<a>/r2/buckets/<b>/objects/<key>` with the API token and a 300 MiB cap; `get` and `delete` use the same path; wrangler has no object list verb. The path is not in Cloudflare's public API reference |
| Token introspection | `tokens/permission_groups` answers 9109 with the Toolkit token: scopes can be exercised, not listed |
| Toolkit token reach | lists every bucket, `payout`, `invoice`, and `dataroom-kyc-evidence-prod` included: it must never be a publisher's R2 token |

## Picture

```
 publisher A (Mini)          publisher B (laptop)               visitor
 share --profile df add      share --profile df add             https://f.d.foundation/<id>/<name>
        |                           |                                   |
        | curl, API token via -H @<(...) (never argv, never a file)     v
        +-------------+-------------+                      Cloudflare edge: TLS, Access app on
                      v                                     f.d.foundation/<id>, /<id>/* (gated ids)
        Cloudflare REST: /accounts/<a>/r2/buckets/<b>/objects                    |
          (TASK-1 fallback: S3 API, curl --aws-sigv4, same token)                v
                      |                                    Worker share-f-d-foundation (custom domain
                      v                                     only; workers.dev and previews off)
        R2 bucket (private: no r2.dev, no custom domain)      |  400 on any non-canonical raw path
          share.json               marker: {v:1, host}        |  exact Host, else 404
          m/<id>                   one record per share  <----+  GET m/<id>: none, expired, or
          o/<id>.<nonce>/<path>    the snapshot bytes    <----+    bad prefix -> 404
                                                              |  index.html, README.html, slash redirect
 local, per publisher: access-pending (own gate waits and    |  no-store, noindex on every answer
 failed deletes), r2-own (id -> source path of own adds)     +->  Analytics Engine: one point per <400
 A prefix no record names is a stage: the Worker reaches bytes only through m/<id>.
 Live dev-server links (share add 3000) stay on a tunnel profile.
```

## Design

### Approaches considered

| Question | Options | Chosen, one-line reason |
|---|---|---|
| Uploader transport | wrangler `r2 object put`; S3 API through `curl --aws-sigv4`; rclone; curl against the REST object path | REST object path through curl: the same endpoint Cloudflare's own wrangler calls, JSON in and out, the existing header-file token, and no new dependency. wrangler adds node, one process per file, and no list verb; rclone adds a dependency on every teammate's machine. SigV4 costs XML listings and the `-K` credential dance but escapes the account API rate limit; it is the fallback TASK-1 switches to, whole, if the REST path refuses bucket-scoped tokens or conditional writes. |
| Shared index | one index object written with `If-Match`; D1; one record object per share | one record per share (`m/<id>`). An index object is workable (a failed `If-Match` retries rather than losing an update), but every add and rm contends on one key and a retry re-uploads the whole index. D1 lists in one query, but it adds a resource, a binding, a database read on every request, and D1 tokens are account-wide (no per-database scope to match a bucket-scoped R2 token). Records keep every write on its own key. |
| Stage then publish | copy objects from a staging prefix; a publish flag in object metadata; a record that names the prefix | the record names the prefix. R2 has no rename, so a copy costs one call per file. With the record as the only path to the bytes, one conditional `PUT m/<id>` publishes, and a conditional record swap makes a refresh atomic. |
| Worker delivery | a separate `worker/` file shipped by the formula; wrangler with a `wrangler.toml`; source embedded in `bin/share`, uploaded by curl | embedded: `install.sh` over curl ships `bin/share` alone, and the Homebrew formula stays unchanged. The multipart upload is one `PUT workers/scripts/<name>`. |
| Folder listing | generated by the Worker per request; generated at stage time | stage time, by `gen_index` as today, uploaded as `index.html`; the Worker only resolves index files. |
| Expiry | lifecycle rules; a Worker cron; the record's `expires` checked per request | per request: a link dies at its second. Records and bytes are deleted by the next `ls` or `prune` from any publisher. A cron would need an Access token in the Worker, which ADR-0006 rules out. |
| Visit counts | Workers Logs; a counter object; Analytics Engine | Analytics Engine: a write never blocks a response; `share hits` reads it with one SQL call. |

### Selecting the backend

- `share [--profile <p>] setup <hostname> --backend r2 --bucket <name>` writes `backend=r2` into the profile's config. `--backend tunnel` or no flag is today's setup, byte for byte. A profile has one backend; switching goes through `teardown` (the ADR-0002 stance).
- `--backend r2` refuses `--quick`, `--tunnel-name`, `--login`, and `--no-service`: `usage: share setup <hostname> --backend r2 --bucket <name> [--force]`.
- Config of an r2 profile: `backend=r2`, `hostname=`, `zone=`, `bucket=`, `port=r2`, a kept `api_token_cmd=`. `port=r2` is a sentinel: an older share dies at load on it (`port 'r2' is not a number`) for every verb, so it can never write `pub/` or create an Access app against an r2 profile. The new CLI reads `backend` before the port check; SPEC-005's cross-profile scans already skip a non-numeric `port=`. The Worker name is always derived, `share-<host-with-dashes>`, and the dataset is `share_<host-with-underscores>` (checked `^[a-z0-9_]+$`); neither is read from the config.

### Setup (admin, once per hostname)

Admin work (deploy, purge) reads `CLOUDFLARE_API_TOKEN` from the environment only, never a stored token, so a stored publisher token cannot redeploy and an admin token is never stored by accident: `share api-token` on an r2 profile refuses a token that `GET workers/scripts/<worker>/settings` accepts. Order, each step verified before the next; every refusal precedes the first write; any answer other than the named ones fails closed.

| Step | Call | Refuse or stop when |
|---|---|---|
| 1 | the hostname, the bucket name (`^[a-z0-9][a-z0-9-]{1,61}[a-z0-9]$`), SPEC-005 `other_cfg hostname` | bad name, hostname of another profile, a tunnel config in this profile |
| 2 | zone and account (`access_account`) | no token: a block naming the admin scopes and the publisher-token form |
| 3 | `GET r2/buckets/<b>`: 404 -> `POST r2/buckets {name}`; 200 -> `GET .../domains/managed`, `GET .../domains/custom`, `GET objects?prefix=&per_page=1` | the bucket holds objects and no `share.json`; r2.dev is on; a custom domain exists; any of these reads answers other than 200. So `brand-assets` (objects, custom domain) is refused before any write |
| 4 | `GET objects/share.json`; 404 -> `PUT` it with `If-None-Match: *` | the marker names another hostname |
| 5 | `GET zones/<z>/dns_records?name=<hostname>`, `GET workers/domains?hostname=<hostname>` | a DNS record that is not this Worker's custom domain, unless `--force`; a custom domain naming another service, even with `--force` |
| 6 | `GET workers/scripts/<worker>/settings` | the script exists and its bindings are not `HOST == <hostname>`, `BUCKET == <b>`, and a `VERSION`: not share's Worker, refused; its `VERSION` is above this CLI's: refused unless `--force` (no silent downgrade) |
| 7 | deploy when absent, or when the deployed `SHA` differs and its `VERSION` is not above this CLI's | |
| 8 | `POST workers/scripts/<worker>/subdomain {"enabled":false,"previews_enabled":false}`, then `GET` it | the read-back is not `false,false`: die; no custom domain exists yet, so nothing is exposed |
| 9 | `PUT workers/domains {hostname, service:<worker>, zone_id, environment:"production"}` | an API error |
| 10 | live check: `https://<hostname>/healthz` answers `200 ok` with `X-Share-Worker: <version> <sha>` naming this CLI's pair, three times in a row, up to `SHARE_R2_WAIT` (300 s: cert issuance on a new name) | timeout: die naming the hostname; the config is not written |
| 11 | `write_config_r2` | |

Deploy (`r2_deploy`): one `curl -X PUT .../workers/scripts/<worker>` with two multipart parts: `metadata` (`main_module`, a `compatibility_date` constant, bindings `r2_bucket BUCKET`, `analytics_engine HITS`, `plain_text HOST`, `plain_text VERSION`, `plain_text SHA`, and `keep_bindings: ["secret_text"]`) and `share.js` (`application/javascript+module`). The first deploy also sets a `secret_text` binding `SALT` (32 random hex) that later deploys keep. The source comes from `worker_js`, a quoted heredoc in `bin/share` written to a file in `$root` and read back (never a heredoc inside `$( )`, per CLAUDE.md). `WORKER_VERSION` (an integer) and `WORKER_SHA` (the first 12 hex of the source's sha256) are constants beside it; the suite fails when the computed sha differs from `WORKER_SHA`, so a Worker edit cannot ship without a version bump. `compatibility_date` moves only with a `WORKER_VERSION` bump.

Join mode: a teammate runs the same command with a publisher token. Steps 1 to 5 read only. The marker must name this hostname. Step 6 answers 401 or 403, so steps 7 to 9 are skipped. Step 10 accepts any `X-Share-Worker` pair; a pair other than this CLI's prints `the Worker at <host> runs <v> <sha>; this share ships <v> <sha>; whoever holds the admin token reruns '<me> setup <host> --backend r2 --bucket <b>'`. Setup then writes the config and changes nothing on Cloudflare. Record `v:1` is the contract between CLI versions: a Worker accepts every record version up to the one it announces in `X-Share-Records`, and a CLI writes the highest version the deployed Worker announces.

### Objects and records

| Key | Content | Written by |
|---|---|---|
| `share.json` | `{"v":1,"host":"<hostname>"}` | setup |
| `m/<id>` | `{"v":1,"id","name","src","added","expires","opts","prefix","by"}`. `opts` is the index opts string (`noindex`, `access=<uuid>`, `access_rule=<rule>`); `prefix` is `o/<id>.<nonce>/`; `by` is the publisher's `this_host`, for display only | add (`If-None-Match: *`), refresh (`If-Match: <etag>`), rm and prune (delete) |
| `o/<id>.<nonce>/<path>` | the stage tree, byte for byte: what `stage_copy` built | add, refresh |

Every key goes through `urlenc` in the URL (only `/` stays literal; `%` becomes `%25`), and after an upload a listing of the prefix must equal the stage's file list. A stage file name with a control character is refused before any upload.

The snapshot (`r2_snapshot`): list `m/` (every page; any non-2xx page dies), fetch every record in one parallel curl run (any answer other than 200 or 404 dies), then jq drops a record whose `id` differs from its key or whose fields hold a control character, and emits `@tsv` rows whose opts gain `prefix=<prefix>` and `by=<host>`. `index` points at that file (`$root/.r2-index.XXXXXX`) for the process, so `rows()` stays the only reader and the `-s $index` guards in `ls`, `prune`, and `id_of` keep working. The awk gains two checks: `prefix=` must be `o/<id>.` plus 8 hex plus `/`, and `by=` must pass the hostname character set. The snapshot uses the full `api_token_resolve`: on an r2 profile a listing runs `api_token_cmd`, which SPEC-004's listing rule forbids for Access checks only. `rand_id` refuses an id whose `GET m/<id>` answers 200, and dies on anything but 200 or 404.

`$root/r2-own` holds `<id>\t<source path>` for every share this install added. `refresh` works only on ids listed there and reads the source path from it, never from a record another publisher could forge.

### Per verb

| Verb | r2 behavior |
|---|---|
| `add <file\|dir>` | `stage_copy` as today; refuse over `SHARE_R2_MAX_FILES` (500) files or any file over 300 MiB; upload every file to `o/<id>.<nonce>/` (`r2_put_tree`); compare the prefix listing to the stage; `PUT m/<id>` with `If-None-Match: *` (the publish); append to `r2-own`; trash the stage |
| `add --access` | SPEC-004 unchanged up to the publish: prepare, stage, upload, intent line, app, gate. Publish under the local `index` lock: exact pending line present, `PUT m/<id>` with `If-None-Match: *`, drop the line. No record exists during the gate wait, so the Worker answers 404 behind the login. A 412 means another publisher took the id: delete the app and the prefix, die |
| `add <port>`, `add --host` | refused before any write: `live shares and --host need a tunnel profile; this profile serves from R2` |
| `ls` | rows from the snapshot, each line with `by=<host>`; prune in `listing` mode first |
| `refresh <id>` | ids in `r2-own` only, else `<id> was added from another install; refresh it there`. Upload to a new nonce prefix, then `PUT m/<id>` with `If-Match: <etag read at start>`; a 412 or 404 aborts (a concurrent rm or refresh won) and deletes the new prefix; on success delete the old prefix |
| `rm <id>` | pending line for a gated row; `DELETE m/<id>` (404 counts); a fresh `GET m/<id>` must answer 404, else the line stays, the app stays, and rm dies; delete every object under `o/<id>.` (all nonces; 404 counts); then the Access app |
| `prune` | expired rows from the snapshot through `rm` in prune mode. An expired gated row is removed only by a process whose resolved token passes `access_proof`; without one its record and bytes stay (the Worker already answers 404) and prune prints `expired gated share <id> waits for a publisher with the Access token`. So no install ever defers another install's app into its local `access-pending`. Bare `prune` then sweeps orphan prefixes: every `o/<id>.<nonce>/` that no record names and whose newest object is older than 24 h is deleted |
| `hits <id>` | `POST analytics_engine/sql`: `SELECT SUM(_sample_interval) AS hits, COUNT(DISTINCT blob2) AS visitors, MAX(timestamp) AS last FROM <dataset> WHERE index1 = '<id>' FORMAT JSON`, with the id checked `^[0-9a-f]{6}$` first; output as today: `N hits, M visitors, last YYYY-MM-DD HH:MM` |
| `status` | `r2 backend: https://<host>/`, the `/healthz` answer (`up`, or `DOWN: <code>`), the version-mismatch line when it applies, then `ls` without its prune (SPEC-004 round 8: status is a read) |
| `state` | `state` `serving` when set up, `ready` from one `/healthz` probe (2 s), `mode` `named`, `hosts` `""`, `serves_here` and `service` false, shares from the snapshot, plus `"backend":"r2"` on r2 profiles only; `schema` stays 1. `cmd_profiles` sets `SHARE_STATE_BRIEF=1`, which makes r2 `state` skip the share list; tunnel `state` ignores it |
| `start`, `stop`, `serve`, `service` | refused: `an r2 profile serves from Cloudflare; nothing runs on this machine ('<me> rm <id>' unpublishes a link)` |
| `teardown [--yes]` | local only: the config, `r2-own`, and the stored API token go; the bucket, the Worker, and every share stay for the other publishers; it says so |
| `teardown --yes --purge` | admin token from the environment; before any change: the step-6 binding check passes, `share.json` names this hostname, and the custom domain's `service` is this Worker. Then every share through `rm` (gated first), `access_sweep`, `DELETE share.json`, the custom domain, the script, the bucket only when its listing is empty (else the remaining key count is named), then the local config. It prints that the Analytics Engine dataset cannot be deleted and ages out. The dispatch passes every argument (`shift; cmd_teardown "$@"`) |

Every r2 call (`r2_call`, on `cf_try`'s globals) retries 429 and 5xx up to three times, honoring `Retry-After` up to 30 s. `r2_put_tree`: one `curl --parallel --parallel-max 8` run whose config file holds only `url = "..."` and `upload-file = "..."` lines (backslash and double quote escaped); the token reaches curl only as `-H @<(printf ...)`; `-w '%{http_code} %{url}\n'` per transfer, and every transfer must answer 2xx. The EXIT trap (`release_locks`) deletes a held prefix only after a fresh `GET m/<id>` shows that no record names it.

### Worker contract

The Worker reads no API token and holds one secret (`SALT`). Checks run in this order for every request.

| Request | Answer |
|---|---|
| `new URL(request.url).hostname` is not exactly `env.HOST` (a trailing dot or another name fails) | 404 |
| method other than GET or HEAD | 405 |
| raw path: the text of `request.url` after the host and before `?`. It holds `%2f`, `%5c`, or `%2e` (any case), a literal `\`, `//`, a `.` or `..` segment, or a byte below 0x20; or `new URL(request.url).pathname` differs from it | 400. The Worker serves only canonical paths, so it never reaches bytes by a path the edge could match differently, whatever the zone's URL normalization setting |
| `/healthz` | `200 ok`, headers `X-Share-Worker: <VERSION> <SHA>`, `X-Share-Records: 1` |
| first segment is not exactly 6 lowercase hex chars (no decoding: `/ABC123/`, `/%61bc123/` answer 404) | 404 |
| no `m/<id>`; a record whose `v` is above the Worker's; whose `id` is not the key's id; whose `prefix` is not `o/<id>.` plus 8 hex plus `/`; or whose `expires` is past (`expires > 0 && now > expires`) | 404 |
| `/<id>` | 308 to `/<id>/` |
| a path ending in `/` | `<prefix><rest>index.html`, then `README.html`, else 404 |
| any other path | segments decoded with `decodeURIComponent` (a malformed escape answers 400); the object `<prefix><rest>`; missing, but `<key>/index.html` or `<key>/README.html` exists -> 308 to `<path>/`; else 404 |
| every answer, errors included | `Cache-Control: no-store`, `X-Robots-Tag: noindex, nofollow` |
| a hit (status < 400, not `/healthz`) | `HITS.writeDataPoint({indexes:[id], blobs:[id, first 16 hex of sha256(SALT + cf-connecting-ip)]})`; the raw IP is never written. This pseudonymizes; it does not anonymize |

`Content-Type` comes from a fixed extension map (html, css, js, mjs, json, txt, md, csv, xml, svg, png, jpg, jpeg, gif, webp, ico, pdf, mp4, webm, mp3, wav, woff, woff2, zip, wasm), `application/octet-stream` otherwise. `Range` and conditional request headers pass to `BUCKET.get(key, {range, onlyIf})`. Every served path starts with `/<id>/` or is `/<id>`, both inside the Access destinations `<host>/<id>` and `<host>/<id>/*`.

### Token scopes

| Role | Scopes | Used by |
|---|---|---|
| admin (environment only) | Workers Scripts: Edit; Workers R2 Storage: Edit (bucket create and settings); Zone: Read; the custom-domain scopes TASK-1 pins (candidates: Zone Workers Routes: Edit, DNS: Edit) | setup deploy, `teardown --purge` |
| publisher (stored per profile with `share api-token`) | UNVERIFIED until TASK-1(a) records the exact group names: Workers R2 Storage Bucket Item Read and Write, resource the share bucket only; Zone: Read; Account Analytics: Read (optional, `hits`; it reads every dataset on the account) | add, ls, refresh, rm, prune, hits, state |
| gated publisher | the publisher scopes plus SPEC-004's Access scopes (Access Apps and Policies Edit is account-wide) | `add --access`, removal of gated shares |

A publisher token can read every object in the bucket, gated shares included: Access gates visitors, not publishers. An account-wide R2 token reaches every bucket (`payout`, `invoice`, `dataroom-kyc-evidence-prod`); the docs name the bucket-scoped form and never suggest the Toolkit token. `docs/setup.md` recommends an `expires_on` on every token and one token per teammate, so a leaver is revoked alone.

### What stays tunnel-only

Live dev-server links (`add <port>`), own hostnames (`--host`; a later spec can map fqdn -> id in the Worker), quick mode, and the login service. An r2 profile and a tunnel profile run side by side on one machine (SPEC-005), so `share --profile df-live add 3000` keeps working.

### Cost and liveness

At list prices (R2 storage $0.015/GB-month after 10 GB free; class A $4.50 per million writes; class B $0.36 per million reads; Workers requests within the paid plan's included 10 million; Analytics Engine within its free tier), 5 GB and 1,000 views a day cost under $1 a month; TASK-1 re-reads the pricing pages. No path costs without bound: uploads are capped per add, every view is two reads, and orphan prefixes live at most 24 h past the next `prune`. `status` and `state` probe `/healthz`; `docs/setup.md` names `https://<host>/healthz` for an external monitor (vps-mon on Dwarves). The Worker, bucket, and domain are owned by whoever holds the admin token for the profile's account.

## Byte-identity with no flag

A profile without `backend=r2` runs every current code path unchanged: every r2 branch is guarded by `backend == r2`, read once at load. Byte-identical means the files share writes (config, `index.tsv`, Caddyfile, plist and unit, Keychain service names) and the stdout, stderr, and `state` JSON of every existing verb. The usage header gains two lines, the only text change a tunnel install sees.

## Files

- `bin/share`: the r2 functions and per-verb branches above, the usage lines, one skill row.
- `tests/share.sh`: an r2 section under `SHARE_R2_DRY=1`.
- `tests/worker.mjs`: Worker unit and integration checks under node.
- `tests/e2e-r2.sh`: the live leg.
- `README.md`, `docs/how-it-works.md`, `docs/setup.md`, an ADR (next free number), `docs/verification/r2-backend.md`.

## Failure modes

| Failure | Detection | Behavior |
|---|---|---|
| upload fails mid-tree | a transfer's code not 2xx | die; no record, nothing served; the EXIT trap deletes the prefix; a hard kill leaves an unreferenced prefix the next `prune` deletes after 24 h |
| record PUT lost (000) but committed | `r2_call` code | die; the EXIT trap sees the record naming the prefix and keeps it; a gated add keeps its pending line, and its sweep drops the line on a record naming the app (the finished add), never deleting the app |
| `DELETE m/<id>` lost | the fresh `GET m/<id>` answers 200 | rm dies before touching the app; the pending line stays |
| partial prefix delete | a later listing still shows keys | the record is already gone, so nothing is served; the next `rm` retry or the orphan sweep finishes |
| two publishers pick one id | `If-None-Match: *` answers 412 | the loser deletes its prefix (and its app) and dies with `rerun` |
| refresh races rm or another refresh | `If-Match` answers 412 or 404 | the refresh aborts and deletes its new prefix; no record is resurrected |
| Cloudflare API 429, 5xx, outage | `r2_call` code | three retries with `Retry-After`, then die naming the call; nothing is published half-way (the record is written last) |
| R2 or Worker outage | `/healthz` in `status` and `state`; an external monitor | links answer an error; the CLI prints `DOWN` |
| publisher token revoked mid-add | 401/403 from `r2_call` | die; the EXIT trap cannot delete the prefix (same token), so the orphan sweep of another publisher deletes it after 24 h |
| snapshot page or record read fails | non-2xx | the verb dies; never an empty `ls` or a "free" id |
| a forged or corrupt record | jq and `rows()` checks; the Worker's id and prefix checks | skipped by the CLI, 404 at the Worker; never a path into another share's prefix; `refresh` never reads its source path |
| workers.dev or preview left on | setup step 8 read-back | die before the custom domain exists |
| bucket turned public later (r2.dev or a custom domain) | a setup rerun with the admin token (step 3) | refused and named; publishers cannot see it, so Decisions for Han item 5 assigns the check |
| Worker older or newer than the CLI | `/healthz` header | a warning in `setup` and `status`; an admin deploy refuses a downgrade without `--force` |
| an old share CLI on an r2 profile | `port=r2` fails its load-time check | it dies before any verb runs; no write |
| an Access app on a Worker custom domain does not enforce | the SPEC-004 gate | the gate times out; the app and the prefix are deleted; nothing is published |

## Task Breakdown

- [ ] TASK-1: spike on a throwaway bucket and hostname with throwaway tokens; answers in `docs/implementation-notes/r2-backend.md`. (a) The exact permission groups a bucket-scoped token needs for REST object PUT, GET, DELETE, and list. (b) List pagination fields. (c) Whether REST PUT honors `If-None-Match: *` and `If-Match`. (d) Key encoding for `/`, `%`, `?`, `#`, space, non-ASCII. (e) The minimal custom-domain scopes. (f) The Analytics Engine distinct-visitor query (fallback: `GROUP BY blob2`, counted client-side). (g) An Access app on a Worker custom-domain path redirects with `kid == aud`. (h) The edge and Worker view of `%2e%2e`, `%61`, `//`, `\`. (i) `curl --parallel` with per-transfer `-w` on macOS system curl and Ubuntu 22.04 curl (fallback: a sequential loop). (j) The account API rate limit. If (a) or (c) fails on REST, the transport becomes `curl --aws-sigv4 "aws:amz:auto:s3"` with S3 credentials derived from the same token (key id = token id, secret = sha256 of the token) passed through `-K <(...)` and listings with `encoding-type=url`; if neither transport honors (c), `--access` and `refresh` are refused on r2 and this spec is amended before any build task. AC: every UNVERIFIED line here is answered or amended.
- [ ] TASK-2: `backend` load, the `port=r2` sentinel, setup argument refusals, byte identity. AC: rows 1, 2, 22.
- [ ] TASK-3: `worker_js`, `WORKER_VERSION`/`WORKER_SHA` and the sha check, `tests/worker.mjs`. Depends on TASK-1(h). AC: rows 17 to 19, 21.
- [ ] TASK-4: `r2_call` (retries, key encoding) and the dry seam. Depends on TASK-1(a)(c)(d)(j). AC: row 16.
- [ ] TASK-5: `r2_put_tree`, `r2_list`, `r2_delete_prefix`. Depends on TASK-4 and TASK-1(b)(i). AC: row 5.
- [ ] TASK-6: `r2_snapshot` into `rows()`, `rand_id`, `r2-own`. Depends on TASK-5. AC: rows 7, 25e.
- [ ] TASK-7: admin setup (steps 1 to 11, deploy). Depends on TASK-1(e), TASK-3, TASK-4. AC: rows 3, 4, 20.
- [ ] TASK-8: join mode. Depends on TASK-7. AC: row 23.
- [ ] TASK-9: `add` and the refusals. Depends on TASK-6. AC: rows 5, 6.
- [ ] TASK-10: `ls`, `refresh`, `rm`, `prune` with the orphan sweep. Depends on TASK-9. AC: rows 8, 9, 10, 24, 25a, 25c.
- [ ] TASK-11: `hits`, `status`, `state`, `profiles`. Depends on TASK-6 and TASK-1(f). AC: rows 13, 14.
- [ ] TASK-12: gated add and rm on r2 and the r2 sweep. Depends on TASK-10 and TASK-1(c)(g). AC: rows 11, 12, 25b, 25d.
- [ ] TASK-13: `teardown` local and `--purge`. Depends on TASK-12. AC: row 15.
- [ ] TASK-14: `tests/e2e-r2.sh` and its run log. Depends on TASK-2 to TASK-13. AC: rows L1 to L11 and the cleanup assertions.
- [ ] TASK-15: `README.md`, `docs/how-it-works.md`, `docs/setup.md`. Depends on TASK-13. AC: each doc claim matches the code line it describes.
- [ ] TASK-16: the ADR, `docs/verification/r2-backend.md` with the negative-control runs, the skill row. Depends on TASK-14. AC: every negative control has a red and a green run.

## Test plan

Local rows run in `tests/share.sh` with `SHARE_R2_DRY=1`: `r2_call` reads and writes a directory, `$SHARE_R2_DRY_DIR/<key>` (one bucket shared by every `HOME` in a test, with etags and conditional headers honored), and appends `METHOD key` to `$root/r2-calls.log`; Worker, domain, subdomain, and SQL calls answer from fixtures and log the same way. Knobs: `SHARE_R2_DRY_PUT=lost` (commit, answer 000), `SHARE_R2_DRY_DELETE=lost` (no commit, answer 000), `SHARE_R2_DRY_LIST=500`, `SHARE_R2_DRY_PAUSE=<METHOD key>` (wait for a file before answering, for interleavings). `SHARE_R2_DRY` is honored only with `SHARE_TUNNEL=0` and a hostname under `.test`. Order is asserted by line numbers in the log. `tests/worker.mjs` imports the emitted Worker and drives `fetch(request, env)` with an in-memory `BUCKET` (get, put, head, list; `range` and `onlyIf`), a recording `HITS`, and `HOST`, `VERSION`, `SHA`, `SALT`; its integration mode serves the Worker over `node:http` on a loopback port with `BUCKET` backed by `$SHARE_R2_DRY_DIR`, so a bucket written by `share add` is fetched through the real Worker logic with curl. Without node the section prints `SKIP`, except under `CI=true`, where a missing node fails the suite.

### Coverage matrix

| # | Category | Case | Assert |
|---|---|---|---|
| 1 | compat | `git show origin/main:bin/share` and the branch's `bin/share`, each under its own private `HOME` with the same `SHARE_TEST_IDS`, date seams, and dry tunnel seams: quick setup, add file, add folder, add live, `--host` add, `ls`, `state`, `service install` | configs, `index.tsv`, Caddyfiles, plists, stdout, stderr, and `state` JSON byte-identical; the existing suite passes unchanged |
| 2 | refuse | `--backend r2` with no `--bucket`; a bad bucket name; with `--quick`; on a profile with a `tunnel_id`; `--backend bogus` | exit 1, the usage or named message, no call logged, no config written |
| 3 | setup | dry admin path | log order: bucket GET < bucket POST < marker GET < marker PUT < DNS GET < domains GET < script GET < script PUT < subdomain POST < subdomain GET < domain PUT < healthz; config has `backend=r2`, `bucket`, `port=r2`, no `tunnel_id`, `hosts`; no plist, no Keychain tunnel item, no cloudflared call |
| 4 | setup | bucket with objects and no marker; marker for another host; r2.dev on; a bucket custom domain; a DNS record; a custom domain for another service with `--force`; subdomain read-back `true`; a script whose bindings name another host; a deployed `VERSION` above the CLI's; a 500 on the domains read | each dies before any write it guards (subdomain case before the domain PUT; others before any PUT or POST); the fixture bucket's listing unchanged |
| 5 | add | a folder with a dotfile, a symlink, a README.md, a subfolder with no index, and files named `a%b.txt`, `q?.txt`, `h#.txt`, `sp ace.txt` | the prefix listing equals the stage tree (no dotfile, no symlink, `README.html` present, the four names intact); every object PUT precedes `PUT m/<id>`, which carries `If-None-Match: *`; no `pub/`; link `https://<host>/<id>/<name>/` |
| 6 | refuse | `add 3000`, `add --host x.<zone>`, `SHARE_R2_MAX_BYTES=1024` with a 2 KiB file, `SHARE_R2_MAX_FILES=2` with 3 files, a file name with a control character, no token source, `start`, `stop`, `serve`, `service install` | exit 1 each, named message, no object PUT |
| 7 | multi-publisher | two `HOME`s on one dry bucket: A adds, B adds | each `ls` shows both rows with `by=`; B's `refresh` of A's id is refused; B's `rm` of A's id works |
| 8 | refresh | A refreshes its own share | new prefix uploaded before `PUT m/<id>` with `If-Match`; the record names the new prefix; old-prefix DELETEs after the PUT; a forged record `src` is not read (the upload comes from `r2-own`) |
| 9 | rm | rm of a snapshot; rm with `SHARE_R2_DRY_DELETE=lost` on a gated row | `DELETE m/<id>` < `GET m/<id>` (404) < object DELETEs for every nonce; lost: exit 1, no `DELETE app`, pending line kept |
| 10 | expiry | ungated and gated records forged expired | integration Worker: 404 before any prune; `ls` with a publisher token: ungated record and prefix gone, gated one kept with the waiting line; `prune` with an Access-capable token: gated record, prefix, and app gone |
| 11 | gate order | gated add, probe fixture `fail`,`fail`,`pass`x3 | object PUTs < `POST app` < every `PROBE` < `PUT m/<id>`; while any `PROBE fail` is logged, `m/<id>` is absent (background poll) and the integration Worker answers 404 for `/<id>/` |
| 12 | gate parity | SPEC-004 rows 8, 9, 10, 11, 23c, 25 on an r2 profile | same asserts, with `PUT m/<id>` for `PUBLISH` and `DELETE m/<id>` plus its 404 read before `DELETE app` |
| 13 | hits | fixture SQL answer | SQL names the dataset and `index1 = '<id>'`; `hits "abc' OR '1'='1"` refused before any call; line `3 hits, 2 visitors, last ...` |
| 14 | state, status, profiles | r2 profile with two rows beside a tunnel profile | `backend` `r2`, `mode` `named`, `serves_here` false, `schema` 1; the tunnel state has no `backend` key; `status` logs no DELETE; `profiles` logs no `m/` list for the r2 profile |
| 15 | teardown | plain; `--purge` without the admin fixture; `--purge` with a foreign script (bindings name another host); `--purge` with it | plain: config gone, dry bucket unchanged; refused purges: nothing logged past the reads; purge: every record and object gone, then `DELETE share.json` < domain DELETE < script DELETE < bucket DELETE, and the dataset line printed |
| 16 | secrets | a `curl` shim first on `PATH` recording argv, a sentinel token, add, ls, rm, hits, setup | the sentinel appears in no recorded argv, no stdout or stderr, and no file under `$root`, `$config_dir`, or `$TMPDIR` |
| 17 | Worker | `/<id>/` with index.html; with only README.html; a folder path without slash; `/<id>`; a missing file; a subfolder with no index; HEAD; `Range: bytes=0-3`; `/healthz` | 200, 200, 308, 308, 404, 404, no body, 206 with 4 bytes, `ok` plus both headers |
| 18 | Worker | `/x/..%2F<id>/f`, `/%2f<id>/f`, `/x/..%5C<id>/f`, `/<id>/a%2Ehtml`, `/x/..\<id>/f`, `/x/../<id>/f`, `/x/%2e%2e/<id>/f`, `//<id>/f`, `/<id>/%zz`, `/<ID>/f`, `/%61bc123/f`, `/<id>/50%25.v1.txt`, `/<id>/f?next=%2Fhome`, Host `f.test.` and another name, a record whose prefix names another id, a record whose `id` differs from its key, an expired record, POST | 400 x9, 404, 404, 200, 200, 404, 404, 404, 404, 405; `no-store` and `noindex` on every one |
| 19 | Worker | a 200, a 404, `/healthz` | one data point, for the 200; its blobs hold the id and 16 hex, never the IP string |
| 20 | version | rerun setup; bump `WORKER_VERSION` and `WORKER_SHA` with a changed source; a deployed version above the CLI's; source changed without the constants | no script PUT; one PUT with the new `VERSION` and `SHA` bindings; refused without `--force`; the suite's sha check fails |
| 21 | lint | `shellcheck` on every script; `/bin/bash -n bin/share`; `node --check` on the emitted Worker | clean |
| 22 | compat | `origin/main`'s `bin/share` run against an r2 profile config: `add ./x`, `ls`, `add --access`, `setup` | exit 1 at load each; no file created under the profile's root |
| 23 | join | a second `HOME`, script GET answers 403, the Worker's pair differs from the CLI's | no script, subdomain, or domain write; config written; the mismatch line printed; exit 0 |
| 24 | orphans | a prefix no record names aged 25 h; one aged 1 h; a referenced prefix aged 25 h | bare `prune` deletes only the first |
| 25 | interleavings | (a) A's refresh paused before its PUT while B rms; (b) B takes A's id while A waits in the gate; (c) A and B prune the same expired id at once; (d) `SHARE_R2_DRY_PUT=lost` on a gated publish, then a sweep; (e) `SHARE_R2_DRY_LIST=500` | (a) 412, A deletes its new prefix, no record; (b) A's publish gets 412, A deletes its app and prefix; (c) both exit 0, one set of deletes; (d) the sweep finds the record naming the app, drops the line, logs no `DELETE app`; (e) `ls` and `add` exit 1, no id picked |

### Negative controls

Each is a temporary patch that must turn the named rows red, recorded with its red run in `docs/verification/r2-backend.md`.

| Patch | Expected red |
|---|---|
| publish `m/<id>` before the gate | row 11 |
| drop the encoded-separator check from the Worker | row 18 (the `%2F`, `%5C`, `%2E` cases) |
| check the parsed pathname only, not the raw path | row 18 (the `\` case) |
| decode the id segment | row 18 (`/%61bc123/` answers 200) |
| drop the `expires` check from the Worker | row 10 |
| skip the subdomain POST | row 3 and L1 |
| drop `If-Match` from the refresh PUT | row 25a |
| delete the app without the `GET m/<id>` 404 check | rows 9 and 25d |
| skip the purge binding check | row 15 |
| write a `backend=` line into every tunnel config | row 1 |

### Live leg (`tests/e2e-r2.sh`, by hand before the release)

Inputs: `SHARE_E2E_R2_HOST` (an unused name on a zone the admin token edits), `CLOUDFLARE_API_TOKEN` (admin), `SHARE_E2E_R2_PUBLISHER_TOKEN` (bucket-scoped, made in TASK-1), optional `SHARE_E2E_ACCESS_EMAIL`. The bucket is `share-e2e-<6 hex>`; the script refuses any bucket name without that prefix, so `brand-assets` and every existing bucket are out of reach. Everything runs under mktemp `HOME`s.

| # | Step | Assert |
|---|---|---|
| L1 | admin setup | exit 0; `/healthz` 200 with this CLI's pair; subdomain reads `false,false`; `https://<worker>.<sub>.workers.dev/healthz` does not answer 200 |
| L2 | rerun setup | no script PUT |
| L3 | publisher B joins with the bucket token | exit 0; `GET workers/scripts` with B's token refused; B's `ls` empty |
| L4 | A publishes a folder with `.env` and a subfolder with no index | link 200, content equal, `.env` 404, subfolder 404, `no-store` and `noindex`, `/<id>` 308 |
| L5 | encoded and dot paths on A's share | `/x/..%2F<id>/<name>/`, `/%2F<id>/<name>/`, `/x/..%5C<id>/<name>/`, `/x/..\<id>/<name>/` answer 400; `/x/%2e%2e/<id>/<name>/` answers 400 or the share (both inside the gate), recorded |
| L6 | B lists and publishes | both `ls` show both rows |
| L7 | expiry | the admin token rewrites A's record with `expires` = now + 20; after 25 s the link is 404; A's `ls` leaves no key under the prefix |
| L8 | hits | after 90 s, `share hits <B's id>` counts the requests L6 made |
| L9 | gated (with the email) | during the gate a parallel poll of `/<id>/` never sees 200; after, `/<id>/`, `/<id>`, `/<ID>/`, `/%<hex of first char><rest>/` all 302 with `kid == aud`; `rm` leaves `GET access/apps/<uuid>` 404 |
| L10 | B's local teardown | the bucket listing and A's link unchanged |
| L11 | admin `teardown --yes --purge` | exit 0 |

Cleanup is asserted, then enforced. After L11 the script checks through the API: the script answers 404, no custom domain and no DNS record for the hostname, the bucket answers 404, no Access app named `share * <host> *`. An EXIT trap runs `teardown --yes --purge` and then a by-name fallback (domain, script, every object under the `share-e2e-` bucket, the bucket, Access apps named for the host) whatever happened before, and prints each leftover it could not delete. The Analytics Engine dataset cannot be deleted by API; the log says it ages out.

## Grounding

Live samples, 2026-09-30, read-only, through a helper that prints names, codes, and field names only (the token enters curl as `-H @<(printf ...)`):

| Claim | Command (shape) | Excerpt |
|---|---|---|
| buckets and publicity | `GET /accounts/<a>/r2/buckets`; per bucket `.../domains/custom`, `.../domains/managed` | `circle-dfoundation-raw custom domains: [] managed (r2.dev): false` (same for the other 13); `brand-assets: skipped by rule` |
| workers.dev default | `GET /accounts/<a>/workers/scripts/monitor/subdomain` | `{"enabled":true,"previews_enabled":true}` |
| REST list shape | `GET .../r2/buckets/circle-dfoundation-raw/objects?per_page=1` | `item_fields: ["custom_metadata","etag","http_metadata","key","last_modified","size","storage_class"]`, `result_info: null` |
| missing key | `GET .../objects/share-probe-does-not-exist` | `HTTP/2 404`, `content-type: application/json` |
| Analytics Engine | `POST .../analytics_engine/sql` `SHOW TABLES` | `"rows": 1` |
| custom domains | `GET /accounts/<a>/workers/domains` | `dataroom.d.foundation -> df-dataroom`, `memo.d.foundation -> df-memo` |
| wrangler path | `grep objects/\${objectName} wrangler-dist/cli.js` | `PUT`, `GET`, `DELETE` on `/accounts/${accountId}/r2/buckets/${bucketName}/objects/${objectName}`; `MAX_UPLOAD_SIZE_BYTES = 300 * 1024 * 1024` |
| introspection | `GET /accounts/<a>/tokens/permission_groups` | `{"code":9109,"message":"Unauthorized to access requested resource"}` |

Not sampled (TASK-1): bucket-scoped tokens on the REST path, conditional writes, pagination, custom-domain scopes, `curl --parallel` write-out, the edge's view of `\`.

Dry traces for the negative controls: each patch changes one line; the row's assert reads `r2-calls.log` line order, the dry bucket directory, or the Worker's answer through `tests/worker.mjs`, so the red is mechanical. For example, "publish before the gate" moves `PUT m/<id>` above `access_gate`; row 11's background poll then finds `$SHARE_R2_DRY_DIR/m/<id>` while `PROBE fail` is in the log, and the integration Worker answers 200 for `/<id>/`.

## Verification

```sh
shellcheck bin/share install.sh tests/share.sh tests/e2e.sh tests/e2e-r2.sh demo/render.sh mac/*.sh
/bin/bash -n bin/share
bash tests/share.sh          # includes the r2 section and tests/worker.mjs
```

Then by hand: `tests/e2e-r2.sh` with the inputs above; its log goes to `docs/verification/r2-backend.md`.

## After state

- [ ] `share --profile df setup f.d.foundation --backend r2 --bucket share-dfoundation` with the admin token deploys the Worker; a teammate joins with a bucket-scoped token from a laptop, and both see the same `share ls`.
- [ ] A link published from the laptop answers while the Mini is off.
- [ ] A gated link on the r2 profile prints only after the gate passes, as on the tunnel.
- [ ] `https://f.d.foundation/x/..%2F<id>/<name>` answers 400.
- [ ] The default profile (`s.han.ws`) and the `s.d.foundation` tunnel profile show no change: `shasum` of their configs and plists before and after equal.

## Acceptance Criteria (global)

1. No byte of a share is reachable before its record exists, and no record of a gated share exists before its gate passed three rounds.
2. Every path the Worker serves lies inside that share's Access destinations, and an Access app is deleted only after a fresh read shows no record naming it.
3. No token appears in argv, output, a file, a Worker binding, or an object.
4. A profile without `backend=r2` is byte-identical in files and output (row 1), and an older share refuses an r2 profile (row 22).
5. Setup never writes to a bucket that holds foreign objects or has any public route, and purge or redeploy never touches a Worker, domain, or bucket that is not this hostname's.

## Out of scope

`--host` and live shares on r2; migrating a tunnel profile's shares into a bucket; Share Bar reading an r2 default profile (it would run `api_token_cmd` on every menu open; use the Keychain form there); uploads over 300 MiB or 500 files (the upgrade is the S3 transport, multipart and outside the account API rate limit); a Worker cron; Worker-side Access JWT checks (Decisions for Han item 6).

## Decisions for Han

1. Hostname for the Dwarves r2 profile: a new name (`f.d.foundation`, proposed) beside the `s.d.foundation` tunnel profile, or move `s.d.foundation` (its current links and one gated share die at teardown).
2. Publisher tokens: one bucket-scoped token per teammate, minted by an account admin, each with an `expires_on`, versus one shared publisher token in a shared vault. Proposed: per teammate.
3. Gated publishing: Access Apps Edit is account-wide and reaches the gates in front of chat and vps-mon. Proposed: only named people get a gated-publisher token; everyone else publishes ungated.
4. The Worker `share-f-d-foundation` lives outside `dwarvesf/foundation-workers` and is deployed by the share CLI. Proposed: accept, and add it to the foundation-workers inventory note so nobody deletes it as unknown.
5. Who reruns `setup` with the admin token after a share release (the Worker upgrade and the public-bucket recheck). Proposed: Han, on each share release that bumps `WORKER_VERSION`.
6. `share hits` counts cover the Analytics Engine retention (months), with visitor IPs pseudonymized. A later option: the Worker verifies the Access JWT (`Cf-Access-Jwt-Assertion`, `aud` stored in the gated record) so a hand-deleted app fails closed at the origin too; the tunnel backend has the same gap today, so it is deferred to a spec covering both.

## Decision Log

- DEC-001: records, not an index object; the record names its content prefix, so an unreferenced prefix is a stage the Worker never serves (Han's staging requirement met with one PUT per publish instead of one copy per file).
- DEC-002: the REST object path over SigV4, wrangler, and rclone; TASK-1 switches the whole transport to SigV4 through curl's built-in flag, same token, if the REST path refuses bucket-scoped tokens or conditional writes.
- DEC-003: the Worker source is embedded in `bin/share`, versioned by `WORKER_VERSION` plus `WORKER_SHA`; no `wrangler.toml`.
- DEC-004: expiry is enforced per request by the Worker and cleaned up by any publisher's `ls` or `prune`; no Worker cron, because Access apps need a token the Worker must not hold.
- DEC-005: `teardown` on r2 is local by default; destroying the team's backend needs `--purge` and the admin token.
- Round 1 (seven fresh-context reviewers, 2026-09-30):

| Change | Why |
|---|---|
| The Worker serves only canonical raw paths (literal `\`, `//`, dot segments, control bytes, encoded separators, parsed-vs-raw mismatch all 400) | the parsed pathname already resolves `..` and `\`, so a check on it alone could serve a path the edge matched differently |
| Worker name derived from the hostname; binding, marker, and domain-service checks before every deploy, purge, or domain change; `--force` never takes another service's domain; admin token from the environment only, and `api-token` refuses to store one | a hand-edited config plus an account-wide admin token could overwrite or delete a `df-*` Worker or bucket |
| An expired gated share is removed only by a process holding an Access-proven token; each install's `access-pending` holds only its own lines | a teammate's token-less prune would have parked another install's app in a file nobody with the token reads |
| `rm` and the sweep delete an app only after a fresh `GET m/<id>` answers 404 (or the record names another app); a lost `DELETE m` stops rm | a committed-but-lost record write or a lost record delete could leave gated bytes public |
| Conditional writes are required (`If-None-Match: *` on create, `If-Match` on swap); without them on either transport, `--access` and `refresh` are refused on r2 | a refresh racing an rm could resurrect a gated share after its app was deleted; an id collision during a gate wait could overwrite a gated record |
| Join mode accepts any Worker version at the live check; `WORKER_VERSION` ordinal plus `WORKER_SHA`, no silent downgrade, `X-Share-Records` for the record contract | a teammate on a newer share could never finish setup, and an admin on an older share would silently downgrade the Worker |
| Orphan prefixes older than 24 h are deleted by bare `prune` | a crashed upload's storage cost had no bound |
| `port=r2` sentinel in r2 configs | an older share would have treated an r2 profile as a named tunnel and written `pub/` or created Access apps |
| Snapshot and `rand_id` fail closed; 429/5xx retries with `Retry-After`; 500-file cap; keys through `urlenc` with a read-back; control-character names refused; token never in the curl config file | an empty listing on error, the account API rate limit, and filenames that change a key |
| `refresh` reads the source path from the local `r2-own` file, never a record | a forged record could make a victim upload any local path |
| Publisher scopes marked UNVERIFIED with Read and Write; TASK-1 gains (i) curl parallel and (j) the rate limit; every build task names its TASK-1 dependency; TASK-5 and TASK-6 split; `Depth:` and `## Grounding` added | the scope table assumed Write alone lists and reads; an autonomous run could build on the wrong transport |
| Visitor hash salted with a Worker secret and called pseudonymous; Account Analytics Read marked optional and account-wide; publishers can read gated bytes, stated | a public salt brute-forces IPv4 in minutes; honest blast radius |
| Cost, liveness, owner, and purge's dataset note added | sustainability review |
| Not taken: `custom_metadata` for one-call listings (the REST PUT's metadata header is unverified; the parallel record fetch keeps `ls` to one round of requests); a CSP sandbox on HTML (the tunnel backend serves the same shares without one; a later spec covers both) | scope |
