# Proof of done: r2 backend, batch 1

Date: 2026-09-30
Branch: docs/r2-backend-spec
Spec: docs/specs/SPEC-007-r2-backend.md

## Green run

```
Command: SHARE_TEST_PORT_BASE=38787 bash tests/share.sh
Exit:    0
Checks:  545 ok, 0 FAIL (PASS), at aff423d (backend load, sentinel, setup refusals)
Tail:    === process leaks ===
           ok    serve.pid removed
         PASS
Verdict: PASS
```

`shellcheck bin/share tests/share.sh` and `/bin/bash -n` on both are clean on the same tree.

```
Command: node tests/worker.mjs
Exit:    0
Checks:  68 ok, 0 FAIL (PASS): Worker sha and version self-checks, node --check,
         serving shapes (index, README fallback, 308s, HEAD, Range), path and
         record and Host refusals, hit points, and the gated-record JWT matrix
         (valid, array aud, no header, unknown key, wrong aud or iss, expired,
         alg none or HS256, malformed, TEAM empty, certs down, bad record aud)
Verdict: PASS
```

The `=== r2 backend: dry seam and r2_call ===` section drives the directory
bucket: PUT/GET/HEAD/DELETE with md5 etags, `If-None-Match` and `If-Match` 412s,
an `a b%q?.txt` key round trip, url-encoded LIST XML, the PUT/DELETE `lost`
knobs (commit vs no commit, both answering 000), `SHARE_R2_DRY_LIST=500`, the
PAUSE interleaving knob, the refusal of `SHARE_R2_DRY` with the tunnel on, and
`r2-call` refusing a non-r2 profile. The `=== live transport ===` section runs
`r2_call` through a `curl` shim on PATH: two 429s retried to a 200 (three calls,
Retry-After read from the `-D` header file), a persistent 500 giving up after
three, the `endpoint/bucket/urlenc(key)` URL, `--aws-sigv4 aws:amz:auto:s3`, the
credential config reaching curl as `/dev/fd/N`, and a sentinel token absent from
argv, stdout, stderr, and every file under the test HOME.

The new `=== r2 backend ===` sections cover row 2 (every setup argument refusal:
missing and bad `--bucket`, `--quick`, `--no-service`, `--login`, `--tunnel-name`,
a bogus `--backend`, `--bucket` without `--backend r2`, setup over a tunnel config,
and start, stop, serve, service install, teardown, live add, `--host` add, tunnel
and quick setup on an r2 profile), row 22 (`origin/main`'s share dies on the
`port=r2` sentinel at load for add, gated add, ls, and setup, with nothing written
under the profile root), and row 1 (a compat driver runs quick setup, add file,
add folder, add live, a refused `--host` add, ls, state, and service install under
one private HOME for `origin/main` and this branch, then diffs every artifact
byte for byte).

## Negative controls

```
Command: sed the backend= load line to backend="", then
         SHARE_TUNNEL=0 bash bin/share --profile r2x start   (r2 profile config)
Exit:    1 with "port 'r2' is not a number"
Verdict: RED. Without the backend load the r2 refusal never runs; the config's
         own port sentinel is the only thing that stops the verb. Restored, the
         same call answers "an r2 profile has no local server" (green above).
```

Row 22 is itself a shipped negative control: `origin/main` cannot read
`backend=r2` and every verb dies on the sentinel before it can write a pub/ tree
or an Access app against an r2 profile.

## Batch 2: snapshot, ids, r2-own, admin setup (dry)

```
Command: SHARE_TEST_PORT_BASE=38787 bash tests/share.sh
Exit:    0
Checks:  782 ok, 0 FAIL (PASS), at a720574
Verdict: PASS
```

```
Command: node tests/worker.mjs
Exit:    0
Checks:  65 ok, 0 FAIL (PASS)
Verdict: PASS
```

`shellcheck bin/share tests/share.sh` and `/bin/bash -n bin/share` are clean on the same tree.

`=== r2 backend: snapshot, rows, rand_id ===` covers rows 25e and 27: forged records (id differs from key, control byte, bad prefix, `v:2`, not JSON, `expires` 1e300, a `prefix=` inside opts) never reach `rows()`; `$index` names the snapshot file; `ls` prints the row with `by=`; `rand_id` skips an id with a record and an id with leftover `o/<id>.` objects; a LIST 500 makes `ls`, `rand_id`, and `add` exit 1 with no object write. `=== r2-own ===` covers replace, drop, and a prefix naming another id.

