# Proof of done: CI skips the suite a change cannot affect

Date: 2026-11-15
Branch: chore/ci-skip-unaffected
Change: `.github/workflows/ci.yml` (a `changes` job gates `test` and `mac`, job timeouts, PR-only cancel)

Every check ran on the Mac Mini in the branch worktree. `.github/scripts/ci-changes-test.sh` extracts the `changes` step from the workflow and runs it against fake diffs, with `git` stubbed to print the file list.

## Recorded run

```
Command: actionlint .github/workflows/ci.yml
Exit:    0
Verdict: PASS
```

```
Command: bash .github/scripts/ci-changes-test.sh .github/workflows/ci.yml
Exit:    0
Output:
ok    [mac/Sources/ShareBar/App.swift docs/verification/share-bar/x.md] -> bash=false mac=true
ok    [mac/Tests/A.swift docs/implementation-notes/share-bar.md] -> bash=false mac=true
ok    [bin/share tests/members.sh] -> bash=true mac=false
ok    [mac/Sources/ShareBarCore/CLI.swift] -> bash=true mac=true
ok    [mac/a.swift bin/share] -> bash=true mac=true
ok    [.github/workflows/ci.yml] -> bash=true mac=true
ok    [docs/how-it-works.md] -> bash=true mac=false
ok    [docs/verification/members-core.md] -> bash=true mac=false
ok    [git diff fails] -> run all
ok    [empty diff] -> run all
Verdict: PASS
```

## Negative control

The broken variant drops the clause that keeps `mac/Sources/ShareBarCore/CLI.swift` on the bash suite (`tests/share.sh` reads that file):

```
Command: bash .github/scripts/ci-changes-test.sh <ci.yml without the CLI.swift clause>
Output:  FAIL  [mac/Sources/ShareBarCore/CLI.swift] want 'bash=true mac=true ' got 'bash=false mac=true '
Verdict: RED as expected; the real workflow is green (run above)
```

## Not covered here

- The live job graph (skipped jobs on a mac-only PR) shows on the first such PR after merge. This PR edits `.github/`, so it runs everything.
- The 30 min test timeout and the PR-only cancel are plain config; actionlint checks their syntax only.
