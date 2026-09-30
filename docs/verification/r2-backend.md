# Proof of done: r2 backend, batch 1

Date: 2026-09-30
Branch: docs/r2-backend-spec
Spec: docs/specs/SPEC-007-r2-backend.md

## Green run

```
Command: SHARE_TEST_PORT_BASE=38787 bash tests/share.sh
Exit:    0
Checks:  545 ok, 0 FAIL (PASS), at aff423d (backend load, sentinel, setup refusals)
Tail:    === process leaks ===
           ok    serve.pid removed
         PASS
Verdict: PASS
```

`shellcheck bin/share tests/share.sh` and `/bin/bash -n` on both are clean on the same tree.

The new `=== r2 backend ===` sections cover row 2 (every setup argument refusal:
missing and bad `--bucket`, `--quick`, `--no-service`, `--login`, `--tunnel-name`,
a bogus `--backend`, `--bucket` without `--backend r2`, setup over a tunnel config,
and start, stop, serve, service install, teardown, live add, `--host` add, tunnel
and quick setup on an r2 profile), row 22 (`origin/main`'s share dies on the
`port=r2` sentinel at load for add, gated add, ls, and setup, with nothing written
under the profile root), and row 1 (a compat driver runs quick setup, add file,
add folder, add live, a refused `--host` add, ls, state, and service install under
one private HOME for `origin/main` and this branch, then diffs every artifact
byte for byte).

## Negative controls

```
Command: sed the backend= load line to backend="", then
         SHARE_TUNNEL=0 bash bin/share --profile r2x start   (r2 profile config)
Exit:    1 with "port 'r2' is not a number"
Verdict: RED. Without the backend load the r2 refusal never runs; the config's
         own port sentinel is the only thing that stops the verb. Restored, the
         same call answers "an r2 profile has no local server" (green above).
```

Row 22 is itself a shipped negative control: `origin/main` cannot read
`backend=r2` and every verb dies on the sentinel before it can write a pub/ tree
or an Access app against an r2 profile.
