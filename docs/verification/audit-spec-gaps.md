# Audit spec gaps: proof of done

Closes the open gaps of `docs/research/2026-11-14-audit-to-spec-trace.md`: a cloud add over a dead `setup-r2` (gap 2), a 401 on an add (gap 6), join step 2 split into one step per write (gap 7), and the prune leg of gap 3. Decisions: SPEC-010 DEC-37 to DEC-39, SPEC-009 DEC-82. Notes: `docs/implementation-notes/state-groundwork.md` and `multi-member.md`.

## Recorded run

All runs used a copy of the worktree made with `git clone --shared` plus an rsync of the working tree, port bases 38500 and 38700. "Old" is `bin/share` at the branch base (origin/main 5c827f0). The suite files are the new ones in every run.

### Red on the old code

Command: `SHARE_TEST_ONLY='^state groundwork: G2b$|^state groundwork: G10$' SHARE_TEST_PORT_BASE=38500 bash tests/share.sh` (base `bin/share` plus only the `SHARE_R2_DRY_FAIL` seam, the first draft of the tests)
Exit: 1
Verdict: red as expected. JN-16 at step 11 failed (the add died `R2 is off`, no `op_interrupted`) and at step 12 (the add published, exit 0). The four TK-07 rows failed too, one of them (the 500 row) for a helper defect that I fixed before the green runs.
Output: `6/853 FAILED`

Command: `SHARE_TEST_ONLY='^state groundwork: G7$' SHARE_TEST_PORT_BASE=38700 bash tests/share.sh` with the base `bin/share` and the final tests
Exit: 1
Verdict: red as expected. Every new row that asserts the change failed on the old code: JN-16 (steps 11 and 12), LS-06 (the stored gates row), TK-07 (upload 401, upload 403, record PUT 401, record PUT 500 exit code, pointer PUT 401). Two rows pass on the old code by design: JN-16 past step 12 and after the rerun, LS-06 with only an `api_token_cmd`, and TK-07 "keeps the expires_on" (they guard what must not change).
Output: `9/857 FAILED`; the ninth failure, `no orphaned prune sleeps`, came from sleeps of a killed run of mine (below)

Command: `SHARE_TEST_ONLY='^members: member machine \(R7\) and join$' SHARE_TEST_PORT_BASE=38700 bash tests/share.sh` with the base `bin/share`
Exit: 1
Verdict: red as expected: DP-join-1a to 1d, DP-join-2, 3b, 4, 6 and DP-join-1d (re-join) failed on the six-step journal.
Output: `9/63 FAILED`

### Green on the new code

Command: `SHARE_TEST_ONLY='^members: member machine \(R7\) and join$' SHARE_TEST_PORT_BASE=38700 bash tests/share.sh`
Exit: 0
Verdict: green (the join rows, MB-26, MB-27, MB-32, the re-join and NC-11 included)
Output: `63 checks, PASS (filtered by SHARE_TEST_ONLY: 1 sections ran, the rest skipped)`

Command: `PATH=/bin:$PATH SHARE_TEST_PORT_BASE=38500 bash tests/share.sh` (the full suite, once, with `/bin/bash` 3.2 first on `PATH` so it runs `tests/share.sh` and `bin/share`)
Exit: 1
Verdict: green except one environment check. Every new row passed: JN-16 (4), LS-06 (2), TK-07 (6), DP-join (13 rows, 9 of them new). The failing check, `no orphaned prune sleeps` (expected 0, got 2), counts `sleep 3600` idlers machine-wide; the two were left by a suite run of mine that I killed (started 18:04:07). I killed them by pid and reran the tail checks.
Output: `1/1842 FAILED` (the unchanged suite was 1826 checks; the count only grew, by 16)

Command: `SHARE_TEST_ONLY='^members: member add$' SHARE_TEST_PORT_BASE=38700 bash tests/share.sh` (the always-run tail checks after the two idlers were killed)
Exit: 0
Verdict: green, `no orphaned prune sleeps` ok
Output: `34 checks, PASS (filtered by SHARE_TEST_ONLY: 1 sections ran, the rest skipped)`

### Static checks

Command: `/bin/bash -n bin/share`
Exit: 0
Verdict: parses under macOS bash 3.2
Output: (none)

Command: `shellcheck -S warning bin/share`
Exit: 0
Verdict: clean
Output: (none)

### Review

Command: kit:advisor (critique) and kit:code-reviewer on the frozen diff, then kit:doc-verifier on the docs
Exit: 0
Verdict: no critical finding. Folded: the LS-06 test needed `SHARE_ACCESS_DRY=1`; the 401 verdict keeps the stored `expires_on`; the pointer-PUT 401 row and the keeps-expiry row were added; TASK-4b18 and the step 0 row of the join table were updated; stale step numbers in the notes were fixed; the DP-join labels now match the spec rows. Accepted and written down: the guard also blocks a killed rerun of `setup --r2` on a working tenant (DEC-37), and a join journal an older CLI left reads by the new numbering (DEC-82).
Output: (reports in the PR body)

### UAT

No live Cloudflare work. Every check runs in the dry seam (`SHARE_R2_DRY=1`) and the fake Cloudflare; no tenant of the owner was touched.

## Rollback

Revert the squash commit. Journals under `$root/ops/` are transient: a `join` journal written by this version has nine steps and reads wrongly under the old six-step table, so a member with a dead join runs the bare `share join` on the version that wrote it, or asks the admin for a new invite. `.health` gains a `token.verify` value of `invalid` only through a failed add, and the next `share api-token` or `share status` verify replaces it. No config key, bucket object or Worker changes.
