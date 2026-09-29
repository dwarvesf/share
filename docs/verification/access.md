# Proof of done: per-link Access gate

Date: 2026-09-28 to 2026-09-29
Branch: feat/access-gate
Spec: docs/specs/SPEC-004-access.md
Notes: docs/implementation-notes/access.md

## Green run

```
Command: bash tests/share.sh
Exit:    0
Checks:  499 ok, 0 FAIL (PASS), at 37a85d5, tree 444975f (the tree every control below names)
Tail:    === process leaks ===
           ok    serve.pid removed
           ok    no real launchd or systemd share job appeared during the run
         PASS
Duration: 185 s, run alone
Verdict: PASS
```

`shellcheck bin/share tests/share.sh tests/e2e.sh` and `/bin/bash -n bin/share` clean on the same tree.

The `=== access ===` section runs with `SHARE_TUNNEL=0` and `SHARE_ACCESS_DRY=1`: every Cloudflare call goes through the real `cf_try` path and is answered from fixtures, and call order is read from line numbers in `access-calls.log`. Row 26 turns dry mode off and puts a `curl` shim first on `PATH`. The pre-existing suite runs unchanged around the new section.

## Test-section coverage map

| Row | Case | Covered by |
|---|---|---|
| 1 | three rule forms | `email:`, `domain:`, `group:` row and include checks |
| 2 | bad rules refused | `--access '<bad>' exits 1 with the usage line` (nine inputs), `row 2:` checks |
| 3 | quick mode, dry seam with tunnel | `quick mode refuses --access`, `row 3:` |
| 4, 27 | no token source | `no token:` checks (block text, URL keys decode to three pairs, form name, profile form) |
| 5 | group lookup | `missing group:`, `two groups of one name:`, `paged group:` |
| 6 | publish order, snapshot | `row 6:` (four checks); negative control A |
| 7 | publish order, live | `row 7:` (three checks) |
| 8 | gate timeout | `timeout:` (five checks) |
| 9 | rm | `rm gated:` (five checks); negative control C |
| 10 | expiry without a token | `prune without a token:`, `status prints the pending count`, `state counts it` |
| 11, 11b | sweep, orphaned bytes | `row 11:`, `row 11b:` |
| 12, 12b | teardown | `row 12:`, `row 12b:`; negative control C also reds `row 12b` |
| 13 | forged rows | row 13 section, `forged gated rows counted in skipped` |
| 14 | state | `row 14:` |
| 15 | compat | the whole pre-existing suite, green |
| 16 | negative control | negative control A below |
| 17 | e2e gated leg | `tests/e2e.sh` private-link leg, live (below) |
| 18 | e2e `--host` plus `--access` | e2e `--host plus --access` leg, live (below) |
| 19 | e2e rm | e2e `GET access/apps/<app> is 404`, `no app named for this share remains`, live (below) |
| 20 | two zones | e2e check behind `SHARE_E2E_OTHER_HOST` (deviation in the notes); not in the recorded live run |
| 21 | UAT | open: Han opens a `group:dwarves-ops` link |
| 22 | Caddy encoded separators | row 22 section (five encoded paths, plain link, `%25` file, query, adapted route order); negative control B |
| 23, 23b, 23c, 23d | lost POST, unproven list, lost DELETE, young no-match | `lost POST:`, `row 23:`, `row 23b:`, `row 23c:`, `row 23d:` |
| 24, 25, 25b | pending ids, live owner, reused pid | `row 24:`, `row 25:`, `row 25b:` |
| 26 | token never in argv | `shim:` checks (sentinel token through a `curl` shim) |
| 28, 29 | api-token store, preflight | rows 28 and 29 section (`--cmd`, stored-once, scope lines, MISSING lines, idempotent output) |
| 30 | clean-HOME walkthrough | proven live against the Dwarves account, below |
| 31 | gauntlet | one round at `docs/verification/gauntlet/2026-09-28-readme-quickstart-access/card.md`, PASS on the first try, below |
| 32 | error lines name a fix | `no fix-naming line ends without a command or a URL` |
| 33 | api-token with no argument | row 33 section (`expect` drives the prompt; `expect` present on this machine, so it ran) |
| 34 | Host binding | `main host block names the hostname and loopback, never any Host`, `a foreign Host gets the 404 catch-all, not the pub tree` |
| 35 | foreign app | `a pending line whose app is not this share's is never deleted` and the malformed-line checks |
| 36 | deferred owner | `serve's own expiry defers the app with no live owner`, `serve's startup prune makes no Access call` |
| 37 | round 8 refusals | `row 37:` (four checks) |
| 38 | teardown with a foreign app | `row 38:` |