`=== r2 backend: admin setup ===` covers rows 3, 4, and 20 on the dry account: the no-token block; the admin log order from the settings read through `HEALTHZ`; config keys and no tunnel keys or service file; bindings (HOST, VERSION, SHA, TEAM, dataset, SALT with no stored value); the workers.dev read-back; a rerun with no script, domain, bucket, or marker write; a changed deployed SHA redeployed once; a failed organizations read keeping TEAM; TEAM drift redeployed; a newer deployed version refused, then downgraded with `--force`; eight refusals (foreign objects, foreign marker, r2.dev on, bucket custom domain, DNS record, another Worker's domain with `--force`, foreign script bindings, a 500 on the domains read) each with no write logged, the bucket unchanged, and no config; the subdomain read-back dying before the domain PUT; a healthz timeout writing no config.

No call reached the real Cloudflare account in this batch.

## Batch 3: join mode (dry)

```
Command: SHARE_TEST_PORT_BASE=38787 bash tests/share.sh
Exit:    0
Checks:  800 ok, 0 FAIL (PASS)
Verdict: PASS
```

`node tests/worker.mjs` exits 0 on the same tree. `=== r2 backend: join as publisher ===` covers row 23: a second HOME joins with the script and bucket reads answering 403; it prints `joining as publisher` and the public-route skip, reads the marker, makes no DNS, domain, or Access read, logs no write, leaves the bucket unchanged, writes the config, and prints the version-mismatch line. A missing marker, a missing bucket, and a Worker that never answers each exit 1 with no config.

## Rollback

Code: revert the batch commits on `docs/r2-backend-spec`; no tunnel profile reads any r2 key (row 1 stays green).

Live state: [UNAVAILABLE: this batch created nothing on Cloudflare; every setup run hit the dry seam]. Once an admin runs setup live, `share --profile <p> teardown --yes --purge` (TASK-13) removes the marker, custom domain, Worker, and empty bucket; until TASK-13 lands, the by-name cleanup is the one in `tests/e2e-r2.sh`'s EXIT trap (TASK-14).

## Batch 4: the live leg, docs, and the negative controls

### Live e2e (tests/e2e-r2.sh)

```
Command: SHARE_BIN=<worktree>/bin/share SHARE_E2E_R2_HOST=share-e2e-<6 hex>.d.foundation SHARE_E2E_R2_BUCKET=share-e2e-<6 hex>
         SHARE_E2E_ACCESS_RULE=group:dwarves-ops CLOUDFLARE_API_TOKEN=<admin> SHARE_E2E_R2_TOKEN_ADMIN=<token minter> tests/e2e-r2.sh
Tree:    30eb3bc (bin/share is unchanged since; later commits touch tests/worker.mjs and docs only)
Exit:    0
Checks:  84/84 passed (L1 to L11, the before checks, and the cleanup asserted through the API)
Log:     docs/verification/r2-e2e-2026-10-01.txt
Verdict: PASS
```

Runs 1 to 5 (`r2-e2e-2026-09-30-run1.txt`, `r2-e2e-2026-10-01-run2.txt` to `-run5.txt`) each stopped on one defect: the deploy's module filename (400), the healthz probe's negative-cached DNS, 206 on every plain GET, one edge 500 right after setup (the check now polls), and `Content-Range: bytes NaN-NaN`. Each fix is its own commit with a regression check that is red against the code before it (below). Every run was bracketed by outside checks through the admin and token-admin credentials: before and after, 0 buckets named `share-e2e*`, 0 Workers named `share-share-e2e*`, 0 custom domains and 0 DNS records for the run's hostname, 0 Access apps named for it, 0 user tokens named `share-e2e*`, and the same 15 other buckets (sha of their names `79a3fcf51452` every time). Run 1's trap could not empty a bucket without the profile config, so bucket `share-e2e-d31313` (holding only `share.json`) was deleted by hand through S3 and the API, verified 404; the trap now does it.

Created and deleted per passing run: bucket `share-e2e-<hex>`, Worker `share-share-e2e-<hex>-d-foundation`, its custom domain and DNS record `share-e2e-<hex>.d.foundation`, one Access app for the gated share, two user API tokens `share-e2e-<hex>-a` and `-b` (bucket-scoped, 2 h expiry, revoked at the end). The Analytics Engine datasets `share_share_e2e_<hex>_d_foundation` cannot be deleted by API and age out. `f.d.foundation` was not created.

What the live run shows beyond the dry rows: a bucket-scoped token lists and writes its bucket through S3 and gets 403 on the Worker settings, a script PUT, and `GET r2/buckets`; `GET workers/scripts` with it answers 200 with 0 scripts. The Access edge caught `/<ID>/`, `/%<hex><rest>/`, `/x/..\<id>/`, `/x/%2e%2e/<id>/`, and `//<id>/` on the gated share (302 with `kid == aud`, never 200); the gated add took about 40 s with no 200 during the wait. On the ungated share `/x/..\<id>/doc/` answers 200 (the edge resolves it to the canonical path) and `/x/%2e%2e/<id>/doc/` 400. `hits` counted 3 hits, 1 visitor.

### Suites on the final tree

```
Command: SHARE_TEST_PORT_BASE=<base> bash tests/share.sh ; node tests/worker.mjs ; swift test --package-path mac
Tree:    70831fd (exported with git archive, run alone)
Checks:  share.sh 1039 ok, 0 FAIL; worker.mjs 71 ok, 0 FAIL; swift 153 tests, 0 failures
Lint:    shellcheck bin/share install.sh tests/share.sh tests/e2e.sh tests/e2e-r2.sh demo/render.sh mac/*.sh: clean; /bin/bash -n bin/share: clean
Verdict: PASS
```

### Negative controls (same tree, 70831fd)

Each control is a patch applied to an exported copy of 70831fd (`git archive`), then the full `tests/share.sh` (which runs `worker.mjs` once more) and `node tests/worker.mjs`. A Worker patch also rewrites `WORKER_SHA`, so the sha self-check stays green and only the named row turns red. The GREEN run is the unpatched copy of the same tree. Controls 1 to 11 ran four at a time; row 1's compat driver starts `origin/main`'s quick server on its default port in every copy, so row 1 also went red in controls 1, 2, 3, and 7 from the parallel runs alone (not counted below). GREEN and control 12 ran alone.

| # | Patch | Expected red | Red checks on the named row (FAIL total) | GREEN |
|---|---|---|---|---|
| 1 | publish `m/<id>` before the gate | row 11 | 6 row 11 checks, among them the order `object PUTs < POST app < every PROBE < PUT m/<id>` (28; gated adds in rows 9, 12, 15, 25d fail too) | 0 FAIL |
| 2 | drop the encoded-separator check from the Worker | row 18 `%2F` `%5C` `%2E` | 4 r18 cases, 400 became 404 (9) | 0 FAIL |
| 3 | skip the JWT check for gated records | row 28 | 13 r28 cases answer 200, and row 11's integration Worker serves without a JWT (28) | 0 FAIL |
| 4 | gated `rm` without the Apps Edit probe | row 29 | 2 row 29 checks: rm exits 0, DELETEs logged (2) | 0 FAIL |
| 5 | run the orphan sweep from the filtered snapshot | row 24 | 3 row 24 checks: the `v:2` prefix is deleted, no warning (3) | 0 FAIL |
| 6 | decode the id segment | row 18 `/%61...` | 1 r18 case answers 200 (3: the case in both worker.mjs runs, and `worker.mjs exits 0`) | 0 FAIL |
| 7 | drop the `expires` check from the Worker | row 10 | 1 row 10 check: an expired record answers 200 (1) | 0 FAIL |
| 8 | skip the subdomain POST | row 3 | 9 row 3 checks: setup dies on the read-back, no config (20; every later setup-based check) | 0 FAIL |
| 9 | drop `If-Match` from the refresh PUT | row 25a | 6 row 25a checks: no 412, a record resurrected (6) | 0 FAIL |
| 10 | delete the app without the `GET m/<id>` 404 check | rows 9 and 25d | 5 row 9 and 1 row 25d checks, plus row 12/23c (7) | 0 FAIL |
| 11 | skip the purge binding check | row 15 | 14 row 15 checks: the foreign-Worker purge exits 0 and deletes (14) | 0 FAIL |
| 12 | write a `backend=` line into every tunnel config | row 1 | 1: row 1's byte-identity diff (1) | 0 FAIL |

Control 12 first patched only the named-tunnel writer (`write_config`) and stayed green (1039 ok): row 1's compat driver runs quick setup, which writes through `write_config_quick`, and a named setup needs a live account. With both writers patched, row 1 turns red. The named writer's byte identity rests on its unchanged code and the `backend` read being guarded by `== r2`.

Regression checks added with the live fixes, each red against the code before its fix: `r17 a folder name with a space serves its index` and the non-ASCII README case (404 before), `r17 a plain GET is 200, not 206` plus nine other 200 checks (206 before), `r17 Range Content-Range` (`NaN-NaN` before), and the shim check that `/healthz` resolves over DoH first. The row 18 `%61` case used an id with no record, so a decoding Worker still answered 404 and control 6 stayed green; it now spells the test share's id and turns red.

### Rollback

Code: revert the branch commits; a tunnel profile reads no r2 key (row 1 green). Live state: [UNAVAILABLE: nothing persists; every e2e object was deleted and verified gone through the API]. A future live r2 profile is removed with `share --profile <p> teardown --yes --purge` and the admin token.
