# Proof of done: CI shards for the bash suite

Lane: full. Notes: `docs/implementation-notes/ci-shards.md`. Files: `.github/workflows/ci.yml`, `tests/ci/`.

## What changed

- A pull request runs the suite as three Ubuntu shards (`chain`, `members-a`, `members-b`) from `tests/ci/shards.txt`, through `tests/ci/run-shard.sh`.
- A push to main runs the whole suite once on Ubuntu and once on macOS (`test-full`). On a pull request macOS runs a bash 3.2 parse check and the `members-b` shard (`test-macos`), not the whole suite.
- The lint job runs `tests/ci/shard-check.sh` (every section in exactly one shard) and `tests/ci/shard-check-test.sh` (its negative controls).
- `changes` gating and the 30 minute timeout are kept.

## Why three shards and not six

On the Mac mini the unfiltered suite took 1353 s over 82 sections. The sections of the `core`, `r2`, `groundwork` and `late` groups form one chain: `late` pulls the other three. Run with the `# pull` lines removed in a clone:

- `r2` alone aborted after 46 checks: `tests/share.sh: line 1965: QPATH: unbound variable` (QPATH is set at line 680, in core).
- `groundwork` alone stalled at 9 checks for 20 minutes (the `serve on a busy port` hang SG-13 named) and was killed.

So the chain is the floor of a PR run (about 63 percent of the suite). The standalone `members:` sections (about 450 s on the mini) split into two shards of about 215 to 235 s. Splitting the chain needs edits to `tests/share.sh`, outside this goal's files.

## Recorded run

Command: `bash tests/ci/shard-check-test.sh`
Exit: 0
Verdict: PASS
Output:
```
  ok    the committed shards cover every section once (exit 0)
        shard-check: 82 sections, 3 shards, each section in exactly one
  ok    a new section in no shard turns it red (exit 1)
        shard-check: no shard runs section: members: a section no shard names
  ok    a section in two shards turns it red (exit 1)
        shard-check: 2 shards run section: members: member rm and member purge (TASK-2d) (members-a members-b)
  ok    a shard that names no section turns it red (exit 1)
        shard-check: shard extra names no section
```

Command: `shellcheck tests/ci/*.sh`
Exit: 0
Verdict: PASS
Output: (none)

Command: `bash tests/share.sh` (unfiltered, on the Mac mini, before the change to CI files)
Exit: 0
Verdict: PASS
Output:
```
1826 checks, PASS
  total 1353s
```

Command: `bash tests/ci/run-shard.sh members-b`
Exit: 0
Verdict: PASS
Output:
```
147 checks, PASS (filtered by SHARE_TEST_ONLY: 9 sections ran, the rest skipped)
  total 210s
```

Command: `gh run view 43705138181` (PR run on the shard branch, every job green)
Exit: 0
Verdict: PASS
Output:
```
job                 result   wall
lint                success  0m50s
test (members-b)    success  2m49s
test (members-a)    success  4m00s
test-macos          success  5m08s   (bash 3.2 parse + members-b)
mac                 success  2m06s
test (chain)        success  12m19s
run total (first job start to last end): 12m29s
checks: members-a 136, members-b 147, chain 1560 (Ubuntu); test-macos members-b 147
```

Command: `bash tests/ci/run-shard.sh members-a`, `members-b`, `chain` on the Mac mini, then `SHARE_TEST_ONLY` on `^worker \(`, `^members: the invite seal`, and both
Exit: 0 for members-a and members-b; 1 for chain (one check, see below)
Verdict: PASS for the count; the chain run has one failure from other sessions' processes on the shared host
Output:
```
members-a   136 checks, PASS
members-b   147 checks, PASS
chain      1570 of 1571 checks pass; FAIL  no orphaned prune sleeps: expected '0', got '2'
always-run setup and tail checks (every shard runs them): 15 + 18 - 19 = 14
sum 136 + 147 + 1571 = 1854; minus 2 extra copies of the 14 = 1826 = the unfiltered run's "1826 checks, PASS"
```
The failing check counts `sleep 3600` processes whose parent is pid 1. `ps` showed two such sleeps started during the run by other sessions' suites on the same host (pids 25758 and 26385). The chain shard on CI, a clean host, is green with 1560 checks (the 11 fewer are Mac-only checks: the tty and `fr_FR` locale rows and the `r2 api-token` form).

## Result against the goal

- The PR wall time fell from the unsharded Ubuntu run (822 s of suite plus setup, measured in the goal) to 12m29s of run, set by `chain` at 12m19s. The target of 2 to 3 minutes is not met: `chain` is the `core`, `r2`, `groundwork` and `late` groups, which cannot run apart (see above). The members shards finish in 2m49s and 4m00s.
- A shorter wall needs `tests/share.sh` changes that make `r2`, `groundwork` and the heavy core sections independent of core's variables (`QPATH`, the suite's server). Heaviest chain sections on the mini: access 145 s, r2 compat 105 s, G2c 100 s, G2b 55 s, refresh racing rm 54 s.
- macOS: five shards would still exceed 4 minutes, so the whole suite runs on main only; a PR runs the parse check and `members-b` there.
- The main-push run (one full run per OS) is the first run of `test-full`; it is not part of this PR's proof.

## Negative control

The new section "members: a section no shard names" appended to a copy of `tests/members.sh` turns `shard-check.sh` red (exit 1, "no shard runs section"); the committed tree is green (exit 0). Both lines are in the first run above.

## Rollback

Revert the PR: the workflow returns to one `test` matrix of `bash tests/share.sh` on ubuntu and macOS. No deploy, Worker or persistent state is touched.
