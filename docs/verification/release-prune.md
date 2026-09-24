# Proof of done: release-prune

Date: 2026-09-24
Branch: fix/release-prune

## Bug

`bin/release` fetches `main:refs/remotes/origin/main` then rev-parses
`origin/main`. When the user's global git config has `fetch.prune=true` and
`refs/remotes/origin/main` already exists locally, that fetch's own implicit
prune deletes the ref (it isn't in the fetch's refspec set), so the following
rev-parse fails and the script dies `main is not in sync with origin` even
though main IS in sync. Observed live: `bash -x` trace showed the fetch run,
then `git rev-parse origin/main` fail immediately after.

## Fixture

A throwaway bare repo + clone under `mktemp -d`, standing in for the real
`dwarvesf/share` remote, so the repro touches no real refs:

```
git init --bare "$FIX/remote.git"
git init "$FIX/clone"; commit; push a "main" branch to $FIX/remote.git
cd "$FIX/clone"
git fetch -q "$FIX/remote.git" main:refs/remotes/origin/main
git rev-parse origin/main   # de7f197996d0867621e93312391f55251c98cb3b
```

## Negative control (old fetch form, RED)

```
Command: git -c fetch.prune=true fetch --quiet "$FIX/remote.git" main:refs/remotes/origin/main
Result:  git rev-parse origin/main  -> fails, ref not found
Verdict: RED — reproduces the bug under a global fetch.prune=true
```

## Green run (fixed form)

```
Command: git fetch -q "$FIX/remote.git" main:refs/remotes/origin/main   # restore the ref
Command: git -c fetch.prune=true -c fetch.prune=false fetch --quiet "$FIX/remote.git" main:refs/remotes/origin/main
Result:  git rev-parse origin/main -> de7f197996d0867621e93312391f55251c98cb3b
Verdict: PASS — the -c fetch.prune=false override on bin/release's own fetch
         survives a global fetch.prune=true
```

```
Command: bash tests/share.sh
Result:  129 "ok" lines, final line "PASS"
Verdict: PASS
```

```
Command: shellcheck bin/release
Exit:    0
Verdict: PASS (no findings)
```

## Not exercised

The rest of `bin/release` (tag, push, tap-formula bump) is unchanged and out
of scope; this fix touches one fetch invocation. Per repo instructions,
`bin/release` itself was not run (it tags and publishes).
