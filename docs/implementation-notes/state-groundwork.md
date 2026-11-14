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

## Build delta: Phase 1 (G1, G1b, G2a to G2c, G3, G4, G5, G13)

Decisions the spec left open, and changes from it, made while building Phase 1. Owner decisions D1, D2, D5, D7 (DEC-33 to DEC-36) are the spec's, not repeated here.

### Decisions

| # | Decision | Why |
|---|---|---|
| B1 | `code_text` reads one table string (`code|meaning|next`), not a bash `case` | `share state-fn codes` enumerates the same table; a `case` cannot be listed without parsing the script |
| B2 | `op_interrupted` is not added | it has no raiser (validation warning); a dead op is reported through `state.ops`, not a code |
| B3 | `op_step <n>` takes the step number only; the name comes from `op_steps_<verb>` | one list feeds the file, `status`, the progress line and the die-point loops; a second name argument could drift |
| B4 | `op_steps_<verb>` functions use `_` for `-` (`op_steps_setup_tunnel`) | portable function names |
| B5 | `admin_token_resolve` and `minter_token_resolve` set the variable without `export` | "for that process only" holds by construction; the `env -u` wraps on background spawns stay as the spec's belt and braces |
| B6 | `setup --backend r2` resolves the admin token in `optional` mode, not `required` | `required` would replace today's `r2_no_token` guidance block for a publisher with no token (die text byte-identical rule) |
| B7 | `setup <host> --token-stdin` (migrate's remote switch) writes no journal | its rerun needs stdin; the local `migrate` journal covers the switch step |
| B8 | the journal is written at `op_begin`, after the verb's pure argument checks, so a read-only refusal at a numbered step leaves a dead journal | the spec numbers read steps (setup-r2 1 to 7); a rerun or the rollback is harmless there, and the next success sweeps it |
| B9 | CD-01's HEAD capture runs the base commit's own `bin/share` (`git show`) beside the new one | a capture from HEAD, not a hand-typed expectation |
| B10 | `setup --r2` resolves the admin token and runs the `profile_migrated` guard before `op_begin`; `teardown --purge` resolves the token before its journal | AT-03 and AT-04 say "before any write"; a journal file is a write |
| B11 | `op_done`'s success sweep skips a journal file it cannot read (truncated, or an unknown `v`); only the next run of that file's own verb removes it | a file share cannot read may be a newer CLI's live journal |
| B12 | `start` waits up to 2 s for serve to drop a stale `.serve-exit` before it returns | serve removes it once it answers, about 1 s after `start` sees the pid; without the wait a later read-only check saw the root change |
| B13 | serve's EXIT trap makes `pkill -P` and `kill` non-fatal (`|| true`) | the trap runs under `set -e`; a `pkill` that found no child (the prune loop between two runs) ended the trap before caddy was killed. The die-point tests' 1 s prune loop exposed it; with the 3600 s loop the window is rare but real |
| B14 | hidden test seams: `SHARE_PRUNE_EVERY` (the prune loop interval) and `SHARE_PRUNE_DIE_CODE` (a bare `prune` dies with that code) | CD-05 needs a prune that dies while serve runs; serve's own startup prune (`quiet`) ignores the seam |
| B15 | `code_table`'s next column writes `{me}` for the profile's own command | the suite's hint lint refuses a bare `share <verb>` outside usage lines |
| B16 | the tenant rollback code's next is the rerun when an alias is folded, else `--no-r2` | `tenant_die` already names both; the code carries the runnable one |
| B17 | `CONTEXT.md` holds the terms that exist after Phase 1; `serve phase` and `link_state` land with G6 and G7 | a glossary line for a thing not built would mislead |
| B18 | `state-fn` gained `die`, `code` and `owner-live` beside the spec's verbs | CD-03, the unknown-code row and JN-15's pending-line half test the owners directly |

### Changes to existing tests

- `r2 backend: byte identity of existing installs`: the `state` and `profiles --json` normalization also drops `codes_v`, `role`, `tier`, `ops`, the additive keys of this spec. Every config, Caddyfile, index and plist artifact is still compared byte for byte.
- `row 15: --purge with no admin token` and `setup --token-stdin: without it an empty token is refused`: the refusal is now `admin_token_missing` ("... needs the admin token: set CLOUDFLARE_API_TOKEN, or store a command that prints it ..."), as G13 specifies.

### Findings outside this spec

- A `teardown --purge` of an r2 profile holding two cloud links dies at the second `rm` with `no share with id`; a rerun removes the next link. It reproduces on the base commit (84ebd9a), so it is not the journal's. The die-point loop for `teardown-purge` uses a one-link fixture. Follow-up: find why `cmd_rm_r2`'s second call loses its row from `r2_snap_file`.

### AC to test map (tests/share.sh, `=== state groundwork: <task> ===`)

| Task | AC rows | Test names (check labels start with the row id) |
|---|---|---|
| G1 | CD-01, CD-02 per migrated guard | `CD-01 <guard>: stderr and exit byte-identical to HEAD's`, `CD-02 <guard>: ...` for start, serve and service install outside `hosts=`, no tunnel token, port busy, metrics port busy, server not started, `setup --quick` on a named tunnel, serve while serving, and (G2b) setup `--r2` dying at the route |
| G1 | CD-03, unknown code, CD-06 | `CD-03 a message holding ...`, `an unknown code still dies ...`, `every die_code in bin/share names a code ...` (+ its negative control), `CD-06 ...` (two checks) |
| G1b | CD-04, CD-05, CD-07 | `CD-04 a read-only root ...`, `CD-05 ...` (+ negative control without the loop's unset), `stop records stopped ...`, `CD-07 ...` (four checks) |
| G2a | JN-01 to JN-07, JN-09, JN-12, JN-13, JN-15; state writes nothing | `JN-0n ...` checks; `negative control NC-G2 ...`; `state writes nothing with a live and a dead journal present` |
| G2b | die-point loops, JN-08, JN-11, DP-G-01, NC-G6 | `G2b die-point loop: setup-r2 ...`, `G2b die-point loop: --no-r2 ...`, `JN-08 ...` (three), `DP-G-01 ...` (three), `JN-11 ...`, `JN-01 on the wired verb ...`, `negative control NC-G6 ...` |
| G2c | die-point loops, JN-10, JN-14, TD-01, progress | `G2c die-point loop: setup <host> ...`, `... teardown ...`, `... teardown --purge ...`, `... migrate ... under /bin/bash 3.2`, `JN-10 ...`, `JN-14a ...`, `JN-14b ...`, `TD-01 ...` (two), `G2c SHARE_PROGRESS=1 setup ...` |
| G3 | RL-01 to RL-10, CP-01 (bash), NC-G3 | `RL-0n ...`, `RL-10 ...` (two), `CP-01 state_schema_ok passes on a migrated HOME ...`, `status names the moved profile`, `after migrate the old origin reads not_setup ...`, `negative control NC-G3 ...` |
| G4 | CF-01 to CF-08, NC-G4 | `CF-0n ...` (CF-02 once per writer: write_config, write_config_quick, tenant_config for --r2 and --no-r2, api-token --cmd, write_config_r2), `negative control NC-G4 ...`, `state-fn config-put writes only under its test seam` |
| G13 | AT-01 to AT-13, Q-SEC-7 grep, `--help` | `AT-nn ...` checks, `Q-SEC-7 no fixture token value in any captured output ...`, `--help lists admin-token and minter-token` |
| G5 | skill reads `share state`; every code has a line; NC-G5 | `skill names share state first`, `every code in share state-fn codes appears in the skill`, `negative control NC-G5 ...`, `skill lists every role` |
| CP-01 (swift) | decode with today's types | `mac/Tests/ShareBarCoreTests/GroundworkCompatTests.swift` (three cases) |
