# Member lifecycle verbs: proof of done

SPEC-009 TASK-3a to 3d: `share member pause`, `resume`, `invite`, `rotate` and `renew`, the member's expiry warnings, and the CC-14 (setup-first) lease-read flake. Notes: `docs/implementation-notes/multi-member.md` ("Phase 3 build", P41 to P52). Dry seams only; nothing ran against Cloudflare.

Done = TASK-3a to 3d pass their AC; the MB and DP rows of those tasks are green; a rotate of a paused member followed by a re-join ends `paused` (`mm MB-12 (paused)`, `mm DP-rotate (paused)`, `mm MB-26 (verbs)`); renew on a token the current minter cannot find reports `token_unreachable` with its expiry (`mm MB-37`). Every token, tunnel and VPC Service is found by name.

## Recorded run

All runs on the Mac mini in the SG-08 worktree, `SHARE_TEST_PORT_BASE=30000`. The host load average ran from 10 to 56 (other sessions' suites).

### The new section, filtered

Command: `SHARE_TEST_ONLY='^members: pause, resume' SHARE_TEST_PORT_BASE=30000 bash tests/share.sh` (at 826e2b6, after the review fixes)
Exit: 0
Verdict: green
Output: `59 checks, PASS (filtered by SHARE_TEST_ONLY: 1 sections ran, the rest skipped)`

Command: `SHARE_TEST_ONLY='^members: pause, resume' SHARE_TEST_PORT_BASE=30000 bash tests/share.sh` (at 42a5a3c, after the advisor fixes)
Exit: 0
Verdict: green
Output: `64 checks, PASS (filtered by SHARE_TEST_ONLY: 1 sections ran, the rest skipped)`

Command: `SHARE_TEST_ONLY='^members: (member rm and member purge|revoke and reconcile|leave and the member|tenant T1 to T2|dry seams|member ls and member sync)' SHARE_TEST_PORT_BASE=30000 bash tests/share.sh` (at 2077648)
Exit: 0
Verdict: green: the dry bucket fix and the join changes break no rm, reconcile, leave, tenant or sync row
Output: `154 checks, PASS (filtered by SHARE_TEST_ONLY: 6 sections ran, the rest skipped)`

Command: the `members-b` shard regex of `tests/ci/shards.txt`, `SHARE_TEST_PORT_BASE=30000 bash tests/share.sh` (at 2077648)
Exit: 1
Verdict: red on one expected change: MB-28's line now reads `step 3 of 4 (deploy)`, since `pause` has a step table. The expectation was updated; the full run below is green on it.
Output: `2/151 FAILED`

### Negative controls (each red on a mutant, green on the real code)

Each mutant is a copy of `bin/share` with one change, run as `MX_SH=<mutant> MXM_SH=<mutant> SHARE_TEST_ONLY='^members: pause, resume' SHARE_TEST_PORT_BASE=30000 bash tests/share.sh`. Green: the filtered runs above.

Command: NC-CC14, the dry GET reads the file non-atomically again (`cf_body="$(cat "$f")"; r2_etag="$(r2_md5 "$f")"`), with `SHARE_R2_DRY_VANISH="GET lock/admin"` forcing the release between the check and the read
Exit: 1
Verdict: red as expected: `mm CC-14 (vanished lease)` got `1 1 active 1` (the pause died "needs the admin S3 pair", the CC-14 flake's message)
Output: `1/56 FAILED`

Command: NC-guard, join step 6 without the `reg_guard` on the redeemed invite hash
Exit: 1
Verdict: red as expected: `mm CC-03 (join loses)` (the old code's join landed on the rotated member) and its follow-up row
Output: `2/56 FAILED`

Command: NC-rot, rotate takes the record's rotation plus one, ignoring the names on the account
Exit: 1
Verdict: red as expected: `mm DEC-58: a forged rotation never reuses a live tunnel name` (the forged `rotation: 0` reused `-r1`)
Output: `1/59 FAILED`

Command: NC-renew, `mb_token_reach` never refuses
Exit: 1
Verdict: red as expected: `mm MB-37` (renew under another user's minter did not die `token_unreachable`)
Output: `1/59 FAILED`

Command: NC-rotjournal, a rerun keeps the record's rotation whenever the record reads `rotating` (no journal check)
Exit: 1
Verdict: red as expected: `mm DEC-58, DEC-67: a forged rotating record never makes rotate keep the live tunnel`
Output: `1/59 FAILED`

### Full suite, once, under macOS /bin/bash 3.2

Command: `PATH=<shim dir with bash -> /bin/bash>:$PATH SHARE_TEST_PORT_BASE=30000 /bin/bash tests/share.sh` (every section, no filter, at 42a5a3c; `bash` resolves to 3.2.57, so `tests/share.sh` and every `bash bin/share` run under macOS bash 3.2)
Exit: 0
Verdict: green; the count grew from 1842 (SG-18) to 1892
Output: `1892 checks, PASS`, `exit=0 secs=1618 bash=3.2.57(1)-release`

## Review

`/kit:review` ran as an independent `kit:code-reviewer` (correctness and security), then `kit:advisor` (critique) on the frozen diff. The spec's `## Review` section was not replaced (SPEC-009 is outside this sub-goal's Touches; its verdict line already reads SHIP).

### Verdict: SHIP

Findings, each fixed and covered by a row:
- HIGH (review): a forged `rotating` record made rotate reuse the live tunnel, so a leaked connector kept serving. Fixed in 826e2b6 and 42a5a3c: only this machine's dead rotate journal of the same member vouches for the record's rotation. Rows: `mm DEC-58, DEC-67: ...`, `mm DEC-58: a dead rotate journal of another member ...`; NC-rotjournal.
- MEDIUM (review): invite and rotate could refuse toward each other when a tunnel was deleted outside share. Fixed: invite makes the tunnel again under its name. Row: `mm TASK-3b: invite of a member whose tunnel was deleted outside share ...`.
- MEDIUM (review): renew copied `status: expired` back into its PUT. Fixed: `active` (a disabled token stays disabled). Row: `mm MB-18: renew of an expired token ...`.
- Major (advisor): DP-rotate rows did not re-join. Fixed: each rerun now re-joins and asserts `active`; a paused case asserts `paused`.
- Major (advisor): a dead rotate journal of another member vouched for this one. Fixed (above).
- Major (advisor): `sync --rebind` could rebind a died rotate's old service, and ignored `prev_status` `paused`. Fixed. Rows: `mm TASK-3c, sync --rebind: ...` (2).
- Major (advisor): invite from `left` after a paused leave ended `active` while `PAUSED` held the member. Fixed. Row: `mm TASK-3b: invite from left while the deploy still pauses ...`.
- Major (advisor): `member ls` warned from the member-writable record. Fixed: it reads the minter's own token list when `SHARE_MINTER_TOKEN` is set.

### Previously rejected

none (`docs/verification/rejected-findings.md` does not exist)

### TODOs (open follow-ups)

- A forged `mode: cloud` record makes pause and rotate refuse `member_cloud` (the same class as a forged status; notes Q5).
- A bare resumed join has no invite hash, so the CC-03 guard holds only in the run that redeemed (notes P47).
- The member's own expiry display follows its record, which members can write (notes P46).

## Rollback

The change touches persistent state (bucket records `u/`, `i/`, the Worker's `PAUSED` and bindings, member tokens) only through the new verbs; no existing verb writes anything new. Rollback is a revert of the merge commit on main: the older CLI ignores records in the new statuses (`member_can` is unchanged), and `member rm` cleans any member a new verb left mid-way, finding every object by name. A member paused by the new CLI stays paused under the old one (the deploy holds `PAUSED`); `share member sync` keeps it so (DEC-75). No migration, no data format change.

## UAT

Not applicable here: dry seams only. The live legs (ML-8 pause and resume at verb exit) belong to SG-17 and SG-12.
