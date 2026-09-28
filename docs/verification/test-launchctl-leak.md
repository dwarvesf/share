# Proof of done: the suite never reaches the real launchctl or systemctl

Date: 2026-09-28
Branch: fix/test-launchctl-leak

## Root cause

`tests/share.sh` stubbed `launchctl` and `systemctl` by prefixing `PATH` on one call
(`PATH="$WORK/fakesvc:$QPATH" psh c service install`), but `psh` sets `PATH="$QPATH"`
inside, so the stub never applied. `service install` for profile `c` ran the real
`launchctl bootstrap` on a plist under a mktemp `HOME`. The job `foundation.d.share.c`
outlived the deleted HOME in the operator's gui session (exit 78) and had to be booted
out by hand.

## Fix

The stubs (`launchctl print` fails so the unload wait returns at once; everything else
exits 0) shadow both binaries on `PATH` for the whole run. A guard at the end lists the
real launchd (`launchctl list`) and systemd (`systemctl --user list-units`) jobs named
`foundation.d.share*` before and after the run and fails on any that appeared.

## Green run

```
Command: bash tests/share.sh
Exit:    0
Checks:  337 ok, 0 FAIL (PASS), at e0e2050
Tail:      ok    no real launchd or systemd share job appeared during the run
         PASS
Verdict: PASS
```

`shellcheck tests/share.sh` and `/bin/bash -n tests/share.sh` clean on the same tree.
`launchctl list` shows no `foundation.d.share*` job after the run.

## Negative control: the stub line removed

```
Command: sed -i.bak 's|^export PATH="$WORK/stubsvc:$PATH"$|# NEGCTL: stub removed|' tests/share.sh; bash tests/share.sh
Result:  RED, exit 1, at e0e2050:
           FAIL  no real launchd or systemd share job appeared during the run: expected '', got 'foundation.d.share.c'
         (one unrelated timing flake in the same run: "500-row index answers under 3s")
         launchctl list showed foundation.d.share.c live afterwards; booted out with
         launchctl bootout gui/$(id -u)/foundation.d.share.c
Command: git checkout -- tests/share.sh; bash tests/share.sh
Result:  GREEN, 337 ok, 0 FAIL, exit 0 (the green run above, same tree)
Verdict: PASS (mutate -> RED -> restore)
```
