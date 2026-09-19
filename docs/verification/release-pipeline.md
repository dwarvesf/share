# Proof of done: release-pipeline

Date: 2026-09-19
Branch: feat/release-pipeline

## Green run

```
Command: shellcheck bin/release bin/share install.sh tests/share.sh tests/e2e.sh
Exit:    0
Verdict: PASS
```

```
Command: PATH=/usr/bin:/bin /bin/bash -n bin/release   # macOS bash 3.2 parse
Exit:    0
Verdict: PASS
```

```
Command: bash bin/release   (on feat/release-pipeline)
Result:  "release: run on main", exit 1
Command: bash bin/release   (scratch clone, bin/release untracked)
Result:  "release: main is dirty", exit 1
Command: bash bin/release   (scratch, local main ahead of remote)
Result:  "release: main is not in sync with origin", exit 1
Verdict: PASS (all three refusal paths fire)
```

```
Command: scratch repo synced to a local bare remote, tag v9.9.9 at real main,
         commits since: chore x2, fix, feat   |  echo N | bash bin/release
Result:  "v9.9.9 -> v9.10.0", commit list printed, "release: aborted" on N, exit 1
Command: + "feat!: drop the old config shape" commit | echo N | bash bin/release
Result:  "v9.9.9 -> v10.0.0"
Verdict: PASS (patch path shown by the negative control below, minor and major green)
```

## Negative control

The first scratch run of the ORIGINAL classifier is the revert:

```
Command: original case patterns `feat*:|feat*\(` | feat+fix history | bin/release
Result:  RED — "v9.9.9 -> v9.9.10" (patch): `feat*:` is a whole-string glob and
         only matches subjects ENDING in ':', so "feat: a new thing" never set
         minor. The classifier is load-bearing, not decorative.
Command: fixed patterns `feat:*|feat\(*\):*` and `*!:*` | same history
Result:  GREEN — "v9.9.9 -> v9.10.0"; "feat!:" history -> "v10.0.0"
Verdict: PASS (broken -> RED -> fixed -> GREEN, found by the green run itself)
```

## Not exercised

Tag creation, tag push, `release.yml`, and the tap-formula bump cannot run
without a real remote and a real release. First live run happens on the next
feature merge (expected: v0.3.0). The refusal and computation paths above are
the parts with logic worth proving.
