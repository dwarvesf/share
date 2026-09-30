# SPEC-007: R2 storage backend per profile

Status: DRAFT
Lane: full (external provider, authz on the publish path, a new public surface, credentials for several people)
References: `bin/share` `cmd_setup`, `cmd_add`, `stage_copy`, `stage_publish`, `rows`, `row`, `rand_id`, `cmd_rm`, `cmd_prune`, `cmd_hits`, `cmd_state`, `cmd_teardown`, `access_*`, `api_token_resolve`, `cf_try`; SPEC-004 (Access gate), SPEC-005 (profiles), ADR-0002 (a mode is fixed at setup), ADR-0005, ADR-0006.

## Problem

Every link of a profile lives on one machine. When the Mac Mini sleeps, reboots, or loses its uplink, every Dwarves link answers Cloudflare 530. Only someone with a shell on that machine can publish, so a teammate who wants to share a report asks Han. A profile needs a backend that serves from Cloudflare itself and accepts uploads from several people, while the per-link Access gate keeps its guarantees and existing installs change by zero bytes.

## Context (research, 2026-09-30)

Read-only probes of the Dwarves LLC account with the Toolkit token (through 1Password Connect; no value, key, or account id is quoted here).

| Item | State | Evidence |
|---|---|---|
| R2 | enabled; 15 buckets, location APAC | `GET r2/buckets` |
| Public buckets | only `brand-assets` (custom domain `assets.d.foundation`); every other bucket has no custom domain and r2.dev off | `GET r2/buckets/<b>/domains/custom`, `.../domains/managed` for each bucket except `brand-assets`, which was not probed |
| Workers | 44 scripts, `df-*` naming; custom domains in use (`dataroom.d.foundation`, `memo.d.foundation`, `status.d.foundation`, ...) | `GET workers/scripts`, `GET workers/domains` |
| workers.dev defaults | an existing script (`monitor`) reads `enabled: true, previews_enabled: true` | `GET workers/scripts/monitor/subdomain`; a new share Worker must turn both off, or `<script>.<sub>.workers.dev` would serve content outside the Access app's hostname |
| Analytics Engine | enabled; one dataset, SQL API answers | `POST analytics_engine/sql` `SHOW TABLES` |
| D1 | enabled; 5 databases | `GET d1/database` |
| `s.d.foundation` | a live tunnel profile (`share-s-d-foundation`, proxied CNAME) with one gated share's Access app | `GET dns_records`, `cfd_tunnel`, `access/apps` |
| R2 object REST endpoint | `GET /accounts/<a>/r2/buckets/<b>/objects?prefix=...` answers 200 with a JSON array whose items carry `key`, `etag`, `size`, `last_modified`, `http_metadata`, `custom_metadata`, `storage_class`; a missing key answers 404 JSON; `result_info` was `null` on a one-item page (pagination UNVERIFIED) | probe on a non-public bucket, field names only |
| wrangler's own upload path | `wrangler r2 object put` (4.133.0) calls `PUT /accounts/<a>/r2/buckets/<b>/objects/<key>` with the API token, 300 MiB cap, headers `content-type` and friends; `get` and `delete` use the same path; wrangler has no object list verb | `wrangler-dist/cli.js`, `putRemoteObject`, `MAX_UPLOAD_SIZE_BYTES` |
| Token introspection | `tokens/permission_groups` answers 9109 with the Toolkit token | scopes can be exercised, not listed |
| Toolkit token reach | lists every bucket on the account, `payout`, `invoice`, and `dataroom-kyc-evidence-prod` included | it must never be a publisher's R2 token |

## Picture

```
 publisher A (Mini)          publisher B (laptop)               visitor
 share --profile df add      share --profile df add             https://f.d.foundation/<id>/<name>
        |                           |                                   |
        | curl, API token (header file, never argv)                     v
        +-------------+-------------+                      Cloudflare edge: TLS, Access app on
                      v                                     f.d.foundation/<id>, /<id>/* (gated ids)
        Cloudflare REST: /accounts/<a>/r2/buckets/<b>/objects                    |
                      |                                                          v
                      v                                    Worker share-f-d-foundation (custom domain
        R2 bucket (private: no r2.dev, no custom domain)   only; workers.dev and previews off)
          share.json               marker: {v:1, host}       |  400 on %2F %5C %2E in the path
          m/<id>                   one record per share  <---+  GET m/<id>: none, expired, or
          o/<id>.<nonce>/<path>    the snapshot bytes    <---+    bad prefix -> 404
                                                              |  index.html, README.html, slash redirect
                                                              |  no-store, noindex on every answer
                                                              +->  Analytics Engine: one point per <400
 A prefix no record points at is a stage: the Worker reaches bytes only through m/<id>.
 Live dev-server links (share add 3000) stay on a tunnel profile.
```

