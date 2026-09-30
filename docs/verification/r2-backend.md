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
