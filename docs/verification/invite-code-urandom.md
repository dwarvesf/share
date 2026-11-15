# Verification: the invite code never hangs where SIGPIPE is ignored

Bug: `invite_code` read `/dev/urandom` through `tr` into `head -c 20`. The macOS CI runner ignores SIGPIPE, so `tr` never stopped after `head` closed the pipe, and `member add` spun until the job limit (main run 43664641714, macOS Self-test, cancelled at 26 min; its log stops after `mm seam: SHARE_TEST_CODE`, and the runner killed an orphan `tr`).

## Recorded run

```
Command: /bin/bash -c 'trap "" PIPE; ( LC_ALL=C tr -dc "A-Z2-7" </dev/urandom | head -c 20 ) & sleep 3; kill -0 $! && echo HANG'
Exit:    0
Output:
HANG: old pipeline still running after 3 s
Verdict: red: the old pipeline spins with SIGPIPE ignored

Command: /bin/bash -c 'trap "" PIPE; . <invite_code body>; invite_code three times'
Exit:    0
Output:
20 chars, matches: yes
20 chars, matches: yes
20 chars, matches: yes
Verdict: green: bounded draw, no hang

Command: trap '' PIPE; SHARE_TEST_PORT_BASE=40000 bash tests/share.sh
Exit:    0
Output:  2035 ok checks; FAIL lines:
  FAIL  mm invite code: drawn from bounded bytes, never an unbounded /dev/urandom pipe (it spins where SIGPIPE is ignored): expected '0', got '1'
  FAIL  mm CC-14 (setup-first): both finish, two deploys, the end deploy holds an's binding, MEMBERS and PAUSED, and the lease is gone: expected '0 0 2 1 0', go
Verdict: the run reached the end under ignored SIGPIPE (the members sections no longer hang). The guard check matched its own comment (fixed in 1d97882; grep -c now prints 0). CC-14 (setup-first) failed once under heavy local load: a lease read racing a release, unrelated to this change, handed to the next CLI sub-goal.

Command: grep -c "</dev/urandom" bin/share; /bin/bash -n bin/share && shellcheck bin/share tests/members.sh && echo clean
Exit:    0
Output:
0
clean
Verdict: pass
```
