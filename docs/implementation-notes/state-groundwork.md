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

### Advisor critique (frozen diff) and what was folded

| # | Finding | Disposition |
|---|---|---|
| A1 major | tunnel `teardown` resolved `admin_token_cmd` at step 3, after the service stopped, so a failing command said "nothing was changed" with links down | folded: teardown resolves the admin token and refuses a missing gated-share token before `op_begin` and before anything stops |
| A2 minor | `admin-token --clear` on a profile with no config created an empty config, a ghost profile | folded: `--clear` with no config is a no-op |
| A3 minor | serve waits on the tunnel only; caddy dying under a live tunnel records nothing | open: the wait is pre-existing; a liveness poll on both children is G6's (`serve_state`, SS-09) |
| A4 minor | a refusal after `op_begin` reads as a dead op (B8) | partly folded: teardown's refusals moved before the journal (A1); `setup --r2` refusals at its read steps keep B8 |
| A5 minor | CD-07's curl stub answers `/ready`, so "keeps the reason" cannot see a removal at start | open: add a not-ready cloudflared fixture with a failing `/ready` |
| A6 minor | AT-09 cannot see an export behind `env -u`; no check fails without `lock_take config` or `lock_take ops` | open: add an `env` dump from the token command, and two concurrent writers per lock |

## Build delta: Phase 2 (G6, G7, G8, G9, G10, G14)

Decisions the spec left open, and changes from it, made while building Phase 2. Kept as a running list; the AC map and the advisor round follow at the end.

### Decisions

| # | Decision | Why |
|---|---|---|
| C1 | `serve_state` keeps HEAD's precedence: a running serve reads `serving` even on a `migrated` profile, and `not_setup` for a stopped one means "no hostname and not quick", not "role none" | the spec table says role first, but invariant 1 (every old `[state, ready]` value for every old input) is stronger: a config with only `hostname=` has role `none` and reads `stopped` today |
| C2 | the `starting` age is the pidfile's mtime, with `SHARE_STATE_NOW` as the clock seam | serve writes the pidfile once, at start; no extra file, and `stat -c` then `stat -f` covers GNU and BSD |
| C3 | `failed` also needs the service installed (spec) and `elsewhere` wins over it | `not_in_hosts` is itself a serve exit code; a machine outside `hosts=` must read `elsewhere`, not `failed` |
| C4 | the reasons `starting`, `elsewhere` and `not_setup` repeat the phase name and are not codes; only `ok`, `tunnel_down`, `worker_down` join the code table | the spec names those three; the skill explains the rest in prose |
| C5 | `list_rows` is a wrapper: `list_rows_raw` builds the rows, `link_apply` appends `link_state` and `reason` as fields 11 and 12 | every `return` inside the raw body still reaches the classification, and the three readers (`cmd_ls`, `state_lines`, the jq `row`) read one more pair of fields |
| C6 | `list_bucket` prints `#shadow <id>` lines for an id a cloud record also holds; `list_rows` strips them | the shadow set lives in the subshell that reads the bucket; a header line is the one channel it already uses (`#more`) |
| C7 | `gate_missing` reads a `gates` key of `.health` (`{at, missing}`), written by `access_ls_check` only when the check ran, and ignored when older than 7 days | closes the validation warning "no store is named"; a state poll never makes the Access call |
| C8 | `revoked` is in `link_state` now (opts `revoked`, reason `revoked_by=<by>`), ahead of `expired` | SPEC-009 TASK-0c waited on G7 for it; a revoked row answers 404 whatever its expiry |
| C9 | `ls` shows the state as a trailing `state=<s> (<why>)` on a row's second line, only when the row is not `live` | the first line stays the one a test or a script greps for the link |
| C10 | `access_pending` is deferred plus orphan, `access_inflight` intent plus bound, `access_bad` the hand-edited lines; `pending_count` keeps its no-argument and `live` forms for teardown's callers | CP-06 and the spec; teardown still counts every line |
| C11 | the `add` journal opens after the copy is staged: steps `pointer`, `publish`, `access`, `host`, `gate`, `row`; a handled gate failure calls `op_done` | a copy that fails leaves nothing to undo; an add that undid its own work must not read as a dead op |
| C12 | `add_sweep` decides by the row, not the step: a dead add with its row in the index just loses its journal; with no row its `pub/<id>` is trashed and its pointer dropped | a kill between `op_step 6` and the append, or after it, both resolve right |
| C13 | `state.token` is emitted only when the profile uses a token (bucket, r2 backend, or a source exists); `state.compat` only on a profile with a Worker | a plain tunnel profile with no token would otherwise read `missing` forever |
| C14 | `token_source` checks existence only (`api_token_cmd` or `r2_token_cmd` set, a Keychain item by `find-generic-password` without `-w`, the 600 file, an env token); the cache counts only for the same source and under 7 days old | a swapped token must not inherit the old one's `ok`; `state` never runs a command |
| C15 | `.health` writers: `r2_expiry_note` (the `api-token` paths) writes `token`; `cmd_status_r2` and `r2_wait_healthz` write `worker`; `access_ls_check` writes `gates`; teardown removes the file | one call site per fact that is already fetched; no new network call anywhere |
| C16 | `state.compat.worker` is the Worker's `<version> <sha>` pair as it reported it | SG-06's Share Bar decode reads it as a string |
| C17 | `share config` refuses with a plain `die` when the profile has no config file, and prints nothing for an unset key | `config_put` would otherwise create a config that makes a ghost profile |
| C18 | `compat_state` reads the `.health` cache only, also on an r2 profile whose `state` just probed `/healthz` | the cache tests (worker_older, worker_newer, cli_below_min) drive the cache directly; a probe override would shadow them. Open: use `hz_pair` when in hand (advisor minor) |
| C19 | a `token` verdict older than 7 days returns to `unchecked`, but the cached `expires_on` keeps counting for the same source | an expiry is a hard date: `expired` and `expiring` stay true when nobody reran `api-token` (advisor major, folded) |
| C20 | `min_cli` has no writer in this spec; the members work writes it, so `cli_below_min` is dead until then. The test hand-edits the file | the spec names the field and its reader only |
| C21 | the spec says `token` is written by `api-token`, `status`, `setup`, interactive `prune`; only `api-token` (via `r2_expiry_note`) writes it | those other paths make no token verify call today; a writer needs a call that already exists. The `worker` key is the one `status` and `setup` write |

