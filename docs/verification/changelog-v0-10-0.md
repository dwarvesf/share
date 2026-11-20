# Verification -- changelog-v0-10-0

The v0.10.0 release commit: `bin/changelog --next v0.10.0` regenerated CHANGELOG.md, and `SHARE_VERSION` in `bin/handout` is 0.10.0. This is what `bin/release` writes; it lands by PR because `main` takes no direct push.

## Green run
```
Command: compare the newest CHANGELOG heading with bin/handout version (the suite's check OT-19)
Exit: 0
Output:
newest=0.10.0 version=0.10.0
MATCH
Verdict: PASS
```

## Negative control
```
Command: the same comparison with this CHANGELOG.md and the previous commit's bin/handout
Exit: 1
Output:
SHARE_VERSION=0.9.0 (newest heading 0.10.0): OT-19 fails on a version bump without the changelog, or the reverse
Verdict: PASS (the check tells the two apart)
```

## Not proven
- The tag, the GitHub release and the tap bumps: they follow this merge.

## The bump exposed a pinned version in a test
CI failed MB-07 on both OSes: `expected '1 cli_below_min 0 0', got '1 invite_unknown_or_used 0 0'`. Its mutation was `sed "s/^SHARE_VERSION=0.9.0 /..."`, a no-op once the version is 0.10.0. It now matches any version.
```
Command: SHARE_TEST_ONLY='^members: member machine \(R7\) and join$' bash tests/share.sh
Exit: 0
Output:
  ok    mm MB-07: a CLI below the marker's min_cli dies cli_below_min; nothing local is kept
62 checks, PASS (filtered by SHARE_TEST_ONLY: 1 sections ran, the rest skipped)
Verdict: PASS (the CI failure above is the negative control)
```
