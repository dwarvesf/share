# Proof of done: member docs grep (SPEC-009 TASK-4c grep)

Branch: test/members-live-e2e, on main at 66903f9.
Notes: docs/implementation-notes/member-docs.md ("Re-check against the built verbs")

Scope: the docs half of the live e2e sub-goal. The live suite (`tests/e2e-members.sh`, ML-1 to ML-12, the OQ-7 leg) did not run: R2 is off on Console Labs (a bucket create answers `10042`) and the admin token lacks an R2 permission group (`10000`). That half stays open.

What the grep proves: every member verb is dispatched in `cmd_member`, and every verb, flag, config key and refusal code the docs name is a whole word in `bin/share` and in the README, `docs/setup.md` and `docs/how-it-works.md` taken together. It proves no behavior.

Unexercised against Cloudflare (R2 off on Console Labs): the live member WebSocket, adopt, rotate, renew and pause on a real bucket. The docs describe them from the code and the dry fixtures; the live acceptance sub-goals still owe that run.

## Recorded run

```
Command: SHARE_TEST_PORT_BASE=34500 SHARE_TEST_ONLY='tenant docs' bash tests/share.sh
Exit:    0
Output:
  ok    every tenant command, flag, and state key in the docs is in bin/share
  ok    every member verb, flag, config key and code in the docs is in bin/share, and the docs name each
  ok    negative control: the docs without member adopt fail the member check, naming it
  ok    negative control: a bin/share without --invite-ttl fails the member check, naming it
  ok    negative control: a bin/share that no longer dispatches member pause fails the member check
  ok    negative control: --cloud-links gone from bin/share is caught though --cloud remains
559 checks, PASS (filtered by SHARE_TEST_ONLY: 25 sections ran, the rest skipped)
Verdict: PASS (the new member docs check and its four negative controls: docs without member adopt, bin/share without --invite-ttl, bin/share that no longer dispatches pause, --cloud-links gone while --cloud remains)
```

```
Command: shellcheck tests/share.sh; /bin/bash -n tests/share.sh; bash tests/ci/shard-check.sh
Exit:    0
Verdict: PASS (85 sections, each in exactly one shard)
```

```
Command: kit:doc-verifier over the diff and every member-verb claim in README, setup 4i and how-it-works against bin/share
Exit:    0
Verdict: FAIL:fixable on the first pass (3 wrong claims: a pointer to a missing proof file, OC-05 listed as absent, OC-06 and OC-08 attributed to unlabelled tests); all 3 fixed
```

```
Command: kit:advisor (critique) over the frozen diff
Exit:    0
Verdict: 2 major folded (the grep now checks dispatch and whole words, and the controls assert the named term), 2 minor folded (stale proof header, the unexercised-live line above)
```

The full suite ran in CI shards only: one local process outlives the 10 minute tool limit, and a local `chain` shard started beside a leftover process from a killed run failed on server start, so it proves nothing.

## Rollback

Docs and tests only: `git revert` of the squash commit.
