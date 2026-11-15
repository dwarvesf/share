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

## Negative control

The new section "members: a section no shard names" appended to a copy of `tests/members.sh` turns `shard-check.sh` red (exit 1, "no shard runs section"); the committed tree is green (exit 0). Both lines are in the first run above.

## Rollback

Revert the PR: the workflow returns to one `test` matrix of `bash tests/share.sh` on ubuntu and macOS. No deploy, Worker or persistent state is touched.
