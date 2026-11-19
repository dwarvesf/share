# Verification -- ci-macos-timeout

`test-full` gets a 45 minute timeout. The whole suite on macos-latest runs 23 to 30 minutes, so the old 30 minute limit cancelled most main runs.

## Green run
```
Command: gh run view <id> --json jobs, for the last six main CI runs, job test-full (macos-latest)
Exit: 0
Output:
feat: rename share to Handout and add th | cancelled 30m
feat(share): media-aware generated folde | success 25m
docs: re-check member docs against the b | cancelled 30m
feat(share): member adopt, min_cli enfor | success 23m
feat(sharebar): members tab, all links w | cancelled 30m
feat(share): member pause, resume, invit | cancelled 30m
Verdict: PASS (every finished run took 23 to 25 min; every cancel sat at the 30 min limit, so 45 leaves headroom)
```

## Negative control
```
Command: gh run view <id> --log for the cancelled rename run, job test-full (macos-latest)
Exit: 0
Output:
  ok    mm seam: SHARE_R2_DRY_COMMIT_FAIL applies the create, then answers 500
##[error]The operation was canceled.
Verdict: PASS (with the 30 min limit the job is cancelled mid-suite while checks still pass)
```

## Not proven
- The first main run after this merge finishing under 45 min; check its test-full (macos-latest) job.
