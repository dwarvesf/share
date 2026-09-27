# Verification: notary key item found by title suffix

Work: `mac/release.sh` gains a second 1Password fetch mode. When `NOTARY_KEY` and `NOTARY_KEY_OP` are unset and `NOTARY_ITEM_SUFFIX` plus `NOTARY_VAULT` are set, it lists the vault, requires exactly one item whose title ends in the suffix, fetches that item as JSON into a mode-600 temp file, writes the key field into a mode-600 key file, checks the key file starts with a PEM header, and exports `NOTARY_KEY`, `NOTARY_KEY_ID`, and `NOTARY_ISSUER`. Fields match by case-insensitive label regex (`p8|private key`, `^key ?id`, `issuer`), each overridable by env. The cleanup trap removes both temp files. `RELEASE_DRY=1` prints `would resolve the notary key item by suffix` and calls no `op`.

Done = against a stub `op`, the success path exports all three values with both temp files at mode 600 and gone after exit; zero or two matching titles die with the count; a missing field dies naming it; a dry run never calls the stub; and a broken suffix filter turns the harness red.

## Method

No real `op` and no real release ran. A scratch harness (outside the repo) builds a stub `op` first on `PATH` that logs every call to a marker file and answers `item list` and `item get` from fake JSON. The fake key value is PEM-shaped, and the harness builds its header at runtime, so no literal header sits in any file. The harness extracts the script's real prelude (`die()` through the line before `cask_body()`, so `cleanup`, the EXIT trap, and both fetch functions are the shipped code), sources it in a fresh `/bin/bash` per case with a private `TMPDIR`, calls `fetch_notary_key`, and checks the case's `TMPDIR` is empty after the shell exits. The two dry-run cases run the whole `mac/release.sh`.

Fixtures: the one-match list also holds a decoy title that contains the suffix without ending in it (`Notary API Key (old copy)`), so a substring filter would count two.

## Green run

```
Command: shellcheck mac/release.sh
Exit:    0
Verdict: PASS

Command: /bin/bash -n mac/release.sh   # macOS bash 3.2 parse
Exit:    0
Verdict: PASS

Command: bash harness.sh mac/release.sh
Exit:    0
Output:
PASS success: 3 exported, key+item mode 600, key never printed, temp files gone
  KEY_MODE=600 ITEM_MODE=600 KEY_MATCH=yes NOTARY_KEY_ID=FAKEKEYID1 NOTARY_ISSUER=00000000-fake-issuer tmp_left=0
PASS zero matching titles dies with the count
  rc=1: release.sh: expected 1 item whose title ends in NOTARY_ITEM_SUFFIX, found 0
PASS two matching titles dies with the count
  rc=1: release.sh: expected 1 item whose title ends in NOTARY_ITEM_SUFFIX, found 2
PASS missing key id field dies naming it, temp files gone
  rc=1: release.sh: no key id field matching /^key ?id/ in the notary item
PASS missing issuer field dies naming it
  rc=1: release.sh: no issuer field matching /issuer/ in the notary item
PASS missing private key field dies naming it
  rc=1: release.sh: no private key field matching /p8|private key/ in the notary item
PASS non-PEM key value dies
  rc=1: release.sh: the private key field matching /p8|private key/ is not a PEM key
PASS NOTARY_KEY_ID_FIELD_RE overrides the pattern
PASS RELEASE_DRY=1 prints the line and never calls op (marker absent)
  rc=0 marker=absent: would resolve the notary key item by suffix
PASS NOTARY_KEY_OP mode unchanged and takes precedence
harness: 0 failure(s)
Verdict: PASS
```

`KEY_MATCH=yes` compares the key file to the fake value inside the case shell; the harness also greps both output streams to confirm the key text never reached the terminal.

## Negative control

A scratch copy of `mac/release.sh` with the suffix filter broken to a substring match, same harness:

```
Command: sed 's/endswith(\$s)/contains($s)/g' mac/release.sh > <scratch>/mac/release.sh
         bash harness.sh <scratch>/mac/release.sh
Exit:    1
Output (excerpt):
FAIL success: ... err=[release.sh: expected 1 item whose title ends in NOTARY_ITEM_SUFFIX, found 2]
FAIL zero matching titles dies with the count: rc=1 err=[stub: wrong id decoy
release.sh: op item get failed for the NOTARY_ITEM_SUFFIX item]
FAIL missing key id field dies naming it ... found 2
harness: 7 failure(s)
Verdict: RED as expected (the decoy title is counted, so the suffix filter is load-bearing)
```

## Not proven

- No run against a real 1Password item or a real `op`; the real item's JSON shape is assumed to carry `fields[].label` and `fields[].value`, as `op item get --format json` does.
- No real notarization with the exported key.

## Rollback

Revert the commit: `git revert <this commit>`; the `NOTARY_KEY_OP` mode and the keychain profile path are untouched by it.
