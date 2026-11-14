# Proof of done: state groundwork, Phase 1 (SPEC-010)

Date: 2026-11-15
Branch: feat/state-groundwork-must
Spec: docs/specs/SPEC-010-state-groundwork.md, tasks G1, G1b, G2a, G2b, G2c, G3, G4, G5, G13
Notes: docs/implementation-notes/state-groundwork.md (build delta B1 to B18, the AC to test map, the advisor folds)

Every check below ran on the Mac Mini in the branch worktree. The suite's new sections are `=== state groundwork: <task> ===` in `tests/share.sh`. No Cloudflare account was touched: tunnel and DNS calls go to a stateful fake API, R2 and Access calls to the existing dry seams.

## Recorded run

```
Command: /bin/bash -n bin/share && shellcheck bin/share tests/share.sh
Exit:    0
Verdict: PASS (bash 3.2 parse, no shellcheck finding)
```

```
Command: SHARE_TEST_PORT_BASE=21000 bash tests/share.sh          (full suite, brew bash 5 on PATH)
Exit:    1 (1/1401 FAILED: "no suite serve still running: got 2")
Excerpt: the two serves were leftovers of an earlier hand debug run (started 00:20 and 00:27, before this run began at 00:45); stopped by pid, then the next runs below
Verdict: PASS for every groundwork check; the one failure is outside the run
```

```
Command: env PATH=/bin:/usr/bin:/usr/sbin:/sbin:/opt/homebrew/bin SHARE_TEST_PORT_BASE=21000 /bin/bash tests/share.sh
Exit:    1 (3/1402 FAILED)
Excerpt: FAIL an existing 644 token file is 600 after a store; FAIL no real Keychain share item changed during the run
         cause: macOS ships /usr/bin/jq, so the test's "no security binary" PATH (built from jq's directory) put /usr/bin back, and /usr/bin/security wrote the stale fixture item share-api:s.example.test; a PATH artifact of /usr/bin ahead of brew, not of this change
         FAIL row 6: pub/<id> absent while a PROBE fail was logged (passed in the other two runs)
Verdict: SUPERSEDED by the shim run below; every groundwork check passed here
```

```
Command: env PATH="<scratch>/bash32:$PATH" SHARE_TEST_PORT_BASE=21000 /bin/bash tests/share.sh   (bash32/bash -> /bin/bash, so every `bash` is 3.2; tools keep their normal order)
Exit:    0
Excerpt: 1402 checks, PASS; 732 s; every `=== state groundwork: ... ===` section green, JN-12 ran both the locale (fr_FR.UTF-8) and the zone halves
Verdict: PASS (the full suite and the bash 3.2 run, at commit 1f02a6b plus docs)
```

```
Command: swift test --package-path mac
Exit:    0
Excerpt: Executed 179 tests, with 0 failures (GroundworkCompatTests: 3 cases, CP-01)
Verdict: PASS
```

```
Command: bash mac/build.sh 0.0.0
Exit:    0
Excerpt: mac/build/Share-Bar-0.0.0.zip
Verdict: PASS
```

## Negative controls (red, then green)

Each control runs inside the suite against a mutated copy of `bin/share`; the control's check asserts the red outcome, and the matching real check asserts green on `bin/share`.

| Control | Mutation | Red (mutated copy) | Green (bin/share) |
|---|---|---|---|
| NC-G1 | `die_code` prints the JSON line without `SHARE_ERROR_JSON` | `negative control NC-G1 ...`: stderr differs from HEAD's (2 lines) | `CD-01 start outside hosts=: stderr and exit byte-identical to HEAD's` |
| NC-G2 | `owner_live` by pid alone | `negative control NC-G2 ...`: refused `op_running` | `JN-05 a journal whose pid the OS reused reads dead ...` |
| NC-G3 | `profile_role` puts `origin` before `migrated` | `negative control NC-G3 ...`: `origin stopped t0` | `RL-02 migrated before G3 ...`: `migrated not_setup` |
| NC-G4 | `config_put` drops unowned keys | `negative control NC-G4 ...`: `x_future=1` lost | `CF-01 setup <host> rerun keeps ...` |
| NC-G5 | a code in `code_table` with no skill line | `negative control NC-G5 ...`: the check fails | `every code in share state-fn codes appears in the skill` |
| NC-G6 | `op_done` not called on a clean `setup --r2` | `negative control NC-G6 ...`: the journal stays | `JN-01 on the wired verb: a clean setup --r2 leaves ops/ empty` |
| CD-05 control | the prune loop without `unset SHARE_EXIT_FILE` | `negative control: without the loop's unset ...`: `cloudflared_died` lands | `CD-05 the hourly prune dies while serve runs ...`: no record |
| code list control | a `die_code` naming an unlisted code | `negative control: a die_code with an unlisted code fails that check` | `every die_code in bin/share names a code that state-fn codes lists` |

## Die-point loops (Q-REL-5)

| Verb | Steps killed (kill -9 at each, through SHARE_OP_PAUSE) | Check |
|---|---|---|
| setup-r2 | 16 | `G2b die-point loop: setup-r2 ...` |
| no-r2 | 2 | `G2b die-point loop: --no-r2 ...` |
| setup-tunnel | 8 | `G2c die-point loop: setup <host> ...` |
| teardown | 7 | `G2c die-point loop: teardown ...` |
| teardown-purge | 7 | `G2c die-point loop: teardown --purge ...` (one cloud link, see the finding below) |
| migrate | 7 | `G2c die-point loop: migrate ... under /bin/bash 3.2` |

Every rerun printed `previous <verb> died at step <n> (<name>); continuing`, exited 0, reached the happy end state, and left `ops/` empty.

## Compatibility

- CP-01: `GroundworkCompatTests` decodes `Fixtures/state.json` plus `codes_v`, `cloud_error_code`, `role`, `tier`, `ops` with today's `Snapshot`, equal to the plain decode; a migrated state is `.notSetUp` and neutral; a listing carrying the keys has no error. Bash half: `CP-01 state_schema_ok passes on a migrated HOME with state not_setup`.
- With `SHARE_ERROR_JSON` unset, every migrated guard's stderr and exit equal the base commit's own `bin/share` (84ebd9a), run beside the new one in the suite (`CD-01 ...`, ten guards).
- `r2 backend: byte identity of existing installs`: every config, Caddyfile, index and plist artifact byte-identical; the `state` normalization also drops the new additive keys.

## Findings outside this change

- A `teardown --purge` of an r2 profile with two cloud links dies at the second `rm`; reproduced on 84ebd9a. Recorded in the notes; not attempted here.
- The restricted-PATH run above changed the stale test item `share-api:s.example.test` in the login Keychain (a leftover fixture from an earlier run, never a real credential).

## Rollback

The change is local to the CLI: new files are `$root/ops/`, `$root/.serve-exit`, and the config keys `migrated=`, `admin_token_cmd=`, `minter_token_cmd=`. Rollback is a revert of the merge commit; a v0.9 CLI ignores all three files and keys (`state` stays schema 1). Nothing deploys: no Worker, bucket, DNS or tunnel change.