## Negative controls

All three ran at once on `cp -R` copies of the worktree at 37a85d5 (tree 444975f), each with its own `SHARE_TEST_PORT_BASE` (24000, 36000, 48000; the green at 12000 alongside). Each ran the full suite; the suite has no section filter. FAILs outside the access section come from the profiles section, which picks its own ports and ignores the port base (see the notes); they are listed as noise and are not part of the control.

### A: publish before the gate is confirmed

```
Mutation: line 472  if [[ -z $access ]]; then stage_publish "$id"; warn_private ...; fi
          ->        stage_publish "$id"; [[ -n $access ]] || warn_private "$src" "$id"
          line 490  [[ $kind == snapshot ]] && stage_publish "$id"  ->  :
Result:   RED, exit 1, 494 ok, 5 FAIL (all access):
            FAIL  row 6: POST app < every PROBE < PUBLISH
            FAIL  timeout: DELETE app logged, no PUBLISH
            FAIL  timeout: no pub/<id>, no stage, pending empty
            FAIL  lost POST: no PUBLISH, no row
            FAIL  row 23c: the add finds its line gone, publishes nothing, dies
```

### B: remove the Caddy 400 on encoded paths

```
Mutation: delete the @encsep matcher and its handle { respond 400 } block (bin/share lines 641 to 644)
Result:   RED, exit 1, 492 ok, 7 FAIL (6 access, 1 profiles noise):
            FAIL  encoded path /x/..%2F<id>/gated.txt answers 400: got 200
            FAIL  encoded path /%2f<id>/gated.txt answers 400: got 200
            FAIL  encoded path /x/..%5C<id>/gated.txt answers 400: got 404
            FAIL  encoded path /x/%2e%2e/<id>/gated.txt answers 400: got 200
            FAIL  encoded path /x/..%2F<live id>/ answers 400: got 404
            FAIL  the @encsep route precedes file_server in the adapted config
            noise: a serves again on its own port
```

### C: skip the Access app delete on rm

```
Mutation: line 575  elif access_delete "$app" "$1"; then  ->  elif true; then
Result:   RED, exit 1, 491 ok, 8 FAIL (4 access, 4 profiles noise):
            FAIL  rm gated: RELOAD precedes DELETE app
            FAIL  shim: rm deleted the app through the shim
            FAIL  shim: at least the add's five calls and rm's three reached the API
            FAIL  row 12b: the gated row and its bytes are gone, DELETE app logged
            noise: a's share answers on a's port, b's share answers on b's port,
                   a's hits counts a's fetches, b's share still answers
```

### Restored tree

```
Command: bash tests/share.sh (the unmutated worktree, run alone)
Result:  GREEN, 499 ok, 0 FAIL, exit 0, at 37a85d5, tree 444975f
Verdict: PASS (mutate -> RED -> restore) for A, B, C
```

## Live legs (Dwarves Cloudflare account, `tests/e2e.sh` with `SHARE_E2E_ACCESS_EMAIL`)

| Leg | Result |
|---|---|
| `share add --access` on a new hostname | link printed 37 to 38 s after start, three passing probe rounds included |
| inline allow policy on app create | accepted; the app read back intact |
| cleanup, checked from outside | the account holds only its four pre-existing Access apps; no share DNS record or tunnel remains |

The leg also asserts the rows 17 to 19 checks (redirect with `kid == aud` on the link variants, 400 on encoded separators, `--host` redirects, the app 404 after `rm`). The live run needed two e2e fixture fixes (20e1448, 4e33026); its per-check output was not kept in the repo, so rerun `tests/e2e.sh` before release and paste the result here.