## Design

### Approaches considered

| Question | Options | Chosen, one-line reason |
|---|---|---|
| Uploader transport | wrangler `r2 object put`; S3 API through `curl --aws-sigv4`; rclone; curl against the REST object path | REST object path through curl: the same endpoint Cloudflare's own wrangler calls, JSON in and out, the existing header-file token, and no new dependency. wrangler adds node, one process per file, and no list verb. SigV4 and rclone add a second credential form, XML listings, or a dependency. SigV4 is the fallback in TASK-1. |
| Shared index | one index object with ETag optimistic concurrency; D1; one record object per share | one record per share (`m/<id>`): every write touches only its own key, so there is no read-modify-write to protect. A single index object makes every add and rm contend on one key, and a lost update drops a row. D1 adds a resource, a scope, a binding, and a database read on every request. |
| Stage then publish | copy objects from a staging prefix into the served one; a publish flag in object metadata; a record that names the prefix | the record names the prefix. R2 has no rename, so a copy costs one call per file. With the record as the only path to the bytes, one `PUT m/<id>` publishes, and a new record swaps a refresh atomically. |
| Worker delivery | a separate `worker/` file shipped by the formula; wrangler with a `wrangler.toml`; source embedded in `bin/share`, uploaded by curl | embedded: `install.sh` over curl ships `bin/share` alone, and the Homebrew formula stays unchanged. The multipart upload is one `PUT workers/scripts/<name>`. |
| Folder listing | generated by the Worker at request time | generated at stage time by `gen_index`, as today, and uploaded as `index.html`; the Worker only resolves index files. |
| Expiry | object lifecycle rules; a Worker cron; the record's `expires` checked per request | per request: a link dies at its second, earlier than the hourly prune today. Records and bytes are deleted by the next `ls` or `prune` from any publisher. A cron would need an Access token in the Worker, which ADR-0006 rules out. |
| Visit counts | Workers Logs; a counter object; Analytics Engine | Analytics Engine: writes never block a response, `share hits` reads it with one SQL call. |

### Selecting the backend

- `share [--profile <p>] setup <hostname> --backend r2 --bucket <name>` writes `backend=r2` into the profile's config. `--backend tunnel` or no flag is today's setup, byte for byte. A profile has one backend; switching goes through `teardown` (the ADR-0002 stance).
- `--backend r2` refuses `--quick`, `--tunnel-name`, `--login`, and `--no-service` (nothing to install): `usage: share setup <hostname> --backend r2 --bucket <name> [--force]`.
- Config keys of an r2 profile: `backend=r2`, `hostname=`, `zone=`, `bucket=`, `worker=share-<host-with-dashes>`, `dataset=share_<host-with-underscores>`, plus a kept `api_token_cmd=`. No `tunnel_id`, `port`, `hosts`, or `mode`.

### Setup (admin, once per hostname)

Order, each step verified before the next; every refusal comes before the first write.

| Step | Call | Refuse or stop when |
|---|---|---|
| 1 | the hostname, bucket name (`^[a-z0-9][a-z0-9-]{1,61}[a-z0-9]$`), and other-profile checks (SPEC-005 `other_cfg hostname`) | bad name, hostname of another profile, a tunnel config in this profile |
| 2 | token: `CLOUDFLARE_API_TOKEN` or the profile's stored API token (`api_token_resolve`); zone and account (`access_account`) | no token: the O1-style block names the admin scopes and a publisher-scope link |
| 3 | `GET r2/buckets/<b>`; if 404, `POST r2/buckets {name}` | the bucket exists, holds objects, and has no `share.json`; `domains/managed.enabled` is true; `domains/custom` is non-empty. So `brand-assets` (objects, custom domain) is refused before any write |
| 4 | `GET objects/share.json`; absent -> `PUT share.json` `{"v":1,"host":"<hostname>"}` | the marker names another hostname |
| 5 | DNS: `GET zones/<z>/dns_records?name=<hostname>` | a record exists that is not this Worker's custom domain (`GET workers/domains?hostname=`), unless `--force` |
| 6 | Worker: `GET workers/scripts/<worker>/settings`; deploy when absent or its `REV` binding differs from this CLI's rev | 401/403 on the read: join mode (below), no deploy |
| 7 | `POST workers/scripts/<worker>/subdomain {"enabled":false,"previews_enabled":false}`, then `GET` it | the read-back is not `false,false`: die; the Worker has no custom domain yet, so nothing is exposed |
| 8 | `PUT workers/domains {hostname, service:<worker>, zone_id, environment:"production"}` | an API error |
| 9 | live check: `https://<hostname>/healthz` answers `200 ok` with `X-Share-Rev: <rev>` three times in a row, up to `SHARE_R2_WAIT` (300 s, cert issuance on a new name) | timeout: die naming the hostname; the config is not written |
| 10 | `write_config_r2` | |

