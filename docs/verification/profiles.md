# Proof of done: profiles

Date: 2026-09-27 to 2026-09-28
Branch: feat/share-profiles
Spec: docs/specs/SPEC-005-profiles.md

## Green run

```
Command: bash tests/share.sh
Exit:    0
Checks:  336 ok, 0 FAIL (PASS), at 1c2a044 (the tree every control below names)
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
`add` of another profile's port and metrics port refused, and `add 8787` before the
default exists; `setup` on another profile's hostname or tunnel name refused with no
config written; a profile-created `~/share` and `~/share/profiles` at mode 700; a
metrics-port-only collision refused by name; `share profiles` under an exported
`SHARE_ROOT` still reading each profile's own state, and a corrupt profile as one
`error` row that breaks neither the listing nor another profile's port refusal; no
hint in `bin/share` naming a bare `share <verb>`; `serve` with `port=` hand-set to the
other profile's port dying by name while the other keeps answering; `teardown` of one
profile leaving the other serving and no empty profile dir. The pre-existing suite
runs unchanged around it, so the default profile's paths and behavior are the same
checks they were before.

## Negative control 1: the Keychain key drops the profile

```
Command: sed -i.bak 's|share-tunnel${profile:+.$profile}:|share-tunnel:|' bin/share; bash tests/share.sh
Result:  RED, exit 1, 5 FAILs (331 ok), at 1c2a044 (the first recording targeted the
         earlier variable form of the key and was replayed after the key became a function):
           FAIL  default profile stores share-tunnel:<host>: expected '1', got '2'
           FAIL  default profile reads share-tunnel:<host>: expected '1', got '2'
           FAIL  profile a stores share-tunnel.a:<host>: expected '1', got '0'
           FAIL  profile a reads share-tunnel.a:<host>: expected '1', got '0'
           FAIL  the two profiles never share an item: expected '2', got '1'
Command: git checkout -- bin/share; bash tests/share.sh
Result:  GREEN, 336 ok, 0 FAIL, exit 0, at 1c2a044
Verdict: PASS (mutate -> RED -> restore)
```

## Negative control 2: the port pick returns a constant

A mutation rather than a revert: reverting the pick would put both test profiles on
8787 beside the operator's real share on this machine, and caddy's SO_REUSEPORT would
split its live traffic for the length of the run.

```
Command: sed -i.bak 's|port="$(free_port)"; metrics_port|port=18797; metrics_port|' bin/share; bash tests/share.sh
Result:  RED, exit 1, 21 FAILs (315 ok), at 1c2a044, among them:
           FAIL  profile b sets up: expected '0', got '1'
           FAIL  the two profiles' ports differ: expected '1', got '0'
           FAIL  profile b is serving: expected '1', got '0'
           FAIL  profile roots are where the spec says: expected '1', got '0'
           FAIL  profile b link is on its own quick host: expected '1', got '0'
           FAIL  a's share is absent on b's port: expected '404', got '200'
           FAIL  b's share answers on b's port: expected '200', got '404'
           FAIL  profiles: b serving on its host: expected 'b	serving	prof-b.trycloudflare.com', got 'b	stopped	-'
Command: git checkout -- bin/share; bash tests/share.sh
Result:  GREEN, 336 ok, 0 FAIL, exit 0, at 1c2a044
Verdict: PASS (mutate -> RED -> restore)
```

## Negative control 3: the Keychain key fixed at load time (the round-2 bug)

```
Command: sed -i.bak 's|^token_key() { echo "share-tunnel${profile:+.$profile}:$host_name"; }|token_key_v="share-tunnel${profile:+.$profile}:$host_name"; token_key() { echo "$token_key_v"; }|' bin/share; bash tests/share.sh
Result:  RED, exit 1, 5 FAILs (331 ok), at 1c2a044:
           FAIL  default profile stores share-tunnel:<host>: expected '1', got '0'
           FAIL  default profile reads share-tunnel:<host>: expected '1', got '0'
           FAIL  profile a stores share-tunnel.a:<host>: expected '1', got '0'
           FAIL  profile a reads share-tunnel.a:<host>: expected '1', got '0'
           FAIL  no key was built before setup knew the hostname: expected '0', got '4'
