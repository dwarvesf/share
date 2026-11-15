# Verification: the invite code never hangs where SIGPIPE is ignored

Bug: `invite_code` read `/dev/urandom` through `tr` into `head -c 20`. The macOS CI runner ignores SIGPIPE, so `tr` never stopped after `head` closed the pipe, and `member add` spun until the 6 h job limit (main run 43664641714, macOS Self-test, cancelled at 26 min; its log stops after `mm seam: SHARE_TEST_CODE`, and the runner killed an orphan `tr`).

## Recorded run

```
Command: /bin/bash -c 'trap "" PIPE; ( LC_ALL=C tr -dc "A-Z2-7" </dev/urandom | head -c 20 ) & sleep 3; kill -0 $! && echo HANG'
Exit:    0
Verdict: red before the fix: HANG (the old pipeline spins with SIGPIPE ignored)

Command: /bin/bash -c 'trap "" PIPE; . invite_code body; invite_code x3'
Exit:    0
Verdict: green: three 20-character base32 codes, no hang

Command: trap '' PIPE; SHARE_TEST_PORT_BASE=40000 bash tests/share.sh
Exit:    0 (suite ran to the end under ignored SIGPIPE; the members sections no longer hang)
Verdict: the new guard check went red on its own comment, fixed in 1d97882; CC-14 (setup-first) failed once under load, a lease read racing a release, unrelated to this change and handed to the next CLI sub-goal

Command: /bin/bash -n bin/share && shellcheck bin/share tests/members.sh
Exit:    0
Verdict: pass
```
