# State groundwork: implementation notes

The delta from SPEC-010 for the builder. Validation ran two rounds on 2026-11-14. Round 1 folded 13 criticals (DEC-18 to DEC-29). Round 2 folded the regressions of those folds (DEC-30 to DEC-32) and raised two new criticals, which are held for a rescope decision below.

## Rescope proposal (not applied; owner decision)

Round 2 found two new edge-case criticals in the same areas round 1 hit. Per the rescope rule they are not folded.

| New critical | Proposal | Why |
|---|---|---|
| A dead `teardown` or `migrate` journal outlives a successful setup that the supersede table does not list (`setup --quick`, `setup --backend r2`), and the Share Bar then offers a destructive Resume | Replace the per-verb `op_supersedes_<verb>` table with one rule: a successful journaled verb on a profile removes every dead journal of that profile except dead `add` journals (bare `prune` owns those) | A per-verb table grows with every SPEC-009 verb and each gap is a destructive Resume; one rule has no table to keep in step |
| `ps -o lstart=` prints local time, so a terminal with `TZ=UTC` and the Share Bar under launchd disagree on a start time even with `LC_ALL=C`; a live op reads dead and runs twice, and `access_sweep` (L2366) can claim a live add's Access app | `proc_start` runs `LC_ALL=C TZ=UTC0 ps -o lstart=`, and one line in the spec says the start key is locale and zone free; pending lines written before the upgrade are accepted in the old format for one release | One environment pin closes both the locale and the zone case; the pending-line tolerance keeps an add that spans the upgrade from being swept |

Alternative to either: defer G9 (the `add` journal) and G12 to a later spec, which removes the `add` exceptions from both rules.

## Validation warnings carried to the build

| Warning | Build rule | Task |
|---|---|---|
| A rerun of teardown killed after the config is trashed dies at `need_host` | `op_begin` runs before `need_host`; a dead teardown journal with no config left counts as done | G2c |
| A stubbed 404 may hide a tunnel that still exists | GET the tunnel and skip the delete when `deleted_at` is set | G2c |
| Pending lines on disk from before the `LC_ALL=C` pin hold the old format | accept the unpinned format for one release (see the rescope proposal) | G2a |
| A `migrate` rerun after the remote `setup --token-stdin` cannot resume on the new machine (no stdin) | the remote journal's rerun names the local `share migrate` rerun, not the remote verb | G2c |
| Legacy `setup --backend r2` is in neither `admin_token_resolve` list; `--r2` and `--no-r2` have no `profile_migrated` guard | classify `--backend r2` as `required`; add `profile_migrated` to `--r2` and `--no-r2` | G3, G13 |
| `setup-r2` rollback `--no-r2` refuses after an alias fold (L4210 to L4214) | omit `rollback_argv` once the alias fold ran, or write the per-alias rollback | G2b |
| Journal readers have no rule for an unknown `v` | treat `v > 1` as `{verb:"?", alive:false}`, never fail | G2a |
| `.health` has no staleness bound | a `verified_at` older than 7 days reads `unchecked` | G10 |
| `admin-token --test` runs five probes per call | assert the call count in AT-06 from `r2-calls.log` | G13 |
| A rejected admin token has no code | map a 401 or 403 from the probe to `admin_token_not_admin` | G13 |
| `profile_migrated`'s next is `teardown --yes`, destructive for an agent | mark it not auto-runnable in the skill line | G5 |
| `SHARE_EXIT_FILE` is a path taken from the env | accept only `$root/.serve-exit` | G1b |
| `state-fn config-put` can write any key | allow it only under the test seam env | G4 |
| `gate_missing` needs a stored check result; no store is named | name it in `.health` or the index before LS-04 | G7 |
| `compat_state` has no edge row; `--help` listing of `admin-token` and `config` and the `share state --json` alias have no AC | add one row each | G10, G13, G14 |
| `op_interrupted` has no raiser | drop it from the first codes, or raise it from `op_begin` | G1 |
| CF-02 byte identity holds only for configs already in HEAD's key order; quick to named is order-sensitive | make CF-05 order-agnostic | G4 |
| Grounding has code cites and dry traces but no live sample | capture one `share state` JSON in the verification record | G1 |
| G2a carries many mechanisms; G2c wires four verbs | split again at build time if a session overflows; keep ids | G2a, G2c |
| The picture omits G12 | add it when G12 is scheduled | G12 |