Command: git checkout -- bin/share; bash tests/share.sh
Result:  GREEN, 336 ok, 0 FAIL, exit 0, at 1c2a044
Verdict: PASS (mutate -> RED -> restore)
```

Every control above was replayed in one sitting against 1c2a044, with the port 18787
idle (the sibling worktree's concurrent suite runs had contaminated an earlier
replay), and the tree was restored with `git checkout -- bin/share` between runs; the
green run at the top is the same tree. Plus the suite's own standing negative control,
last in every run: a host outside `hosts` must not serve.

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
| 8 | `profiles: three lines`, `profiles: default first ...`, `profiles: a serving on its host`, `profiles: b serving on its host`, `profiles under an exported SHARE_ROOT still reads each profile's own state`, `profiles: an unreadable profile is an error row`, `profiles: the other rows survive the error` |
| 9 | `the two profiles never share an item`, `no key was built before setup knew the hostname`, `the token value never reached the stub's argv or log` |
| 10 | `profile a teardown exits 0`, `profile a config dir is gone`, `profile a is no longer listed`, `profile b still serves after a's teardown` |
| 11 | `profile c's service file uses the suffixed label`, `... carries SHARE_PROFILE=c`, `... pins its own config dir and root` |
| 12 | `add of another profile's caddy port is refused`, `add of another profile's metrics port is refused`, `add of the default's 8787 is refused even before the default is set up`, `setup on another profile's hostname is refused`, `the refused setup wrote no config`, `setup on another profile's tunnel name is refused`, `a profile root's parents under ~/share are 700`, `serve on a port another profile listens on dies`, `the die names the port`, `the recovery hint names this profile's own setup`, `serve whose metrics port another profile listens on dies`, `b still answers alone on its port`, `another profile's corrupt port= does not break this profile's port refusal` |
| 13 | `--profile after the verb is refused`, `--profile=<name> after the verb is refused`, `help shows the --profile line and the profiles verb`, `help reaches teardown`, `no hint names a bare share <verb>` |

## UX walkthrough: the README on a clean HOME

`scratchpad/walkthrough.sh`: a fresh `HOME`, every `SHARE_*` override unset, the
suite's fake `cloudflared` on `PATH` (a trycloudflare banner, then idle) and
`SHARE_LIVE_CHECK=0`, so nothing reaches Cloudflare. The README's three-command
quickstart in its `--quick` variant, then the README's "second profile" block, then a
rerun, two wrong shapes, the skill text, the on-disk layout, and teardown. `share` is
the worktree's `bin/share`; the temp dir is shown as `$WORK`.

```
### README quickstart (default profile, --quick variant)

$ bash share setup --quick --no-service
  mode:       quick tunnel (no domain, no login; links get a random trycloudflare.com URL)
  ready:      https://demo.trycloudflare.com/ is live. The URL changes on every start. Next: share add <file|dir>
  [exit 0]

$ bash share add ./team-guide
  https://demo.trycloudflare.com/674fe4/team-guide/
  [exit 0]
### README: second profile

$ bash share --profile work setup --quick --no-service
  port:       8795 (metrics 8796)
  mode:       quick tunnel (no domain, no login; links get a random trycloudflare.com URL)
  ready:      https://work.trycloudflare.com/ is live. The URL changes on every start. Next: share add <file|dir>
  [exit 0]

$ bash share --profile work add ./guide
  https://work.trycloudflare.com/c6dc62/guide/
  [exit 0]

$ bash share profiles
  default	serving	demo.trycloudflare.com
  work	serving	work.trycloudflare.com
  [exit 0]

$ bash share ls
  https://demo.trycloudflare.com/674fe4/team-guide/
      id=674fe4  size=4.0K  added=2026-09-27  expires=2026-10-27  from=$WORK/team-guide
  [exit 0]

$ bash share --profile work ls
  https://work.trycloudflare.com/c6dc62/guide/
      id=c6dc62  size=12K  added=2026-09-27  expires=2026-10-27  from=$WORK/guide
  [exit 0]
### rerun is idempotent

$ bash share --profile work setup --quick --no-service
  mode:       quick tunnel (no domain, no login; links get a random trycloudflare.com URL)
  ready:      https://work.trycloudflare.com/ is live. The URL changes on every start. Next: share add <file|dir>
  [exit 0]
### a wrong shape prints the cause and the fix

$ bash share stop --profile work
  share: --profile goes before the verb: share --profile <name> stop
  [exit 1]

$ bash share --profile Work status
  share: bad profile name 'Work' (a-z, 0-9, -; 32 chars max)
  [exit 1]
### the skill teaches --profile

$ bash -c bash 'share' skill | grep -c -- '--profile'
  1
  [exit 0]
### on disk

$ bash -c cd '$WORK/home' && find share .config/share -maxdepth 3 -name config -o -maxdepth 3 -name serve.pid | sort
  .config/share/config
  .config/share/profiles/work/config
  share/profiles/work/serve.pid
  share/serve.pid
  [exit 0]
### teardown

$ bash share --profile work teardown --yes
  removed the quick setup (no tunnel, DNS, or token existed); shares in $WORK/home/share/profiles/work stay
  [exit 0]

$ bash share teardown --yes
  removed the quick setup (no tunnel, DNS, or token existed); shares in $WORK/home/share stay
  [exit 0]

$ bash share profiles
  default	not_setup	-
  [exit 0]
```

Every command did what the README says on the first try; the profile setup printed
its picked port; a rerun reused it silently; the two wrong shapes named the cause and
the fix; teardown of `work` left the default serving and removed the profile from the
listing. Not covered here: a named hostname (needs a Cloudflare token), the login
service (`--no-service` throughout), and the real `cloudflared`.

## Not proven

- A named-mode profile against the live Cloudflare edge (tunnel, DNS, Keychain on a
  real login keychain, launchd under the real launchd). The spec's Verification lists
  the live steps for the Mini; they need a token with Tunnel Edit, DNS Edit, and Zone
  Read on `d.foundation`, which the operator has to create.
- Linux: the systemd branch of the service test runs only where `uname -s` is not
  Darwin, so CI's Ubuntu job is the one that exercises it.
