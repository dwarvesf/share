# Verification -- handout-rename

The CLI is `handout`, with `bin/share` kept as a symlink alias. The menu bar app is Handout Bar. The README is a product page, and the team pages, CONTRIBUTING and the issue and PR templates are new. State-layer names (`~/share`, `SHARE_*`, Keychain items, `foundation.d.share*` labels, the bundle id, wire constants) are unchanged.

## Green run
```
Command: SHARE_TEST_PORT_BASE=41000 SHARE_TEST_ONLY='docs' bash tests/share.sh
Exit: 0
Output:
596 checks, PASS (filtered by SHARE_TEST_ONLY: 26 sections ran, the rest skipped)
Verdict: PASS
```

```
Command: command diff <(bin/handout version) <(bin/share version); ls -l bin/share
Exit: 0
Output:
alias-same: 0.9.0
bin/share -> handout
Verdict: PASS
```

Worker runs on this branch before the docs commits joined it: `/bin/bash -n bin/handout` under bash 3.2.57 passed, shellcheck on the CI file list passed, `swift test --package-path mac` ran 428 tests with 0 failures, `node tests/worker.mjs` passed, and the full `tests/share.sh` failed only the 3 docs checks shown below. The docs worker's full suite on the old code printed `1954 checks, PASS`. CI runs every shard on this PR.

## Negative control
```
Command: git archive 4f2392a (code renamed, docs not yet) into a temp dir; SHARE_TEST_ONLY='docs' bash tests/share.sh there
Exit: 1
Output:
  FAIL  every member verb, flag, config key and code in the docs is in bin/share, and the docs name each: expected '0', got '1'
  FAIL  negative control: a bin/share without --invite-ttl fails the member check, naming it: expected 'missing: --invite-ttl', got 'missing: handout join'
  FAIL  negative control: --cloud-links gone from bin/share is caught though --cloud remains: expected 'missing: --cloud-links', got 'missing: handout join'
6/596 FAILED
Verdict: PASS (the docs checks go RED when the code says handout and the docs do not; GREEN with the docs commits)
```
The other three failures in that run come from the temp dir having no git history (the groundwork section reads `git show`).

## Not proven
- An existing brew install moving to the `handout` formula (tap rename maps landed in dwarvesf/homebrew-tools#32).
- A signed Handout Bar release: the next `bin/release` and `mac/release.sh` run produces it.
- The demo GIFs still show `share`; they are not re-rendered.