### AC to test map: Phase 2 (tests/share.sh, `=== state groundwork: G6 ... G14 ===`)

| Task | AC rows | Test names (check labels start with the row id) |
|---|---|---|
| G6 | SS-01 to SS-12, `[state, ready]` equals HEAD's | `SS-nn ...` (one fixture per phase; HEAD's `bin/share` is captured with `git show`), `G6 state-fn serve prints the owner's four values` |
| G7 | LS-01 to LS-05, revoked, NC-G7 | `LS-nn ...`, `LS revoked ...`, `LS ls adds a state ...`, `negative control NC-G7 ...` |
| G8 | PS-01 to PS-04 | `PS-nn ...` (intent, bound, deferred, orphan, bad) |
| G9 | AD-01 to AD-05 | `AD-nn ...` (journal steps, overlap, dead add with and without a row, concurrent) |
| G10 | TK-01 to TK-06, state writes nothing | `TK-nn ...`, `TK state writes nothing with .health present / absent`, the negative control on `token_state` |
| G14 | CG-01 to CG-04 | `CG-nn ...` (ttl, storage_default, unknown key, unset, no value) |

### Advisor critique, Phase 2 (frozen diff)

| # | Finding | Disposition |
|---|---|---|
| P1 major | `state.token` decays to `unchecked` a week after `api-token`, and never reaches `expired` | folded (C19); three TK checks cover a week-old cache with a past and a near expiry |
| P2 minor | `compat` and `serve` can disagree on an r2 profile | open (C18) |
| P3 minor | `min_cli` has no writer | recorded (C20) |
| P4 minor | `add_sweep` consumes the journal before `r2_pointer_drop`; serve's hourly prune runs with `SHARE_API_TOKEN_OFF=1`, so the pointer drop may not happen | open: `r2_reconcile` finishes it on the next run with a token |
| P5 minor | a killed `health_put` leaves `.health.XXXXXX`, which blocks `rmdir` | folded: every teardown removes `.health.??????` too |
| P6 minor | one flaky Access GET clears a true `gate_missing` | open: `gates_put` records only a 404; a retry keeps the old list when a GET errors is a follow-up |
| P7 minor | a cloud row's `revoked_by=` is printed raw by `ls` | open: bucket opts are not sanitized like local rows |
