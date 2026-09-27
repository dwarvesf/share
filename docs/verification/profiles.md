# Proof of done: profiles

Date: 2026-09-27
Branch: feat/share-profiles
Spec: docs/specs/SPEC-005-profiles.md

## Green run

```
Command: bash tests/share.sh
Exit:    0
Checks:  320 ok, 0 FAIL (PASS)
Tail:    === NEGATIVE CONTROL: a host outside hosts must not serve ===
           ok    start refused on another host
         === process leaks ===
           ok    serve.pid removed
         PASS
Verdict: PASS
```

`shellcheck bin/share install.sh tests/share.sh tests/e2e.sh demo/render.sh mac/*.sh` and
`/bin/bash -n bin/share` clean on the same tree.

Covers, in the new `=== profiles ===` section: derived paths, label, and name check
through a probe of the script's top block (no flag, `default`, empty `SHARE_PROFILE`,
flag over variable both ways, five bad names each as flag and variable, a bare
`--profile`, a `--profile` after the verb, help through `teardown`); the Keychain
service name per profile through a stubbed `security` that logs `-s` and never `-w`;
two quick profiles set up and serving at once under a private `HOME` with picked,
disjoint ports, each answering on its own port and 404ing on the other's, each `ls`
showing only its rows, `SHARE_PROFILE` from the environment; `share profiles` with
three rows; a setup rerun keeping the port; `hits`, `refresh`, `rm`, `state` on one
profile leaving the other's row and server; the service file of a profile through
stubbed `launchctl`/`systemctl` (suffixed label, `SHARE_PROFILE`, pinned dirs);
`add` of another profile's port and metrics port refused; `setup` on another
profile's hostname refused with no config written; `serve` with `port=` hand-set to the
other profile's port dying by name while the other keeps answering; `teardown` of one
profile leaving the other serving and no empty profile dir. The pre-existing suite
runs unchanged around it, so the default profile's paths and behavior are the same
checks they were before.

## Negative control 1: the Keychain key drops the profile

```
Command: sed -i.bak 's|^token_key="share-tunnel${profile:+.$profile}:$host_name"|token_key="share-tunnel:$host_name"|' bin/share; bash tests/share.sh
Result:  RED, exit 1, 5 FAILs:
           FAIL  default profile stores share-tunnel:<host>: expected '1', got '2'
           FAIL  default profile reads share-tunnel:<host>: expected '1', got '2'
           FAIL  profile a stores share-tunnel.a:<host>: expected '1', got '0'
           FAIL  profile a reads share-tunnel.a:<host>: expected '1', got '0'
           FAIL  the two profiles never share an item: expected '2', got '1'
         313 ok
Command: git checkout -- bin/share; bash tests/share.sh
Result:  GREEN (the green run above)
Verdict: PASS (mutate -> RED -> restore)
```

## Negative control 2: the port pick returns a constant

A mutation rather than a revert: reverting the pick would put both test profiles on
8787 beside the operator's real share on this machine, and caddy's SO_REUSEPORT would
split its live traffic for the length of the run.

```
Command: sed -i.bak 's|port="$(free_port)"; metrics_port|port=18797; metrics_port|' bin/share; bash tests/share.sh
Result:  RED, exit 1, 14 FAILs (304 ok), among them:
           FAIL  profile b sets up: expected '0', got '1'   (serve refused the double bind)
           FAIL  the two profiles' ports differ: expected '1', got '0'
           FAIL  a's share is absent on b's port: expected '404', got '200'
           FAIL  b's share answers on b's port: expected '200', got '404'
           FAIL  profile b still serves after a's teardown: expected '1', got '0'
Command: git checkout -- bin/share; bash tests/share.sh
Result:  GREEN (the green run above)
Verdict: PASS (mutate -> RED -> restore)
```

## Negative control 3: the Keychain key fixed at load time (the round-2 bug)

```
Command: sed -i.bak 's|^token_key() { echo "share-tunnel${profile:+.$profile}:$host_name"; }|token_key_v="share-tunnel${profile:+.$profile}:$host_name"; token_key() { echo "$token_key_v"; }|' bin/share; bash tests/share.sh
Result:  RED, exit 1, 5 FAILs (315 ok):
           FAIL  default profile stores share-tunnel:<host>: expected '1', got '0'
           FAIL  default profile reads share-tunnel:<host>: expected '1', got '0'
           FAIL  profile a stores share-tunnel.a:<host>: expected '1', got '0'
           FAIL  profile a reads share-tunnel.a:<host>: expected '1', got '0'
           FAIL  no key was built before setup knew the hostname: expected '0', got '4'
Command: git checkout -- bin/share; bash tests/share.sh
Result:  GREEN, 320 ok, 0 FAIL, exit 0
Verdict: PASS (mutate -> RED -> restore)
```

Plus the suite's own standing negative control, last in every run: a host outside
`hosts` must not serve.

## Test plan coverage

| Row | Covered by |
|---|---|
| 1 | `no profile: today's paths and label`, `default profile stores share-tunnel:<host>`, `default profile reads share-tunnel:<host>` |
| 2 | `--profile a: paths under profiles/a, label suffixed`, `SHARE_PROFILE=a: the same derivation`, `the flag wins over SHARE_PROFILE`, `--profile default wins over SHARE_PROFILE=a`, `profile a stores share-tunnel.a:<host>` |
| 3 | `profile name '<bad>' is refused` x5, `SHARE_PROFILE='<bad>' is refused too` x5, `--profile with no name is a usage error` |
| 4 | `--profile default is the same as no profile`, `SHARE_PROFILE= (empty) is the default` |
| 5 | `profile a config holds a picked port`, `setup printed the picked port`, `the two profiles' ports differ`, `neither port pair overlaps ...`, `the pick skips a port another profile live-shares`, `profile a is serving`, `profile b is serving`, `a's share answers on a's port`, `a's share is absent on b's port`, `share ls under a shows only a`, `SHARE_PROFILE=b from the environment also lists b` |
| 6 | `rerun keeps a's port` |
| 7 | `a's state has one share`, `a's hits counts a's fetches`, `refresh under a exits 0`, `rm under a removes a's row`, `rm under a leaves b's row`, `b's share still answers` |
| 8 | `profiles: three lines`, `profiles: default first ...`, `profiles: a serving on its host`, `profiles: b serving on its host` |
| 9 | `the two profiles never share an item`, `no key was built before setup knew the hostname`, `the token value never reached the stub's argv or log` |
| 10 | `profile a teardown exits 0`, `profile a config dir is gone`, `profile a is no longer listed`, `profile b still serves after a's teardown` |
| 11 | `profile c's service file uses the suffixed label`, `... carries SHARE_PROFILE=c`, `... pins its own config dir and root` |
| 12 | `add of another profile's caddy port is refused`, `add of another profile's metrics port is refused`, `setup on another profile's hostname is refused`, `the refused setup wrote no config`, `serve on a port another profile listens on dies`, `the die names the port`, `b still answers alone on its port` |
| 13 | `--profile after the verb is refused`, `--profile=<name> after the verb is refused`, `help shows the --profile line and the profiles verb`, `help reaches teardown` |

## Not proven

- A named-mode profile against the live Cloudflare edge (tunnel, DNS, Keychain on a
  real login keychain, launchd under the real launchd). The spec's Verification lists
  the live steps for the Mini; they need a token with Tunnel Edit, DNS Edit, and Zone
  Read on `d.foundation`, which the operator has to create.
- Linux: the systemd branch of the service test runs only where `uname -s` is not
  Darwin, so CI's Ubuntu job is the one that exercises it.