Deploy (`r2_deploy`): one `curl -X PUT .../workers/scripts/<worker>` with two multipart parts: `metadata` (`{"main_module":"share.js","compatibility_date":"<pinned>","bindings":[{"type":"r2_bucket","name":"BUCKET","bucket_name":"<b>"},{"type":"analytics_engine","name":"HITS","dataset":"<dataset>"},{"type":"plain_text","name":"HOST","text":"<hostname>"},{"type":"plain_text","name":"REV","text":"<rev>"}]}`) and `share.js` (`type=application/javascript+module`). The source is emitted by `worker_js` from a quoted heredoc in `bin/share`, written to a file in `$root` and read back (never a heredoc inside `$( )`, per CLAUDE.md). `rev` is the first 12 hex chars of the source's sha256. A git tag of share pins the Worker; a rollback is an older share and a setup rerun.

Join mode: a teammate with a publisher token runs the same command. Steps 1 to 5 read only; the marker must name this hostname; step 6 answers 403, so there is no deploy; step 9 runs. A rev mismatch prints `the Worker at <host> runs rev <x>; this share ships <y>; ask whoever holds the admin token to rerun '<me> setup <host> --backend r2 --bucket <b>'` and continues, because the record format (`v:1`) is the contract between CLI versions. Setup then writes the config. Nothing on Cloudflare changes in join mode.

### Objects and records

| Key | Content | Written by |
|---|---|---|
| `share.json` | `{"v":1,"host":"<hostname>"}` | setup |
| `m/<id>` | the record, JSON: `{"v":1,"id","name","src","added","expires","opts","prefix","by"}`. `opts` is the index opts string (`noindex`, `access=<uuid>`, `access_rule=<rule>`), `prefix` is `o/<id>.<nonce>/`, `by` is the publisher's `this_host` | add, refresh (swap), rm and prune (delete) |
| `o/<id>.<nonce>/<path>` | the stage tree, byte for byte: what `stage_copy` built (dotfiles and symlinks skipped, markdown rendered, `gen_index` applied) | add, refresh |

`rows()` stays the only index reader and validator. On an r2 profile its input is a per-process snapshot: `GET objects?prefix=m/` (every page), one `GET m/<id>` per key, each record turned into the six index fields by jq, into `$root/.r2-index.XXXXXX`; the awk validator runs unchanged, plus a check that `prefix` equals `o/<id>.` followed by 8 hex and `/`. The snapshot is refreshed after this process writes a record. `rand_id` also refuses an id with an existing `m/<id>`.

### Per verb

| Verb | r2 behavior |
|---|---|
| `add <file\|dir>` | `stage_copy` as today; refuse any file above 300 MiB (`SHARE_R2_MAX_BYTES`); upload every stage file to `o/<id>.<nonce>/` in one `curl --parallel --parallel-max 8` run from a generated config, each transfer's `%{http_code}` checked (all 2xx or the add dies); then `PUT m/<id>` (publish); read the record back and compare `prefix`; trash the local stage. The EXIT trap deletes a held, unpublished prefix, best effort |
| `add --access` | SPEC-004 unchanged up to the publish step: prepare, stage, upload to the prefix, intent line, app, gate. The publish step under the `index` lock: exact pending line present, `PUT m/<id>`, drop the line. The prefix is the stage: no record exists during the gate wait, so the Worker answers 404 behind the login |
| `add <port>`, `add --host` | refused before any write: `live shares and --host need a tunnel profile; this profile serves from R2` |
| `ls` | rows from the snapshot; each line gains `by=<host>`; prune in `listing` mode first |
| `refresh <id>` | only on the machine named in `by`, else `the source of <id> lives on <by>; refresh it there`. Upload to a new nonce prefix, `PUT m/<id>` with the new prefix (the swap), read back, then delete the old prefix |
| `rm <id>` | SPEC-004 order: pending line for a gated row; `DELETE m/<id>` (the link 404s from here); list and delete `o/<id>.<nonce>/`; then the Access app |
| `prune` | expired records from the snapshot, each through `rm` in prune mode; Access apps defer to the local `access-pending` exactly as SPEC-004 (owner 0 without a token) |
| `hits <id>` | `POST analytics_engine/sql`: `SELECT SUM(_sample_interval) AS hits, COUNT(DISTINCT blob2) AS visitors, MAX(timestamp) AS last FROM <dataset> WHERE index1 = '<id>' FORMAT JSON`; the id and dataset are validated before they reach SQL; the output line is today's `N hits, M visitors, last YYYY-MM-DD HH:MM` |
| `status` | `r2 backend: https://<host>/ (Worker rev <x>)` with the rev-mismatch line when it applies, then `ls`; no prune (SPEC-004 round 8: status is a read) |
| `state` | `state` `serving` when set up, `ready` from one `/healthz` probe (2 s), `mode` `named`, `hosts` `""`, `serves_here` and `service` false, shares from the snapshot, plus `"backend":"r2"`, present on r2 profiles only; `schema` stays 1 |
| `start`, `stop`, `serve`, `service` | refused: `an r2 profile serves from Cloudflare; nothing runs on this machine ('<me> rm <id>' unpublishes a link)` |
| `teardown [--yes]` | local only: the config and the stored API token go; the bucket, the Worker, and every share stay for the other publishers. Says so |
| `teardown --yes --purge` | admin token; refuses before any change unless `GET workers/scripts/<worker>/settings` and `GET r2/buckets/<b>` both answer 200. Then every share through `rm` (gated first), `access_sweep`, `DELETE share.json`, `DELETE workers/domains/<id>`, `DELETE workers/scripts/<worker>`, the bucket only when its listing is empty (else the remaining key count is named), then the local config. The dispatch passes every argument (`shift; cmd_teardown "$@"`) |
| `profiles` | unchanged; an r2 profile reports its `state` host |

