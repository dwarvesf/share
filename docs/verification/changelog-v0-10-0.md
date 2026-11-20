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
