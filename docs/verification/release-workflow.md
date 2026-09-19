# Verification: release.yml checkout fix

Work: `.github/workflows/release.yml` gained `actions/checkout@v4` so
`gh release create --verify-tag` runs inside a git repository.

Done = the failing step's command succeeds when run from a checkout, and the
original failure mode is on record.

## Negative control (the real failure, observed in CI)

Tag `v0.3.0` was pushed by `bin/release`; the tag-push run executed the
pre-fix workflow.

```
Run:     https://github.com/dwarvesf/share/actions/runs/35430215256
Command: gh release create "v0.3.0" --generate-notes --verify-tag
Exit:    1
Verdict: RED   "failed to run git: fatal: not a git repository
               (or any of the parent directories): .git"
```

## Green run

The identical command, run inside a checkout of the repo (what the fix adds):

```
Command: gh release create v0.3.0 --generate-notes --verify-tag -R dwarvesf/share
Exit:    0
Output:  https://github.com/dwarvesf/share/releases/tag/v0.3.0
Verdict: PASS   (release created; listed by `gh release list` as Latest)
```

The fix cannot be exercised end-to-end until the next tag push; what is
proven here is the mechanism: the failing command succeeds from a checkout,
and `actions/checkout` is what provides one in the job.