### Worker contract

Everything below holds for every request; the Worker reads no secret and holds no API token.

| Request | Answer |
|---|---|
| Host other than `env.HOST` | 404 |
| method other than GET or HEAD | 405 |
| raw path (before `?`) matches `%2f`, `%5c`, or `%2e`, any case | 400 (Caddy's `@encsep` rule) |
| `/healthz` | `200 ok`, header `X-Share-Rev: <REV>` |
| first segment is not exactly 6 lowercase hex chars (no decoding: `/ABC123/` and `/%61bc123/` are 404) | 404 |
| no `m/<id>`, a record whose `v` is not 1, whose `prefix` is not `o/<id>.` plus 8 hex plus `/`, or whose `expires` is past (`expires > 0 && now > expires`) | 404 |
| `/<id>` | 308 to `/<id>/` |
| a path ending in `/` | `<prefix><rest>index.html`, then `README.html`, else 404 |
| any other path | the object `<prefix><decoded rest>`; missing, but `<key>/index.html` or `<key>/README.html` exists -> 308 to `<path>/`; else 404 |
| every answer, errors included | `Cache-Control: no-store`, `X-Robots-Tag: noindex, nofollow` |
| a hit (status < 400, not `/healthz`) | `HITS.writeDataPoint({indexes:[id], blobs:[id, sha256(cf-connecting-ip + HOST) first 16 hex]})`; the raw IP is never written |

`Content-Type` comes from a fixed extension map in the Worker (html, css, js, mjs, json, txt, md, csv, xml, svg, png, jpg, jpeg, gif, webp, ico, pdf, mp4, webm, mp3, wav, woff, woff2, zip, wasm), `application/octet-stream` otherwise. `Range` and conditional request headers pass to `BUCKET.get(key, {range, onlyIf})`, so media seeks as it does through Caddy. Every path the Worker serves starts with `/<id>/` or is `/<id>`, both inside the Access destinations `<host>/<id>` and `<host>/<id>/*`, and the Worker never decodes the id segment, so it never serves a path the edge would match differently.

### Token scopes

| Role | Scopes | Used by |
|---|---|---|
| admin (setup, purge, redeploy) | Workers Scripts: Edit; Workers R2 Storage: Edit (bucket create and settings); Zone: Read; the custom-domain scopes TASK-1 pins (candidates: Zone Workers Routes: Edit, DNS: Edit) | setup, `teardown --purge` |
| publisher (every teammate) | Workers R2 Storage Bucket Item: Write, resource: the share bucket only; Zone: Read; Account Analytics: Read (`hits`); plus SPEC-004's Access scopes only for `--access` | add, ls, refresh, rm, prune, hits, state |

The publisher token is stored per profile with SPEC-004's `share api-token` (`--cmd` or the Keychain item). An account-wide R2 token reaches every bucket (`payout`, `invoice`, `dataroom-kyc-evidence-prod`); the docs and the O1-style block name the bucket-scoped form, and the Toolkit token is never suggested for it.

### What stays tunnel-only

Live dev-server links (`add <port>`), own hostnames (`--host`, a later spec can map fqdn -> id in the Worker), quick mode, and the login service. An r2 profile and a tunnel profile run side by side on one machine (SPEC-005), so `share --profile df-live add 3000` keeps working.

## Byte-identity with no flag

A profile without `backend=r2` runs every current code path unchanged: every r2 branch is guarded by `backend == r2`, read once at load. Byte-identical means the files share writes (config, `index.tsv`, Caddyfile, plist and unit, Keychain service names) and the stdout, stderr, and `state` JSON of every existing verb. The usage header gains two lines, the only text change a tunnel install sees.

## Files

- `bin/share`: `backend` load, `write_config_r2`, `cmd_setup_r2`, `r2_call` (non-dying, on `cf_try`'s globals and header-file token), `r2_put_tree` (parallel curl), `r2_list`, `r2_delete_prefix`, `r2_snapshot` feeding `rows()`, `worker_js`, `r2_deploy`, the per-verb branches above, the usage lines, one skill row.
- `tests/share.sh`: an r2 section under `SHARE_R2_DRY=1`.
- `tests/worker.mjs`: Worker unit and integration checks under node, skipped with a `SKIP` line when node is absent.
- `tests/e2e-r2.sh`: the live leg.
- `README.md` (Features row, a "Serve from R2" section), `docs/how-it-works.md` (an R2 section with the picture and the Worker table), `docs/setup.md` (admin and publisher tokens), ADR (next free number) for the record-per-share and embedded-Worker decisions, `docs/verification/r2-backend.md`.

## Failure modes

| Failure | Detection | Behavior |
|---|---|---|
| upload fails mid-tree | any transfer's code not 2xx | die; no record was written, so nothing is served; the EXIT trap deletes the prefix; a hard kill leaves an unreferenced prefix (storage only) |
| record PUT lost (000) | `r2_call` code | die; a `GET m/<id>` names the outcome in the message; a gated add keeps its pending line |
| two publishers pick one id | `GET m/<id>` in `rand_id`, then the read-back compares `prefix` | the loser deletes its prefix and dies with `rerun`; a write that lands between the other side's read-back and its exit is the residual (1 in 16.7M per concurrent pair), closed by `If-None-Match: *` when TASK-1 finds the REST path honors it |
| refresh races rm | the record read before upload | the refresh re-reads `m/<id>` before its PUT and aborts when it is gone; the window between that read and the PUT is the residual, closed by `If-Match: <etag>` when TASK-1 finds it honored |
| a forged or corrupt record | `rows()` validation; the Worker's prefix check | skipped by the CLI, 404 at the Worker; never a path into another share's prefix |
| workers.dev or preview left on | setup step 7 read-back | die before the custom domain exists |
| bucket turned public later (r2.dev or a custom domain) | `status` reads `domains/managed` and `domains/custom` with an admin token only; otherwise not detected | documented: a public bucket bypasses every gate; the setup refusal covers the initial state |
| Worker rev older than the CLI | `/healthz` header | a warning in `setup` and `status`; records stay `v:1` |
| an old share CLI on an r2 profile | the config has no `tunnel_id` | today's code dies at `need_host`-style checks or `serve`'s missing token; no write, no data loss |
| Access app on a Worker custom domain does not enforce | the SPEC-004 gate, unchanged | the gate times out, the app and the prefix are deleted, nothing is published |

## Task Breakdown

- [ ] TASK-1: spike on a throwaway bucket and hostname with throwaway tokens. Record in `docs/implementation-notes/r2-backend.md`: (a) a bucket-item-scoped token against the REST object PUT, GET, DELETE, and list; on refusal, switch the transport to `curl --aws-sigv4 "aws:amz:auto:s3"` with S3 credentials derived from the same token (key id = token id, secret = sha256 of the token), credentials passed through `-K <(...)`, listing with `encoding-type=url`; (b) list pagination fields; (c) whether the REST PUT honors `If-None-Match: *` and `If-Match`; (d) whether object keys need `/` encoded in the URL; (e) the minimal custom-domain scopes; (f) the Analytics Engine distinct-visitor query (fallback: `GROUP BY blob2` counted client-side); (g) an Access app on a Worker custom domain path redirects with `kid == aud`; (h) the edge and Worker view of `%2e%2e`, `%61`, `//`. AC: every UNVERIFIED line in this spec is answered or amended.
- [ ] TASK-2: `backend` load, `write_config_r2`, setup refusals, the byte-identity check. AC: rows 1, 2.
- [ ] TASK-3: `worker_js`, rev, `tests/worker.mjs`. AC: rows 17 to 19.
- [ ] TASK-4: `r2_call`, `r2_put_tree`, `r2_list`, `r2_delete_prefix`, `r2_snapshot` into `rows()`, the dry seam. AC: rows 5, 7, 16.
- [ ] TASK-5: `cmd_setup_r2` with deploy, subdomain off, custom domain, live check, join mode. AC: rows 3, 4, 20.
- [ ] TASK-6: add, ls, refresh, rm, prune, hits, status, state, the refusals. AC: rows 5 to 10, 13, 14.
- [ ] TASK-7: gated add and rm on r2 (SPEC-004 parity). AC: rows 11, 12.
- [ ] TASK-8: teardown local and `--purge`. AC: row 15.
- [ ] TASK-9: `tests/e2e-r2.sh` and its run log. AC: every L row passes and the cleanup assertions hold.
- [ ] TASK-10: docs, ADR, skill row. AC: each doc claim matches the code line it describes.

## Test plan

Local rows run in `tests/share.sh` with `SHARE_R2_DRY=1`: `r2_call` reads and writes a directory, `$SHARE_R2_DRY_DIR/<key>` (one bucket shared by every `HOME` in a test), and appends `METHOD key` to `$root/r2-calls.log`; Worker, domain, subdomain, and SQL calls answer from fixtures and log the same way. `SHARE_R2_DRY` is honored only with `SHARE_TUNNEL=0` and a hostname under `.test`. Order is asserted by line numbers in the log, never by independent greps. `tests/worker.mjs` imports the emitted Worker source and drives `fetch(request, env)` with an in-memory `BUCKET` (get, put, head, list; `range` and `onlyIf` honored), a recording `HITS`, and `HOST`/`REV`; its integration mode serves the Worker over `node:http` on a loopback port with a `BUCKET` backed by `$SHARE_R2_DRY_DIR`, so a bucket written by `share add` is fetched through the real Worker logic with curl.

### Coverage matrix

| # | Category | Case | Assert |
|---|---|---|---|
| 1 | compat | `git show origin/main:bin/share` and the branch's `bin/share`, each run under its own private `HOME` with the same `SHARE_TEST_IDS`, fixed date seams, and the dry tunnel seams: quick setup, add file, add folder, add live, `--host` add, `ls`, `state`, `service install` | configs, `index.tsv`, Caddyfiles, plists, stdout, stderr, and `state` JSON are byte-identical; the existing suite passes unchanged |
| 2 | refuse | `--backend r2` with no `--bucket`; a bad bucket name; with `--quick`; on a profile with a `tunnel_id`; `--backend bogus` | exit 1, the usage or named message, no call logged, no config written |
| 3 | setup | dry happy path | log order: bucket GET < bucket POST < marker GET < marker PUT < script GET < script PUT < subdomain POST < subdomain GET < domain PUT < healthz; the config has `backend=r2`, `bucket`, `worker`, `dataset` and no `tunnel_id`, `port`, `hosts`; no plist, no Keychain tunnel item, no cloudflared call |
| 4 | setup | bucket holding objects with no marker; the marker naming another host; `domains/managed` enabled; a custom domain on the bucket; a DNS record for the hostname; subdomain read-back `true` | each dies before any PUT or POST; the subdomain case dies before the domain PUT; the fixture bucket's listing is unchanged |
| 5 | add | a folder with a dotfile, a symlink, a README.md, and a subfolder with no index | objects exist exactly for the stage tree under `o/<id>.<nonce>/` (no dotfile, no symlink, `README.html` present); every object PUT line precedes `PUT m/<id>`; no `pub/` created; the printed link is `https://<host>/<id>/<name>/` |
| 6 | refuse | `add 3000`, `add --host x.<zone>`, a 2 KiB file with `SHARE_R2_MAX_BYTES=1024`, no token source, `start`, `stop`, `serve`, `service install` | exit 1 each with the named message; no object PUT logged |
| 7 | multi-publisher | two `HOME`s on one dry bucket: A adds, B adds | `ls` under each shows both rows with `by=` A and B; B's `refresh` of A's id is refused naming A; B's `rm` of A's id works |
| 8 | refresh | A refreshes its own share | new prefix uploaded before `PUT m/<id>`; the record names the new prefix; old-prefix DELETEs come after the PUT |
| 9 | rm | rm of a snapshot | `DELETE m/<id>` precedes every object DELETE; no key under the prefix remains |
| 10 | expiry | a record forged with `expires` in the past | through the integration Worker: 404 before any prune; after `ls`: record and prefix gone |
| 11 | gate order | gated add, probe fixture `fail`,`fail`,`pass`x3 | order: object PUTs < `POST app` < every `PROBE` < `PUT m/<id>`; while any `PROBE fail` is logged, `m/<id>` is absent (a background poll of the dry dir) and the integration Worker answers 404 for `/<id>/` |
| 12 | gate parity | SPEC-004 rows 8, 9, 10, 11, 23c, 25 rerun on an r2 profile | the same asserts, with `PUT m/<id>` in place of `PUBLISH` and `DELETE m/<id>` before `DELETE app` |
| 13 | hits | fixture SQL answer | the logged SQL names the dataset and `index1 = '<id>'`; an id argument of `abc' OR '1'='1` is refused before any call; the line reads `3 hits, 2 visitors, last ...` |
| 14 | state, status | r2 profile with two rows | `backend` is `r2`, `mode` `named`, `serves_here` false; `schema` 1; the tunnel profile's state has no `backend` key; `status` logs no DELETE |
| 15 | teardown | plain `teardown --yes`; `--purge` without the admin fixture; `--purge` with it | plain: config gone, the dry bucket unchanged; refused purge: nothing logged past the two GETs; purge: every record and object gone, then `DELETE share.json` < domain DELETE < script DELETE < bucket DELETE |
| 16 | secrets | a `curl` shim first on `PATH` recording argv, a sentinel token, one add, ls, rm, hits, setup | the sentinel never appears in the recorded argv or in share's stdout or stderr |
| 17 | Worker | unit: `/<id>/` with index.html; with only README.html; a folder path with no slash; `/<id>`; a missing file; a subfolder with no index; HEAD; `Range: bytes=0-3`; `/healthz` | 200 index, 200 README, 308 to the slash, 308, 404, 404, HEAD with no body, 206 with 4 bytes, `ok` plus `X-Share-Rev` |
| 18 | Worker | encoded and forged paths: `/x/..%2F<id>/f`, `/%2f<id>/f`, `/x/..%5C<id>/f`, `/<id>/a%2Ehtml`, `/<ID>/f`, `/%61bc123/f` (id `abc123`), `/<id>/50%25.v1.txt`, `/<id>/f?next=%2Fhome`, a foreign Host, a record whose prefix names another id, an expired record, POST | 400, 400, 400, 400, 404, 404, 200, 200, 404, 404, 404, 405; `no-store` and `noindex` on every one of them |
| 19 | Worker | hits: a 200, a 404, `/healthz` | exactly one data point, for the 200; its blobs hold the id and 16 hex chars, never the client IP string |
| 20 | rev | setup rerun with the same source; with one byte changed in `worker_js` | no script PUT; one script PUT, and the new `REV` binding equals the new sha256 prefix |
| 21 | lint | `shellcheck` on every script; `/bin/bash -n bin/share` (3.2); `node --check` on the emitted Worker | clean |

### Negative controls

Each is a temporary patch that must turn the named rows red, recorded with its red run in `docs/verification/r2-backend.md`.

| Patch | Expected red |
|---|---|
| publish `m/<id>` before the gate (move the PUT above `access_gate`) | row 11 |
| drop the `%2f|%5c|%2e` check from the Worker | row 18 (four 400 cases) |
| drop the `expires` check from the Worker | row 10 |
| skip the subdomain POST in setup | row 3 (order) and L5 |
| decode the id segment in the Worker | row 18 (`/%61bc123/` answers 200) |
| write a `backend=` line into every tunnel config | row 1 |

### Live leg (`tests/e2e-r2.sh`, by hand before the release)

Inputs: `SHARE_E2E_R2_HOST` (an unused name on a zone the admin token edits), `CLOUDFLARE_API_TOKEN` (admin scopes), `SHARE_E2E_R2_PUBLISHER_TOKEN` (bucket-scoped, made in TASK-1), optional `SHARE_E2E_ACCESS_EMAIL`. The bucket is `share-e2e-<6 hex>`; the script refuses any bucket name without that prefix, so `brand-assets` and every existing bucket are out of reach. Everything runs under a mktemp `HOME` and profile.

| # | Step | Assert |
|---|---|---|
| L1 | admin setup | exit 0; `/healthz` 200 with the rev; `GET workers/scripts/<worker>/subdomain` is `false,false`; `https://<worker>.<sub>.workers.dev/healthz` does not answer 200 |
| L2 | rerun setup | no script PUT (rev equal); exit 0 |
| L3 | publisher B joins with the bucket token in a second `HOME` | exit 0; `GET workers/scripts` with B's token is refused (proves scope); B's `ls` is empty |
| L4 | A publishes a folder with `.env` and a subfolder with no index | link 200, content equal, `.env` 404, subfolder 404, `no-store` and `noindex` present, `/<id>` 308 |
| L5 | encoded paths on A's share | `/x/..%2F<id>/<name>/`, `/%2F<id>/<name>/`, `/x/..%5C<id>/<name>/` answer 400 |
| L6 | B lists and publishes | B's `ls` shows A's row and its own; A's `ls` shows both |
| L7 | expiry | the admin token rewrites A's record with `expires` = now + 20; after 25 s the link is 404; A's `ls` then leaves no key under the prefix |
| L8 | hits | after 90 s, `share hits <B's id>` reports at least the requests L6 made |
| L9 | gated (with `SHARE_E2E_ACCESS_EMAIL`) | during the gate a parallel poll of `/<id>/` never sees 200; after, `/<id>/`, `/<id>`, `/<ID>/`, `/%<hex of first char><rest>/` all 302 with `kid == aud`; `rm` leaves `GET access/apps/<uuid>` 404 |
| L10 | B's local teardown | the bucket listing and A's link unchanged |
| L11 | admin `teardown --yes --purge` | exit 0 |

Cleanup is asserted, then enforced. After L11 the script checks through the API: the script answers 404, no custom domain for the hostname, no DNS record for it, the bucket answers 404, no Access app named `share * <host> *`. An EXIT trap runs `teardown --yes --purge` and then a by-name fallback (domain, script, every object under the `share-e2e-` bucket, the bucket, Access apps named for the host) whatever happened before, and prints each leftover it could not delete. The Analytics Engine dataset cannot be deleted by API; it ages out after its retention, and the log says so.

## Verification

```sh
shellcheck bin/share install.sh tests/share.sh tests/e2e.sh tests/e2e-r2.sh demo/render.sh mac/*.sh
/bin/bash -n bin/share
bash tests/share.sh          # includes the r2 section and tests/worker.mjs when node is present
```

Then by hand: `tests/e2e-r2.sh` with the inputs above; its log goes to `docs/verification/r2-backend.md`.

## After state

- [ ] `share --profile df setup f.d.foundation --backend r2 --bucket share-dfoundation` on the Mini deploys the Worker; a teammate joins with a bucket-scoped token from a laptop, and both see the same `share ls`.
- [ ] A link published from the laptop answers while the Mini is off.
- [ ] A gated link on the r2 profile prints only after the gate passes, as on the tunnel.
- [ ] `https://f.d.foundation/x/..%2F<id>/<name>` answers 400.
- [ ] The default profile (`s.han.ws`) and the `s.d.foundation` tunnel profile show no change: `shasum` of their configs and plists before and after equal.

## Acceptance Criteria (global)

1. No byte of a share is reachable before its record exists, and no record of a gated share exists before its gate passed three rounds.
2. Every path the Worker serves lies inside that share's Access destinations.
3. No token appears in argv, output, a Worker binding, or an object.
4. A profile without `backend=r2` is byte-identical in files and output (row 1).
5. Setup never writes to a bucket that holds foreign objects or has any public route.

## Out of scope

`--host` and live shares on r2; migrating a tunnel profile's shares into a bucket; an orphan-prefix sweep (a prefix a hard kill left with no record is unreachable, and costs storage only; the upgrade is a `prune` pass that lists `o/` ids with no record older than a day); Share Bar reading an r2 default profile (it would run `api_token_cmd` on every menu open: use the Keychain form there); uploads over 300 MiB (the upgrade is multipart through the S3 API); a Worker cron.

## Decisions for Han

1. Hostname for the Dwarves r2 profile: a new name (`f.d.foundation`, proposed) beside the `s.d.foundation` tunnel profile, or move `s.d.foundation` (its current links and one gated share would die at teardown).
2. Publisher tokens: one bucket-scoped token per teammate, minted by an account admin, versus one shared publisher token in a shared 1Password vault. Proposed: per teammate, so a leaver's token can be revoked alone.
3. The Worker `share-f-d-foundation` lives outside `dwarvesf/foundation-workers` and is deployed by the share CLI. Proposed: accept, and add the name to the foundation-workers inventory note so nobody deletes it as unknown.
4. `share hits` on r2 reads Analytics Engine: counts cover the dataset's retention (months), not forever as `access.log` does, and visitor IPs are stored as salted hashes.

## Decision Log

- DEC-001: records, not an index object; the record names its content prefix, so an unreferenced prefix is a stage the Worker never serves (Han's staging requirement met with one PUT per publish instead of one copy per file).
- DEC-002: the REST object path over SigV4, wrangler, and rclone; SigV4 through curl's built-in flag stays the fallback, reachable with the same token, if TASK-1 finds bucket-scoped tokens refused on the REST path.
- DEC-003: the Worker source is embedded in `bin/share`; its sha256 prefix is the rev; no `wrangler.toml`.
- DEC-004: expiry is enforced per request by the Worker and cleaned up by any publisher's `ls` or `prune`; no Worker cron, because Access apps need a token the Worker must not hold.
- DEC-005: `teardown` on r2 is local by default; destroying the team's backend needs `--purge` and the admin token.
