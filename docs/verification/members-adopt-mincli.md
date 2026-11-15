# Proof of done: member adopt, min_cli enforcement, live member shares (SPEC-009)

Branch: feat/members-adopt-mincli
Spec: docs/specs/SPEC-009-multi-member.md, TASK-3e, TASK-3f, TASK-4a
Notes: docs/implementation-notes/multi-member.md, `## SG-14: adopt, WebSocket through a binding, min_cli`

Credentials came from 1Password into process environment variables and never reached argv, files or output. Hex runs of 32 or more are masked as first8…last8; account, token and subdomain values are not printed.

## Recorded run

```
Command: /bin/bash -n bin/share && shellcheck -S warning bin/share tests/members.sh tests/share.sh tests/ci/*.sh
Exit:    0
Verdict: PASS (bash 3.2 parses bin/share; shellcheck is clean)
```

```
Command: node tests/worker.mjs
Exit:    0
Excerpt: 303 ok, 0 FAIL; 17 `v5 LK-02` rows, `WORKER_SHA matches the emitted source`, the version-bump row
Verdict: PASS (Worker 6)
```

```
Command: SHARE_TEST_PORT_BASE=37500 SHARE_TEST_ONLY='adopt and min_cli|live port shares' /bin/bash tests/share.sh
Exit:    0
Excerpt: members: adopt and min_cli (TASK-3e, 4a): 21 ok; members: live port shares (TASK-3f): 8 ok; 0 FAIL
Verdict: PASS
```

```
Command: tests/share.sh with PATH=<bash 3.2 first>:/opt/homebrew/bin:/usr/bin:/bin:..., once unfiltered (1920 checks)
Exit:    1
Excerpt: 5 rows failed: SV-07, SV-08 (twice), DY-03 and MB-07 named values this change moved (live as a forged opt, Worker version 5, a join fixture that built its own min_cli); a sixth, "an existing 644 token file", and the Keychain row failed because my first PATH put /usr/bin ahead of /opt/homebrew/bin, so the suite's jq resolved to /usr/bin/jq and its no-security PATH kept the real `security`. All other rows passed.
Verdict: FAIL (fixed in the rows' tests, not in bin/share; the PATH was the run's own)
```

```
Command: tests/share.sh with PATH=<bash 3.2 first>:/opt/homebrew/bin:/usr/bin:/bin:..., SHARE_TEST_ONLY='members: phase 0|members: member machine \(R7\)|access: a login gate'
Exit:    0
Excerpt: the rows above pass; "no real Keychain share item changed during the run" passes; MB-07 passes
Verdict: PASS
```

```
Command: SHARE_TEST_ONLY='^members: phase 0' (the chain shard: core, r2, groundwork, late) after the row fixes
Exit:    0
Excerpt: 1582 ok, 0 FAIL; no stray suite process, no orphaned prune sleep, no real Keychain share item changed
Verdict: PASS (the first unfiltered run covered every other section: members-a and members-b sections all ok)
```

## Negative controls (red, then green)

| Row | Red run (the defence removed) | Green run |
|---|---|---|
| `mm NC TASK-4a` | `sed` drops the `r2_min_guard` call; the same forged `min_cli 99.0.0` lets `add --cloud` PUT `m/f40003` | with the guard, `OC-04` refuses it `cli_below_min` and no PUT or DELETE reaches the bucket |
| `mm NC LK-02` | a copy of the CLI with the live upgrade branch off (a v5 Worker); the same `--ws` request does not answer 101 | the Worker answers 101 and a masked frame echoes back through a real Caddy |
| Worker rows `v5 LK-02` | a 101 with no `X-Share-Served`, a pointer without `live`, a comma list of types: each answers 503 or octet-stream with the sandbox | the marked 101 on a `live` pointer is a fresh `101` with only the subprotocol |
| adopt refusals | another user's token, an unknown id, an account-wide token, another bucket, Zone Edit, an admin-class bucket group, an empty resource, a token another member holds: each `adopt_token_scope`, no record, no write | the own bucket-scoped token adopts |

## TASK-3f live record (Console Labs, share-e2e-ws-<8hex> names)

R2 is off on Console Labs (SG-01), so this is the bucket-free probe: a throwaway tunnel, a VPC Service to a local echo server (HTTP, a chunked `/stream`, a WebSocket echo), and a Worker with one `vpc_service` binding. The base admin token lacks the Connectivity scope, so the script minted a two-hour admin token through the minter and deleted it at the end. Four runs, each cleaned up by name; each printed `leftovers by name share-e2e-ws-<8hex>: workers=0 services=0 tunnels=0`.

```
Command: bash ws-probe.sh   (creds by op read into the process environment; node ws-probe.mjs)
Exit:    0 (four runs)
Excerpt: tunnel connected: true
         GET /x through the binding: HTTP 200
         stream verdict: 4 reads, first-to-last 2.7 to 3.0 s -> STREAMED
         WebSocket /ws  (the incoming request passed on): error: it never opened
         WebSocket /ws2 (a rebuilt Request, handshake headers only): open, echoed "echo:hello-ws"
         WebSocket /ws3 (the share Worker's shape: allowlist, redirect manual, 10 s signal): open, echoed
         WebSocket /ws4 (a fresh 101 built from the machine's socket, X-Share-Served required): open, echoed, subprotocol "p1" negotiated
         cleanup: worker=200 vpc service=200 tunnel=200 minted admin token=200
Verdict: PASS: a Worker VPC binding carries a WebSocket upgrade and a streamed body
```

UAT: the probe ran on Console Labs from the Mac Mini and passed; the pass branch of TASK-3f was taken. Not run live: the share Worker itself on a real tenant with a bucket (R2 is off on Console Labs). The member row end to end (CLI, Caddy, pointer, Worker 6, a browser) is covered by the dry fixtures and the `--ws` harness against a real Caddy; the live tenant acceptance is TASK-4e.

## Rollback

- Worker 6: it differs from 5 only for a v:3 pointer with `live`, so leaving a tenant on 6 after reverting the CLI is safe. Lowering it needs no members: `setup --force` under members is refused (DY-03), so `share member rm` each member first, then `share setup <host> --r2 --bucket <bucket> --force`.
- Live member rows: `share rm <id>` on the member machine deletes the pointer and the handle.
- adopt: `share member rm <name>` revokes the renamed token and marks the record removed; the token's old name was `share publisher ...` (the renamed token keeps its policies and expiry, so a `PUT /user/tokens/<id>` with the old name undoes the rename).
- `min_cli`: `share setup <host> --r2 --bucket <bucket> --members --yes` resets a marker above this share to this share's version. Reverting the CLI commit removes the guard; a marker already written keeps its value.

## Not attempted

- A live acceptance run of adopt against a real R5 publisher token on a tenant with R2 (Console Labs has none): the dry account's token store stands in, with the same policy shapes the API returns.
- POST and other methods through a live member row: Worker row 15 allows GET, HEAD and the upgrade only (notes P60).
- The docs outside this sub-goal's Touches (README, how-it-works, setup, SYSTEM-DESIGN, CONTEXT): listed in the notes for SG-11 and SG-17.