The spike answers (empty-body probe 400 plus 12130, token verify, zone lookup, group paging, org and IdP reads) are in the notes' TASK-1 table.

## Row 30: clean-HOME walkthrough (live, Dwarves account)

A fresh `HOME`/`SHARE_CONFIG_DIR`/`SHARE_ROOT` under a mktemp dir, `share setup share-e2e.d.foundation --no-service` with the real `op://Toolkit/cf-api-token/credential` token as the stated precondition, then `CLOUDFLARE_API_TOKEN` unset and the README "Private links" steps run verbatim (`SHARE_TUNNEL=0` for the gated adds, permitted since Access enforcement is edge-side and does not need a live local tunnel). `op` and `security` were stubbed inside the mktemp `HOME` only: a mktemp `HOME` has no real 1Password session, and the real Keychain pops a GUI ACL prompt (`SecurityAgent`) on a first `add-generic-password` from a script context with no one to click it, confirmed by direct reproduction and killed by hand the first time. The stub `op` echoed the same real token (read once via Connect, passed through an env var, never a literal in the file); the stub `security` file-backed the round trip so the real Cloudflare calls still ran for real.

```
1. share setup share-e2e.d.foundation --no-service   exit 0
   tunnel: created share-share-e2e-d-foundation; dns: created CNAME; token: stored (stub keychain); live check passed
2. share add ./x --access email:tester@example.com   (no token source)   exit 1
   the O1 block: "none is set", the New-token and --cmd lines, the prefilled form URL
3. share api-token --cmd 'op read "op://Toolkit/cf-api-token/credential"'   exit 0
   ok  Zone: Read | ok  Access: Organizations, Identity Providers, and Groups Read | ok  Access: Apps and Policies Edit
4. share add ./report.pdf --access email:a@example.com,b@example.com   exit 0
   https://share-e2e.d.foundation/<id>/report.pdf
5. share add ./report.pdf --access group:dwarves-ops   exit 0
   https://share-e2e.d.foundation/<id>/report.pdf
6. curl (GET, headers only, --doh-url like access_probe_round) on both links: HTTP/2 302, both
   location: https://dwarves.cloudflareaccess.com/cdn-cgi/access/login/share-e2e.d.foundation?kid=...
7. share ls: both rows present, access= as set
8. share teardown --yes (real CLOUDFLARE_API_TOKEN)   exit 0
   both gated rows unpublished before the tunnel went; dns deleted; tunnel deleted; token removed
```

Verdict: PASS. Cleanup confirmed from outside: the account holds exactly its 4 pre-existing Access apps, no DNS record or tunnel for `share-e2e.d.foundation`, no stray Keychain item.

## Row 31: gauntlet round

One round, `kit:gauntlet`-shaped: a fresh-context subagent (no history, no other repo context) got only the task card text and its own `README.md`/`report.pdf` under a real, already-`share setup`-serving `share-e2e.d.foundation` (same real Dwarves account and token). It read only the README's Private Links section, never the script, never `--help` first.

Result: PASS on the first round. It ran `api-token --cmd`, both gated adds, `share ls`, and verified both links 302 to `*.cloudflareaccess.com` (it hit a local DNS-resolution quirk with plain `curl`, diagnosed it itself as environmental via `dig`, and retried with `--resolve`; not a README gap). The only friction it named was substituting the task card's real `op://Toolkit/...` ref for the README's placeholder `op://Private/...` example, which it called unambiguous. No stuck point, so no README fix and no second round were needed. Cleaned up the same way as row 30 (teardown, symlink and files restored); confirmed from outside: 4 pre-existing Access apps, no DNS record or tunnel left.

## Open before release

| Item | Owner |
|---|---|
| Row 21 UAT: a `group:dwarves-ops` link, a group address gets the PIN, a contractor address gets none | Han |
| Row 20 on a second zone (`SHARE_E2E_OTHER_HOST`) | by hand |
| `tests/e2e.sh` rerun with its output pasted above | by hand |
