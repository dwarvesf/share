# Spec: state groundwork (explicit state for share's implicit machines)
Generated: 2026-11-13
Status: VALIDATED
Lane: full
Depth: blind-spot (failure: a journal file left by a dead process, or by a pid the OS reused, makes every later run refuse with op_running, or a config rewrite reorders or duplicates a key that an older CLI reads by first match)
References: `docs/research/2026-11-13-implicit-state-machines.md` (the audit this spec builds: inventory rows 1 to 19, decisions D1 to D6 and D9, cross-cutting X1 to X5, groundwork G1 to G12; D7 and D8 ship inside SPEC-009); `docs/research/2026-11-13-current-state-machines.md` (the map the audit starts from); playdate-agent `hold-and-grant-machines.md` and `bridge-job-transitions.md` (imitate: named states, one owner, a transition table, one test per transition); `bin/share` `owner_live` (L2213, imitate: liveness is pid alive, a share process, the same start time) and the hidden test verbs `r2-rows`, `r2-id`, `worker-src` (L4821 to L4824, imitate for `state-fn`).
Blocks: SPEC-009 (`docs/specs/SPEC-009-multi-member.md`). Its Phase 1 starts only after G1 to G5 and G13 here have shipped (SPEC-009 TASK-1c calls `admin_token_resolve`; DEC-29).

## Problem

`share` already computes most states correctly; what is implicit is the output. Every reader (the human `status` text, the `state` JSON, the Share Bar's Swift, the agent skill) re-derives state from booleans and stderr text, so they disagree, and multi-step verbs that die leave half states that `state` reports as healthy. The audit found 19 machines; 6 can cause a wrong action today:

| # | What goes wrong (audit row) | Cite |
|---|---|---|
| 3 | After `migrate`, the config stays, so `state` says `stopped`, the Share Bar offers Start, and Start dies `no tunnel token` because migrate forgot the token | L1455, L932, L1195 |
| 4 | `setup --r2` writes the config at step 11 before the route at step 13; a die between leaves `state` reporting `r2: true`, and a later cloud add prints a URL the Worker never sees. The rollback line lives only in the dying terminal | L4152, L4166 to L4170, L3957 to L3960 |
| 19 | `write_config` keeps only `token_cmd`, `api_token_cmd` and four tenant keys; a `setup <host>` rerun drops a hand-set `ttl=`, `r2_token_cmd=`, `r2_key_id=`, and would drop SPEC-009's `members=on` with its refusals | L1677 to L1694 |
| 8 | Expired cloud rows stay in `state.shares` with Copy Link enabled; a gated row whose Access app vanished is public, and only an interactive `ls` with an env token hears it | L2885 to L2892, MM:L97 |
| 1 | `status` prints `not serving: share start` on a machine outside `hosts=`, where `start` then dies; a crash-looping service shows Stopped with the reason only in `serve.log` | L1445, L1380, L1391 |
| X4 | The agent skill tells agents to read `share status`, a human text verb that also prunes | L4766, L4791, L1437 |

SPEC-009 multiplies both problems (13 member statuses, a resume that guesses from file presence, new config keys). It needs a step journal, stable error codes and a key-keeping config writer before its Phase 1 can be written safely.

## Terms

Delta only; TASK G5 writes each line into the repo glossary `CONTEXT.md` (created on first use; SPEC-009 TASK-4c extends it).

- `role`: the one kind a profile is, from `profile_role`: `none`, `quick`, `origin`, `tenant_origin`, `r2_profile`, `migrated`, `member`.
- `tier`: an origin's tenant level: `t0` no bucket, `t1` bucket, `t2` bucket and members on (SPEC-009).
- `code`: a stable snake_case name for a refusal or a state reason, owned by `code_text`; versioned by `codes_v`, never by `schema`.
- `step journal`: one JSON file per running multi-step verb under `$root/ops/`, naming the verb, the step it reached and its rerun line.
- `op`: one entry of the journal as `state.ops` shows it: `{verb, step, of, name, alive, rerun, rerun_argv}`, plus the rollback pair when the verb has one.
- `serve phase`: the reasoned serving state (`not_setup`, `elsewhere`, `failed`, `stopped`, `starting`, `tunnel_down`, `worker_down`, `serving`) behind the old `state`/`ready` pair.
- `link_state`: a row's served state: `live`, `expired`, `shadowed`, `gate_missing` (SPEC-009 adds `revoked`, `paused`).
- `owned keys`: the config keys one writer may rewrite or drop; every other line is kept.

## Solution

### Approaches considered

| # | Approach | Main tradeoff |
|---|---|---|
| A | Fix each of the 19 machines where it lives (19 bespoke patches) | Smallest diffs, but the three copies of each classification (bash text, bash JSON, Swift) keep drifting, and SPEC-009 adds its machines with nothing to reuse |
| B | Five shared mechanisms (audit section 0): one owner function per machine, an additive `state` contract under schema 1, a step journal, stable codes, a key-keeping config writer | One design for every machine and every SPEC-009 verb; costs a new directory, a hidden test verb and a code list to keep in step with the skill |
| C | A `schema: 2` state document with a clean model | Cleanest JSON, but every shipped Share Bar renders "Update Share Bar" on `schema > 1` (SN:L166) and an old top-level schema hides every section (MM:L221) |

### Chosen approach + why

B. A leaves the drift in place; C breaks every installed Share Bar the day it ships. B changes no row, record, bucket key or wire format: `state` stays schema 1 and only gains keys, the `state.state` enum gains no value, die text stays byte-identical unless the caller opts in, and old CLIs ignore the new files (audit section 3).

### Extensibility & boundaries

- Load-bearing dimension: the number of multi-step verbs and codes. A new verb adds one `op_steps_<verb>` list and its `op_step` calls; a new refusal adds one `code_text` arm. SPEC-009 adds about a dozen verbs and twenty codes through exactly these two seams.
- Units, each testable alone through `share state-fn`:
  - `die_code` and `code_text` (codes, copy, next command, the JSON line);
  - the journal (`op_begin`, `op_step`, `op_done`, `ops_read`);
  - `profile_role` (role and tier from config and files);
  - `config_put` (rewrite owned keys, keep the rest);
  - `serve_state`, `link_state`, `pending_state`, `token_state`/`compat_state` (pure classifiers, should-rank).

### Architecture

See `## Design`.

## Picture

```
                        one owner per machine (bash, pure where possible)
                ┌───────────────────────────────────────────────────────────┐
 config, files  │ profile_role ── role, tier            (G3)                │
 pidfile, ports │ serve_state ─── serve{phase,reason}   (G6) ◄─ .serve-exit │
 index, bucket  │ link_state ──── rows[].link_state     (G7)                │
 access-pending │ pending_state ─ access_pending/_inflight/_bad (G8)        │
 .health cache  │ token_state, compat_state ─ token, compat (G10)           │
                └───────────────┬───────────────────────────────────────────┘
                                │ read only, no network, writes nothing
                                ▼
 share state ── {schema:1, state, ready, ... + role, tier, serve, ops,
                 codes_v, shares[].link_state ...}  (additive keys only)
     │                     │                              │
     ▼                     ▼                              ▼
 profiles --json      Share Bar (G11: new keys      agent skill (G5: reads
 (embeds it)          first, today's rules as        state and codes, never
                      the fallback)                  status text)

 multi-step verb ── op_begin ─► op_step n ─► ... ─► op_done      (G2, G9)
   setup, setup --r2,   │            │                 └► own file removed, plus every dead file of
   --no-r2, teardown,   │            │                    the profile except dead adds (prune's)
   --purge, migrate,    └── die ─────┴► file stays ──► state.ops[], status line, next run says
   add (G9)                                             "previous <verb> died at step n; continuing"

 admin path ── admin_token_resolve (G13): env, else admin_token_cmd; never into serve's env
 minter path ─ minter_token_resolve (G13): SHARE_MINTER_TOKEN, else minter_token_cmd
 share config ttl|storage_default (G14) ──► config_put

 any refusal ── die_code <code> <msg> [next]                       (G1)
                 ├► stderr "share: <msg>"          (byte-identical to die)
                 ├► SHARE_ERROR_JSON=1: stderr {"error":{code,message,next}}
                 └► SHARE_EXIT_FILE set: {"code":..,"at":..} to that file (serve -> .serve-exit)

 every config writer ── config_put "<owned keys>" k=v ...  (G4): owned keys rewritten in place,
                        every other line kept in file order, tmp + mv -f
```

## Design

Ordering: the public interfaces first (the `state` keys and the codes, which agents and the Share Bar depend on), then the on-disk shapes (journal, `.serve-exit`, `.health`), then the wiring into verbs.

### Approaches considered + chosen

See `## Solution`. The design view adds one tradeoff, recorded as DEC-6: the JSON error line is a second stderr line, so a reader that keeps the last stderr line (`list_cloud_error`, L2918) must skip it.

### Diagram

No new L1 or L2 element: every change is inside the `share CLI` component and its local files, so `docs/SYSTEM-DESIGN.md` rev B needs no new sheet. The audit's sections carry the per-machine state tables this spec builds:

| Audit section | Machine | Task |
|---|---|---|
| X2, X1 | codes and the JSON error line | G1 |
| D3 | step journal (rows 4, 5, 18) | G2a to G2c, G9 |
| D1 | role and tier (rows 3, 12) | G3 |
| D9 | config writer (row 19) | G4 |
| X4 | agent skill | G5 |
| D2 | serve phase (rows 1, 2) | G6 |
| D4 | link state (row 8) | G7 |
| D6 | access pending (row 6) | G8 |
| D5 | token and compat (rows 7, 9) | G10 |
| X5 | Share Bar mirrors display rules only | G11 |
| section 5, rows 11, 13, 14 | locks, checkmark, quick URL | G12 |

The diagram is `## Picture`. The serve phase table is copied here because the SS fixtures test it (audit D2). `serve_state` reads role, `running`, the `/ready` probe or r2 healthz, `svc_installed`, `host_ok` and `$root/.serve-exit`. First match wins:

| phase | condition | `state.state` | `ready` |
|---|---|---|---|
| `not_setup` | role `none` or `migrated` | `not_setup` | false |
| `worker_down` | role `r2_profile`, healthz not 200 | `serving` | false |
| `serving` | role `r2_profile`, healthz 200 | `serving` | true |
| `elsewhere` | set up, not running, `host_ok` false | `stopped` | false |
| `failed` | service installed, not running, `.serve-exit` holds a code other than `stopped` | `stopped` | false |
| `stopped` | set up, not running | `stopped` | false |
| `starting` | running, not ready, serve pid younger than 30 s (G6 adds a hidden clock seam for the SS fixtures) | `serving` | false |
| `tunnel_down` | running, not ready, older | `serving` | false |
| `serving` | running and ready | `serving` | true |

`reason` is the `.serve-exit` code for `failed`, else the phase name (`ok` for `serving`).

### ADR link(s)

No new ADR: every decision here is reversible (new keys can stop being written, the journal directory can be ignored) and none changes how the pieces fit. `docs/decisions/ADR-0003-menu-bar-reads-through-cli.md` already fixes the boundary this spec relies on: the Share Bar reads state only through the CLI. G13 amends ADR-0009 (the admin and minter token sources, DEC-15, DEC-35); the amendment lands with G13.

### Boundaries & failure modes

Out of bounds: no `schema` bump, no new `state.state` value, no change to `index.tsv`, bucket keys, records or the Worker (D7 rides SPEC-009's v5 bump), no network call from `state`, no change to die text when `SHARE_ERROR_JSON` is unset. Systemic failure classes: `## Failure modes`.

## Technical Design

### Interfaces (I/O contract)

Inputs / consumes: the config (`cfg`, L57), `index.tsv`, `index.migrated`, `serve.pid` (`running`, L84), the metrics `/ready` probe, `access-pending` (L2204), `quick.url`, the Keychain item names (existence only, never the secret, in `state`), the new `$root/ops/`, `$root/.serve-exit`, `$config_dir/.health`.

Outputs / produces: the additive `state` keys below; `die_code` stderr lines; journal files; `.serve-exit`; `.health`; the hidden verb `share state-fn`.

Invariants:
1. `share state` stays `schema: 1`; `state.state` stays one of `not_setup`, `stopped`, `serving`; every existing key keeps its type and value for every input it accepted before (SN:L166, MM:L38).
2. `share state` writes nothing and makes no network call beyond today's `/ready` probe and the stored-token bucket read (tests/share.sh L1025, L1036, L1081 keep passing).
3. With `SHARE_ERROR_JSON` unset, every die's stderr and exit status are byte-identical to today's.
4. A config line whose key a writer does not own survives that writer byte for byte, in file order.
5. A journal file exists only while its verb runs or after it died; a clean finish removes it.

### `die_code`, `code_text`, `SHARE_ERROR_JSON`, `SHARE_EXIT_FILE` (G1)

```
die_code <code> <message> [next]
  stderr: share: <message>                         # the same line die prints (L37)
  if SHARE_ERROR_JSON=1: stderr {"error":{"code":"<code>","message":"<message>","next":"<next>"}}   # jq -nc, one line, last
  if SHARE_EXIT_FILE set: write {"code":"<code>","at":<epoch>} to it (tmp + mv)
  exit 1
```

- `code_text <code>` is one bash `case`: it prints `<copy template>\t<next template>` and returns 1 for an unknown code. `die_code` with an unknown code still dies (a test catches it: G1 AC).
- The JSON line has no `share: ` prefix, so the Share Bar's last-`share:`-line rule (MO:L87 to L92) still picks the human line.
- `list_cloud_error` (L2918) keeps the last non-empty line of the subshell's stderr; it skips a line starting `{"error":` and stores its `code` in a new `state.cloud_error_code` (DEC-6).
- `state` gains `codes_v: 1`. The code list grows without a bump; a renamed or removed code bumps `codes_v`.
- `share state-fn codes` prints every code, one per line (the G5 skill check and SPEC-009's tests read it).
- First codes (the state-transition guards, G1's migration set): `not_in_hosts` (L1179, L1380), `already_serving` (L1180), `no_tunnel_token` (L1195), `port_busy` (L1199), `metrics_port_busy` (the next line), `server_not_started` (L1391), `profile_migrated` (G3), `op_running`, `op_interrupted` (G2), `quick_has_named_tunnel` (`cmd_setup_quick`, L1657), `tenant_rollback` (`tenant_die`, L3957 to L3960). Serve-reason codes added by G6: `ok`, `tunnel_down`, `worker_down`, `caddy_failed`, `cloudflared_died`, `stopped`. Token and compat codes added by G10. Key codes added by G13: `admin_token_missing`, `admin_token_cmd_failed`, `admin_token_not_admin`, `minter_token_missing`, `minter_token_cmd_failed`; `config_value_bad` by G4 (`config_put`'s newline guard; G14 reuses it) and `config_key_unknown` by G14. G1 reserves `members_present` in `code_text` (DEC-16); SPEC-009 TASK-1d raises it and adds the other member and join codes. The other die sites (`grep -c 'die ' bin/share` prints 388 lines) migrate as they are touched.

`SHARE_EXIT_FILE` scoping: `cmd_serve` sets `SHARE_EXIT_FILE=$root/.serve-exit` for its own shell only and unsets it in the hourly loop subshell before it runs `bash "$0" prune` (DEC-7); `cmd_stop` (L1422) writes `{"code":"stopped","at":<epoch>}`. Serve also records a child's death, which is not a die: when `wait` (L1242) returns, serve writes `cloudflared_died`, or `caddy_failed` when the caddy pid is gone, before it exits. Serve itself removes a stale `.serve-exit` (`rm -f`) once its own `/ready` probe answers, never at start and never from `state`; `cmd_stop` writes `stopped` only after the serve pid is gone, so serve's post-`wait` write cannot overwrite it. This holds so a crash loop under launchd (`ThrottleInterval` 30, L1298) keeps its reason (DEC-26).

### The step journal under `$root/ops/` (G2a to G2c, G9)

One file per running process, `$root/ops/<verb>.<pid>.json`, written tmp + `mv -f`:

```
{"v":1,"verb":"setup-r2","step":13,"of":16,"name":"route",
 "pid":4242,"start":"<proc_start pid>","started":1763000000,
 "rerun_argv":["--profile","p","setup","s.example.com","--r2","--bucket","b"],"id":null,
 "rollback_argv":["--profile","p","setup","s.example.com","--no-r2"],
 "rerun":"share --profile p setup s.example.com --r2 --bucket b",
 "rollback":"share --profile p setup s.example.com --no-r2"}
```

- `rerun_argv` and `rollback_argv` are the arguments after `share`, built with `jq -nc --args`; `--profile` is included when set. They are the contract. `rerun` and `rollback` are display strings derived from them with `printf %q` per argument, never parsed. A reader runs an argv only by exec of its own `share` path with no shell (DEC-21).
- Invariant: a journal file never holds a token, a secret or a single-use code. A verb whose input holds one (SPEC-009's `join <code>`) writes a rerun without it (bare `share join`).
- `op_begin <verb> [--concurrent] <rerun argv...> [-- <rollback argv...>]`: the rollback is optional and present only for verbs that have one (`setup-r2`: `--no-r2`; `join`: `leave --local`), so the Share Bar's Roll back button reads it instead of knowing each verb (gap G5, DEC-13). Calls `mk_root`, then `mkdir -p $root/ops` (mode 0700). Under `lock_take ops`, for each `<verb>.*.json` of the same verb: alive per `owner_live` (L2213) refuses with `die_code op_running` naming the pid and the verb; dead prints `previous <verb> died at step <n> (<name>); continuing`, sets `op_prev_step` and `op_prev_name` for the verb, and removes it (`rm -f`). Then it writes its own file at step 0 and releases the lock. "Continuing" means the verb runs from step 1 again; each step skips what is already in place.
- `id`: the share id for `add` (G9 needs it to roll back a dead add), `null` for every other verb.
- `--concurrent` (only `add`, G9): no `op_running` refusal and no touching of other pids' files; only bare `prune` consumes a dead `add` journal, under `lock_take ops`, re-checking that the file still exists. `op_done`'s success sweep never removes a dead `add` journal, and an `add` runs no sweep of its own (DEC-33).
- Locks are never nested: `ops` and `config` are each taken and released inside one helper (`lock_take`, L210, is not re-entrant).
- `SHARE_OP_PAUSE` release file: `$root/.op-release-<verb>-<n>`; `op_step` consumes it and gives up after 60 s.
- Every journal write is tmp + `mv -f` with the tmp named `.<verb>.<pid>.json.tmp`; readers glob `*.json` only, so a left tmp is never listed. A journal write that fails (disk full) is ignored: the journal is advisory and never blocks the verb.
- `op_step <n> <name>`: rewrites `step` and `name`. With `SHARE_PROGRESS=1` it also writes one unprefixed stderr line `{"progress":{"verb":"<verb>","step":<n>,"of":<of>,"name":"<name>"}}` (built with `jq -nc`), which the Share Bar reads to show "step n of m" for a command it started, without polling `state` (DEC-14). The line never starts `share: `, so MO:L87's last-line rule ignores it. With `SHARE_OP_PAUSE=<verb>:<n>` (the hidden test seam), `op_step` writes the file at step n, then waits for a release file in `$root` before it returns; the die-point loops kill there. This reaches every step of every verb, local writes included, and closes OQ-2 (DEC-25).
- `op_done`: removes its own file (`rm -f`, never `to_trash`: the journal is transient bookkeeping, like the pidfile; DEC-24). On success it also removes, under `lock_take ops`, every dead journal file of the profile (`owner_live` false), whatever its verb, except dead `add` journals, which only bare `prune` consumes (G9). A live file of another process is never touched. One rule, no per-verb list: a successful Roll back clears the interrupted op, a successful setup after a dead teardown leaves `ops/` empty, and SPEC-009's verbs (`leave` after a dead `join`) need no entry (DEC-20, DEC-33). A die leaves the file (no EXIT-trap removal). So does SIGTERM, the Share Bar's Stop: the verb's existing traps still release its locks, the journal file stays at the step it reached, and the next run of the verb continues from it (gap G5, DEC-13).
- `op_steps_<verb>` prints `n name` lines, once per verb; `of` and the `status` line and the die-point tests read the same list.
- `ops_read` (used by `state` and `status`, read only) lists every file with `alive` from `owner_live`.
- Liveness across processes needs one start-time format: `proc_start` (L2175) pins `LC_ALL=C TZ=UTC0` on its `ps -o lstart=`, so a journal written from a terminal with a French or German locale, or in another time zone, reads alive to the Share Bar, which runs with no `LANG` and launchd's zone (DEC-23, DEC-34).
- For one release, `owner_live` also accepts the old unpinned format: when a stored `start` does not equal the pinned value, it compares it with `ps -o lstart=` read in the caller's own environment, so a pending line or journal written by a pre-upgrade CLI from the same environment still reads alive. The fallback goes in the release after next (DEC-34).
- Teardown and migrate converge on rerun: their tunnel, connections and DNS deletes treat a 404 as already done (`cf_try` and a status check, not `cf`, which dies on any non-success, L1506).
- Verbs and their lists: `setup-tunnel` (`cmd_setup`, L4400), `setup-r2` (`cmd_setup_tenant`, steps 1 to 16 exactly as its comments number them, L3980 to L4193), `no-r2` (`cmd_setup_no_r2`, L4201), `teardown` (L4557), `teardown-purge` (`cmd_teardown_r2 --purge`, L4641), `migrate` (L938), and with G9 `add` (L465). SPEC-009 adds `join`, `setup-members`, `no-members` and every admin member verb. The Share Bar's Add a tenant and tier buttons run exactly these journals: Set up a hostname is `setup-tunnel`, Join a team is `join`, Turn on cloud storage is `setup-r2`, Turn on members is `setup-members` (gaps G2, G7, G8, DEC-12).
- `status` prints, for a dead op: `<verb> stopped at step <n> of <of> (<name>); rerun: <rerun>`, plus the verb's rollback when it has one (`setup-r2`: `or roll back: share setup <host> --no-r2`, the line `tenant_die` prints today).

### `profile_role` (G3)

Called once at load right after L79, sets `role` and `tier`; every site that asks "what kind of profile" reads `$role` instead of `r2on`/`backend`/`mode` as it is touched (the 28 `r2on` sites stay as they are until SPEC-009 TASK-1g; DEC-4). First match wins:

| role | detector | `state.state` |
|---|---|---|
| `member` | config `role=member` and `member_id` present (SPEC-009 writes them) | as today |
| `migrated` | config `migrated=<target>` set; or, for a profile migrated before G3 shipped, `index.migrated` exists, `tunnel_id` set, no `token_cmd` key, and no tunnel token is stored (Keychain item or 600 file exists check only; never the secret, never `token_cmd`) | `not_setup` (was `stopped`) |
| `r2_profile` | `backend=r2` | `serving` (as today) |
| `quick` | `mode=quick` | as today |
| `tenant_origin` | `tunnel_id` and `bucket` | as today |
| `origin` | `tunnel_id` | as today |
| `none` | else | `not_setup` |

The `migrated` marker is explicit (DEC-19): `migrate_retire` (L897) writes `migrated=<target>` through `config_put`, and `setup <host>`, `setup --r2` and `setup --quick` own the key and drop it. So a later setup on this machine, or a `token_cmd` origin with an old `index.migrated`, never reads `migrated`. The token-absence rule is only the fallback for profiles that moved before G3. `index.migrated` is never renamed or removed.

Tier (origin roles only): `t0` no bucket, `t1` bucket, `t2` bucket and (config `members=on` or marker `members:true`). The marker half is SPEC-009 TASK-1d's; here `t2` reads the config key only.

`profile_role` runs again at the end of every `config_put`, so `setup <host>` on a migrated profile, which drops `migrated=` and then calls `cmd_start` (L4550) and `svc_install` (L4546), passes the guard (DEC-32). Guards: `start`, `serve`, `service install` and `add` on `migrated` refuse before any write with `die_code profile_migrated "this profile moved to <target> (rows in index.migrated); nothing serves here" "share --profile <p> teardown --yes"`. `<target>` is `cfg migrated`, else omitted (a profile moved before G3). Control characters are stripped from it before it reaches a message. `status` prints `role: tenant origin (R2 on)` and, for `migrated`, `moved to another machine`.

Why `not_setup`: shipped Share Bars render it neutral with a Set Up item (MM:L34, MM:L184); `stopped` sends them to a Start that dies.

### `config_put` (G4)

```
config_put "<owned key list>" key=value ...
  any given value holding \n or \r -> die_code config_value_bad before any write   (it would inject a line that cfg, and token_read's eval, L295, read)
  a given key not in the owned list -> die (a caller bug)
  mk_root; lock_take config   (a Share Bar `config ttl` cannot race setup's step 11; mk_root first, or the lock spins on a fresh HOME)
  tmp = mktemp in $config_dir, chmod to the config's current mode (0644 when new)
  for each line of the current config, in order:
    key owned and given      -> write key=<new value> at the first occurrence; drop later duplicates of that key
    key owned and not given  -> drop the line
    anything else            -> keep the line byte for byte (blank lines and comments too)
  append each given owned key not yet written, in the given order
  mv -f tmp config; lock_release config
  profile_role   (recompute role and tier, so a guard later in the same process reads the new config)
```

The newline guard is today's `api-token --cmd` check (L2447) moved into `config_put`, so every writer has it (DEC-18).

Writers and their owned sets (each set = the keys it writes today plus the keys it drops today, so a config holding only known keys comes out byte-identical to HEAD's writer):

| Writer | Owned keys |
|---|---|
| `write_config` (L1677) | `hostname tunnel_id tunnel_name auth hosts port zone mode migrated` (drops `mode` when a quick profile turns named) |
| `write_config_r2` (L3817) | `backend hostname zone bucket port r2_endpoint aliases tunnel_id tunnel_name auth hosts mode migrated` (it never writes a tunnel key today) |
| `write_config_quick` (L1645) | `mode hosts port hostname tunnel_id tunnel_name auth zone migrated` |
| `migrate_retire` (L897) | `migrated` (G3) |
| `tenant_config` (L3867) | `bucket r2_endpoint storage_default aliases migrated` |
| `api-token --cmd` (L2454) | `api_token_cmd` |
| `admin-token --cmd`, `--clear` (G13) | `admin_token_cmd` |
| `minter-token --cmd`, `--clear` (G13) | `minter_token_cmd` |
| `config <key> <value>`, `config <key> --unset` (G14) | the one key named |

Keys today's writers keep by name (`token_cmd`, `api_token_cmd`, `r2_token_cmd`) need no special case: they are simply not owned. bash 3.2: the owned list is a space-joined string matched with `case " $owned " in *" $key "*)`; no associative arrays, no empty arrays.

### The admin and minter key commands (G13)

Gap G3 of `docs/design/share-bar-interactions.md`: the Share Bar runs admin verbs, but today the admin token lives only in `CLOUDFLARE_API_TOKEN`, which an app started by launchd never has (DEC-15, ADR-0009).

- Config key `admin_token_cmd`: a command whose stdout is the admin token (for example `op read op://<vault>/<item>/credential`), never the token itself; the same pattern as `api_token_cmd`. Unset means "ask each time": the Share Bar asks for the token per action, passes it to that one child as `CLOUDFLARE_API_TOKEN`, and never stores it.
- `admin_token_resolve`: `CLOUDFLARE_API_TOKEN` when set (it wins, and the command never runs); else run `admin_token_cmd` once per process, take the first line of stdout, require a token charset (letters, digits, `_`, `-`), and export the result as `CLOUDFLARE_API_TOKEN` for that process only; a non-zero exit dies `admin_token_cmd_failed` naming the exit status, never the command's output; neither dies `admin_token_missing` with the next step `share admin-token --cmd '<command>'`, but only on a path that needs it. Two modes (DEC-27):
  - `required` (dies `admin_token_missing` with neither source): `setup --r2`, `--no-r2`, `teardown --purge`; SPEC-009 adds `--members`, `--no-members`, `member` and an admin's `rm` of another member's link. G13 wires the three that exist now.
  - `optional` (resolves only when `admin_token_cmd` is set, else today's path, the env token or the browser-login cert, L4472 to L4478, L4621 to L4625): `setup <host>`, tunnel `teardown`, `migrate`. `setup --quick` never resolves.
- The resolved token never reaches a long-lived child: when the source is `cmd`, `cmd_start`'s `nohup bash "$0" serve` (L1389), and every other background spawn, run under `env -u CLOUDFLARE_API_TOKEN`, so the serve daemon, caddy and cloudflared do not inherit it after `setup` starts serving (L4550). An env-sourced token keeps today's behavior (DEC-28). With a `cmd` source, serve's expiry cleanup of `--host` DNS records (the L1389 comment) falls back to the login cert, as it does today with no env token.
- It is never called by `ls`, `add`, `refresh`, own `rm`, `prune`, `state`, `status` or `profiles`, so a listing never runs `op read` (the rule at L709) and a publisher path never sees an admin token (`r2_publisher_check`, L2521, still refuses one).
- `share admin-token --cmd '<command>'` and `--clear` write or drop the key through `config_put`. `share admin-token --test [--json]` resolves the token and probes what it can do (tunnels, DNS, Workers scripts, R2, Connectivity Directory: one read call each), prints one line per capability, and never prints the token or the command's output; `--json` prints `{"source":"env|cmd","can":{"tunnels":true,...}}`. A token that fails the Workers settings probe dies `admin_token_not_admin`.
- Config key `minter_token_cmd` (DEC-35): a command whose stdout is the minter token (API Tokens Read and Write, SPEC-009's `minter token`), on the same rule as `admin_token_cmd`. `minter_token_resolve`: `SHARE_MINTER_TOKEN` when set (it wins, and the command never runs); else run `minter_token_cmd` once per process, first line, the same charset check, exported as `SHARE_MINTER_TOKEN` for that process only, never stored; a non-zero exit dies `minter_token_cmd_failed` naming the exit status, never the output; neither dies `minter_token_missing` with the next step `share minter-token --cmd '<command>'`. It runs only on minter paths: SPEC-009's `member add`, `invite`, `rotate`, `renew`, `rm` and `adopt` (TASK-1c1 calls it); G13 lands the resolver and the verb. Background spawns run under `env -u SHARE_MINTER_TOKEN` as they do for the admin token.
- `share minter-token --cmd '<command>'` and `--clear` write or drop `minter_token_cmd` through `config_put`. `share minter-token --test [--json]` resolves the token and makes one read call, `GET /user/tokens`, printing whether it can list tokens and never the token or the command's output; `--json` prints `{"source":"env|cmd","can":{"list_tokens":true}}`.

### `share config` (G14)

The Share Bar's General tab writes two CLI defaults (interactions doc section 7): `share config ttl <duration>` (validated as `add --ttl` validates it) and `share config storage_default local|cloud` (refused with `config_value_bad` on a profile with no bucket); `share config <key>` prints the value; `share config <key> --unset` drops it; any other key dies `config_key_unknown`. Writes go through `config_put` with the one key owned. No other key is settable this way: the token commands keep their own verbs (DEC-17).

### `share state` additions under schema 1

| Key | Shape | Task | Absent means |
|---|---|---|---|
| `codes_v` | `1` | G1 | an older CLI |
| `cloud_error_code` | code string, beside `cloud_error` | G1 | no code |
| `role`, `tier` | strings from `profile_role`; `tier` only on origin roles | G3 | derive as today |
| `ops` | `[{verb, step, of, name, alive, rerun, rerun_argv, rollback?, rollback_argv?}]`, `[]` when none | G2a | an older CLI |
| `serve` | `{phase, reason}` | G6 | derive from `state`/`ready` |
| `shares[].link_state`, `.reason` | `live`, `expired`, `shadowed`, `gate_missing` | G7 | compare `expires` as today |
| `access_inflight`, `access_bad` | integers; `access_pending` becomes deferred + orphan | G8 | today's count |
| `token`, `compat` | `{source, status, expires_on}`, `{cli, worker, status, min_cli}` | G10 | unknown |
| `locks` | `[{name, pid, age, alive}]` | G12 | unknown |

`profiles --json` embeds each `state` unchanged (L1605). `share state --json` already works (the dispatcher ignores the argument, L4828) and is documented as an accepted alias.

### Data model changes

New local files only: `$root/ops/<verb>.<pid>.json`, `$root/.serve-exit`, `$config_dir/.health` (G10, 0600, no secret: `{token:{source, verified_at, expires_on, verify}, worker:{pair, deploy, at}, min_cli}`). Each `.health` writer updates only its own top-level key with `jq`, tmp + `mv -f`, so SPEC-009's `member` block survives a token write. Every teardown removes `.health` (`rm -f`) before its `rmdir "$config_dir"` (L4569, L4638, L4660), or the profile dir stays and `profiles --json` (L1621) lists a ghost profile (DEC-24). Three new config keys: `migrated` (G3), written by `migrate_retire`, and `admin_token_cmd` and `minter_token_cmd` (G13), each a command and never a secret. No row, record or bucket key changes shape.

### API changes

None on the wire. The hidden verb `share state-fn role|serve|link|pending|ops|op-run|codes|config-put <args>` exposes each owner for the suite (X5; SPEC-009 adds `member-can`); it is unlisted in `--help`, as `r2-rows` and `worker-src` are. Three public verbs, listed in `--help`: `share admin-token --cmd|--clear|--test [--json]` and `share minter-token --cmd|--clear|--test [--json]` (G13), and `share config <key> [<value>|--unset]` (G14). One opt-in stderr line, `SHARE_PROGRESS=1`'s progress line (G2a).

### UI changes

`status`: the `role:` line, the dead-op line, the `elsewhere` copy `not serving here: this machine is not in hosts=<list>; links work while a machine in hosts= serves` (G6), the access note only for deferred and orphan lines (G8). Share Bar (G11): new keys first, today's derivation as the fallback; no layout change here (the revision 8 redesign is SPEC-009 TASK-4b1 to TASK-4b23, which reuses G11's types and runs G13's and G14's verbs).

### Infrastructure changes

None.

## Task Breakdown

Each task lands with its tests in `tests/share.sh` (sections named `=== state groundwork: <task> ===`) or `mac/Tests/ShareBarCoreTests`. Phase 1 is the must set and ships before SPEC-009 Phase 1.

### Phase 1: must (ship before SPEC-009 Phase 1)

- [ ] G1: codes. `die_code`, `code_text`, `SHARE_ERROR_JSON`, `codes_v`, `cloud_error_code`, `state-fn codes`; migrate the state-transition guards listed in `### die_code` to `die_code`. AC: every existing die-text grep in `tests/share.sh` passes unchanged; with `SHARE_ERROR_JSON=1` each migrated guard's last stderr line parses with `jq -e .error.code` and equals its code (CD-02, CD-03); with the env unset stderr is byte-identical to a capture from HEAD for each migrated guard (CD-01); an unknown code dies with exit 1 and a suite check fails; `cloud_error` stays the human text when the subshell's last line is JSON (CD-06). Every task below that adds a code adds its skill line in the same task.
- [ ] G1b (after G1): the serve exit record. `SHARE_EXIT_FILE` with the serve scoping, `stop`'s record, serve's child-death write after `wait`, and removal of a stale `.serve-exit` only once `/ready` answers (DEC-26). AC: CD-04, CD-05, CD-07.
- [ ] G2a (after G1): journal core. `op_begin`, `op_step`, `op_done`, `ops_read`, `op_steps_<verb>` for the verbs below, `state.ops`, the `status` dead-op line, `state-fn ops`; the optional `rollback` field; the `SHARE_PROGRESS=1` progress line; SIGTERM leaves the file (gap G5, DEC-13, DEC-14); `rerun_argv`/`rollback_argv`, `--concurrent`, `op_done`'s success sweep of dead journals (DEC-33), `op_prev_step`, the `ops` lock, `SHARE_OP_PAUSE`, `proc_start`'s `LC_ALL=C TZ=UTC0` and `owner_live`'s one-release fallback to the unpinned format (DEC-34). the hidden driver `share state-fn op-run <verb> <n>` (op_begin, n op_steps, op_done, honoring `SHARE_OP_PAUSE`) so the core is tested before any verb is wired. AC: JN-01 to JN-07, JN-09, JN-12, JN-13, JN-15, each through `state-fn op-run`; `state` writes nothing with a live and a dead journal file present.
- [ ] G2b (after G2a): wire `setup-r2` and `no-r2`. `op_step` at each numbered step of `cmd_setup_tenant` and at each write of `cmd_setup_no_r2`; `tenant_die`'s rollback line reprinted by `status` from the journal. AC: the die-point loop (kill at each `op_step` through `SHARE_OP_PAUSE`, rerun, assert the happy end state and an empty `ops/`) for every step of both verbs; JN-08; JN-11 on `setup-r2` then `--no-r2`; DP-G-01.
- [ ] G2c (after G2a): wire `setup-tunnel`, `teardown`, `teardown-purge`, `migrate`; their remote deletes treat a 404 as done; must-fix: `migrate` expands `mids` as `${mids[@]+"${mids[@]}"}` (L899 to L903, L1081), since a rerun after `migrate_retire` rewrote the index has no ids and `/bin/bash` 3.2 aborts on the empty array under `set -u`. `setup-tunnel` is what the Share Bar's Set up a hostname runs, so its `op_steps` names are the steps the add sheet shows (gaps G2, G8, DEC-12). AC: the same die-point loop through `SHARE_OP_PAUSE` on every step of the four verbs, none left to the notes, the `migrate` loop run under `/bin/bash` 3.2; JN-10; JN-14; TD-01; `SHARE_PROGRESS=1 share setup s.example.test` in the dry seam prints one progress line per `op_steps_setup-tunnel` row, in order, with `of` equal to the row count.
- [ ] G3 (after G1, G4): role. `profile_role`, `role` and `tier` in `state`, `status`'s role line, the `migrated` guards with `profile_migrated`. `migrate_retire` writes `migrated=<target>`. AC: RL-01 to RL-10; `state_schema_ok` (tests/share.sh L1000) passes on a migrated HOME with `state` `not_setup`.
- [ ] G4 (after G1): `config_put` replacing the four whitelist writers and the `api-token --cmd` write. The newline guard, the `config` lock and the kept file mode. AC: CF-01 to CF-08; the `r2 backend: byte identity of existing installs` section (tests/share.sh L1849) passes unchanged.
- [ ] G5 (after G1, G3): the skill reads `share state`. `cmd_skill` (L4748): "Before anything" runs `share state`; the text lists every `role` and code value that exists when G5 ships, with one line of meaning each; G6, G7 and G10 add their `serve.phase`, `link_state` and token lines with their own keys; `status` stays the human view. AC: the `=== skill ===` section (tests/share.sh L1748) gains `skill names share state first` and `every code in share state-fn codes appears in the skill`; the check fails when a code is added to `code_text` without a skill line (negative control NC-G5).
- [ ] G13 (after G1, G4): admin and minter key commands (gap G3, DEC-15, DEC-35). `admin_token_cmd`, `admin_token_resolve` in its `required` and `optional` modes at the paths of `### The admin and minter key commands (G13)` that exist today, `env -u CLOUDFLARE_API_TOKEN` on background spawns, `share admin-token --cmd|--clear|--test [--json]`; `minter_token_cmd`, `minter_token_resolve`, `env -u SHARE_MINTER_TOKEN` on background spawns, `share minter-token --cmd|--clear|--test [--json]`; the five codes; the ADR-0009 amendment. AC: AT-01 to AT-13; the existing `api_token_cmd` and listing rows of tests/share.sh pass unchanged; a grep of the dry `r2-calls.log` and every captured stdout and stderr finds no fixture token value (Q-SEC-7).

### Phase 2: should

- [ ] G6 (after G1, G1b, G3): `serve_state`, `serve {phase, reason}`, `.serve-exit` read; `cmd_status`, `cmd_state`, `cmd_state_r2` all call it; `elsewhere` copy fix. AC: SS-01 to SS-09; for each phase fixture `jq '[.state,.ready]'` equals HEAD's output.
- [ ] G7: `link_state` inside `list_rows` (L2897) for `live`, `expired`, `shadowed`, `gate_missing`; `ls` adds a STATE column only when a row is not `live`. AC: LS-01 to LS-05; every old row field equals HEAD's output.
- [ ] G8: `pending_state <line>`; `pending_count` takes a state list; `access_pending` = deferred + orphan; `access_inflight`, `access_bad`; `ls`/`status` note only for deferred and orphan. AC: PS-01 to PS-04.
- [ ] G9 (after G2a): the `add` journal, and bare `prune` finishing or rolling back a dead add (step before the row append: trash `pub/<id>` with no row, drop its own pointer through `r2_pointer_drop`, leave Access lines to the sweep). `add` uses `op_begin --concurrent`. AC: AD-01 to AD-04; the Share Bar's Stop Waiting copy (MO:L111) is G11's.
- [ ] G10: `.health` cache, `token_state`, `compat_state`, `state.token`, `state.compat`; written by `api-token`, `status`, `setup`, interactive `prune`; `state` reads it only; per-key `jq` updates; teardown removes it. AC: TK-01 to TK-06; the three `writes nothing` checks stay green with `.health` present and absent.
- [ ] G14 (after G1, G4): `share config` for `ttl` and `storage_default` (interactions doc section 7, DEC-17). AC: CG-01 to CG-04.
- [ ] G11a (after G3, G6, G10): Share Bar decodes `role`, `tier`, `serve`, `ops`, `link_state`, `token`, `compat` as optional keys, and derives health from them inside today's `NSMenu`: health copy from `serve.phase`, `migrated` reads `Moved to another machine`; an unknown value of any new key falls back to today's derivation. AC: SB-01 to SB-03; `StateMappingTests` unchanged on the old fixtures.
- [ ] G11b (after G11a, G2a, G7): Copy Link disabled on `expired`; an alive op shows `Working: <verb> (<step>/<of>)`, a dead one an attention line with the `rerun` display string (copy only; the menu never runs it). AC: SB-04, SB-05.
- [ ] G11c (after G1, G9): mutations set `SHARE_ERROR_JSON=1` and show the JSON line's message and `next`, else today's last `share: ` line; Stop Waiting copy `The add stops where it is; share prune cleans up what it left.` AC: SB-06, SB-07; `bash mac/build.sh 0.0.0`.

### Phase 3: later

G12 stays in Phase 3 and is outside the current mega-goal, which ends with Phase 2 (DEC-36).

- [ ] G12: `locks[]` in `state` (holder pid, age, alive); the copy checkmark timer owned by `MenuModel` so a poll cannot cut it short (SIC:L846 to L858); quick-URL `phase` (`none`, `pending`, `live`). AC: LK-G-01 to LK-G-03.

Task count: Phase 1: 9 (G1, G1b, G2a, G2b, G2c, G3, G4, G5, G13); Phase 2: 9 (G6 to G10, G14, G11a, G11b, G11c); Phase 3: 1 (G12); 19 in all. G13 is in Phase 1 because SPEC-009 TASK-1c calls `admin_token_resolve`; G14 sits in Phase 2 because only SPEC-009's Share Bar tasks need it; both keep their numbers after G12 so no earlier id moves. G2 is split in three because its wiring spans six verbs and one session per two verbs is the atomic size; G11 in three because its six behaviors span more than five Swift files (DEC-29); G1 in two because the serve exit record is its own concern (DEC-30). A task with no `(after ...)` depends on nothing in this spec.

## After state

- [ ] `SHARE_ERROR_JSON=1 share start` on a machine outside `hosts=` ends stderr with `{"error":{"code":"not_in_hosts",...}}`; without the env the output is unchanged. (Today: text only.)
- [ ] A `setup s.example.test --r2 --bucket b` killed at step 13 leaves `$root/ops/setup-r2.<pid>.json`; `share status` prints `setup-r2 stopped at step 13 of 16 (route); rerun: ...; or roll back: share setup s.example.test --no-r2`; `share state` lists it in `ops`; the rerun prints `previous setup-r2 died at step 13 (route); continuing` and ends with an empty `ops/`. (Today: the rollback line is in the dead terminal only.)
- [ ] After `migrate`, `share state` on the old origin reads `state: not_setup`, `role: migrated`, and `share start` refuses with `profile_migrated`. (Today: `stopped`, and Start dies `no tunnel token`.)
- [ ] A config holding `ttl=7d`, `r2_token_cmd=x`, `x_future=1` keeps all three lines byte for byte across `share setup <host>`. (Today: all three are dropped, L1677 to L1694.)
- [ ] `share skill` tells agents to run `share state` first and names every code `share state-fn codes` prints. (Today: `share status`, L4766.)
- [ ] The shipped v0.9.0 Share Bar decodes every new `state` with no profile reading "Update Share Bar" or "Error: state not readable" (CP-01).

## Quality requirements

`docs/QUALITY.md` does not exist yet; SPEC-009 TASK-4c creates it, and this spec's entries land in the same file.

- Q-COMPAT-4 (new): `share state` stays schema 1, gains keys only, and keeps every existing key's value. Tested by: CP-01 to CP-03, `state_schema_ok`.
- Q-REL-5 (new): every journaled verb converges after a kill at any step and leaves `ops/` empty. Tested by: the G2b and G2c die-point loops.
- Q-REL-6 (new): no config writer drops a key it does not own. Tested by: CF-01 to CF-04.
- Q-AX-1 (new): every refusal a guard raises has a stable code and a next command an agent can run. Tested by: G1 AC, G5 AC.
- Q-SEC-7 (new): the admin and minter tokens are never stored by share and never reach an argv, a file or output; `admin_token_cmd` runs only on admin paths and `minter_token_cmd` only on minter paths. Tested by: AT-02, AT-03, AT-05, AT-06, AT-09 to AT-12, the G13 grep.

## Acceptance Criteria (global)

- [ ] All 19 tasks pass their individual acceptance criteria; Phase 1 (G1, G1b, G2a to G2c, G3 to G5, G13) merged before any SPEC-009 Phase 1 task.
- [ ] Every row of `## Compatibility` has its one test, green.
- [ ] Every edge case below has a named passing test.
- [ ] No regression: every existing `tests/share.sh`, `tests/worker.mjs` and `swift test` row passes unchanged.
- [ ] The shipped Share Bar keeps working against the new CLI (CP-01).

## Verification

```sh
shellcheck bin/share install.sh tests/share.sh tests/e2e.sh tests/e2e-r2.sh tests/e2e-tenant.sh demo/render.sh mac/*.sh
/bin/bash -n bin/share          # macOS bash 3.2 parse (CLAUDE.md)
bash tests/share.sh             # every section, including the new `=== state groundwork: ... ===` sections; it runs node tests/worker.mjs too
swift test --package-path mac   # G11 rows and the CP-01 decode row
bash mac/build.sh 0.0.0
```

CI runs `bash tests/share.sh` on Linux and macOS and `swift test` on macOS (`.github/workflows/ci.yml`). Run the suite once with `PATH` restricted so `/bin/bash` 3.2 runs `bin/share`, as the suite already does for its compat sections.

## Edge Cases

Test file `tests/share.sh` unless marked `swift`.

### Codes (G1)

| # | Scenario | Expected |
|---|---|---|
| CD-01 | a migrated guard with `SHARE_ERROR_JSON` unset | stderr byte-identical to HEAD's capture; exit 1 |
| CD-02 | the same with `SHARE_ERROR_JSON=1` | the human line, then one JSON line, last; exit 1 |
| CD-03 | a message holding `"`, `\` and a tab | the JSON line parses (built with `jq -nc --arg`) |
| CD-04 | `SHARE_EXIT_FILE` points into a read-only directory | the die still prints and exits 1; no second error |
| CD-05 | the hourly prune loop dies while serve runs | `.serve-exit` unchanged (the loop unset the env) |
| CD-06 | a die inside `list_bucket`'s subshell with the env set | `cloud_error` holds the human text; `cloud_error_code` the code |
| CD-07 | serve with a stub cloudflared that exits after 1 s; then a second serve whose stub exits before `/ready` | `.serve-exit` holds `cloudflared_died` after both; it is removed only after a serve whose `/ready` answers |

### Journal (G2)

| # | Scenario | Expected |
|---|---|---|
| JN-01 | a clean run | `ops/` empty after |
| JN-02 | kill -9 at step n | the file names step n; `state.ops[0].alive` false; `status` prints the rerun |
| JN-03 | rerun after JN-02 | prints `previous <verb> died at step n (<name>); continuing`; ends with an empty `ops/` |
| JN-04 | a second run while the first is alive | refused `op_running` naming the pid; the first is untouched |
| JN-05 | a dead file whose pid the OS reused for another process (fixture: the test shell's pid with a wrong `start`) | treated as dead (`owner_live` compares the start time), never `op_running` |
| JN-06 | a dead file whose pid now runs another `share` process of a different verb | dead for this verb; the other verb's own file is untouched |
| JN-07 | `ops/` holds a truncated or non-JSON file | `state` lists it as `{verb:"?", alive:false}` and never fails; the next run of that verb trashes it |
| JN-08 | SIGTERM (the Share Bar's Stop) during step n of `setup-r2` in the dry seam | the verb's locks released by its traps; the file stays at step n; `state.ops[0].alive` false with `rerun` and `rollback`; the rerun continues and ends with an empty `ops/` |
| JN-09 | `SHARE_PROGRESS=1` on a clean run; the same with the env unset | one `{"progress":...}` stderr line per `op_step`, none starting `share: `; unset: stderr byte-identical to HEAD |
| JN-10 | a verb with no rollback (`teardown`) | the file and `state.ops` carry no `rollback` key |
| JN-11 | `setup-r2` killed at step 13, then `share setup <host> --no-r2` succeeds | `ops/` empty; `state.ops` `[]`; `status` prints no dead-op line |
| JN-12 | a live journal written by a process run with `LC_ALL=fr_FR.UTF-8` (or `de_DE`) and `TZ=Asia/Tokyo`; `state` and a second run read with `LC_ALL=C` and `TZ=America/New_York` | the test first asserts that the locale changes raw `ps -o lstart=` output and that the zone changes it; a host without the locale runs the zone half and names the skipped half; the row never passes without one shown change; `alive` true; the second run refused `op_running` |
| JN-13 | a dead journal whose `rerun_argv` holds `;`, `$(touch x)` and a newline inside one argument | `rerun` prints each quoted by `printf %q`; nothing runs; `x` absent |
| JN-14 | (a) a dead `teardown` journal, then `share setup <host>` succeeds; (b) the same with a dead `add` journal also present | (a) `ops/` empty; (b) only the dead `add` file remains, until bare `prune` consumes it (DEC-33) |
| JN-15 | a live journal and a pending line whose `start` is in the unpinned format a pre-upgrade CLI wrote, read from the same environment | `alive` true; a second run refused `op_running` (DEC-34) |
| TD-01 | tunnel `teardown` killed through `SHARE_OP_PAUSE` after the tunnel DELETE; rerun | the rerun treats the 404 as done and ends with an empty `ops/` and no config |
| DP-G-01 | `setup --r2` killed between step 11 (config) and step 13 (route) | `status` names step 11 or 12 and both the rerun and `--no-r2`; the rerun converges |

### Role (G3)

| # | Scenario | Expected |
|---|---|---|
| RL-01 to RL-07 | one fixture HOME per role row, first match wins | `state.role` equals the row; `state.state` as the table says |
| RL-08 | migrated profile: `start`, `serve`, `service install`, `add` | each refused `profile_migrated` before any write |
| RL-09 | a `token_cmd` origin with a leftover `index.migrated` and no `migrated=` key | `role` `origin`; `start` is not refused |
| RL-10 | `migrate` (writes `migrated=`), then `setup <host>` again on the same profile | `migrated` key dropped; `setup` exits 0 and the profile serves; `role` `origin` |

### Config (G4)

| # | Scenario | Expected |
|---|---|---|
| CF-01 | config with `ttl=7d`, `r2_token_cmd=x`, `r2_key_id=y`, `x_future=1`; `setup <host>` rerun | the four lines survive byte for byte and in place |
| CF-02 | config holding only today's keys, for each writer | output byte-identical to HEAD's writer |
| CF-03 | a hand-edited duplicate `port=` | the first one rewritten in place, the second dropped |
| CF-04 | `api-token --cmd` on a config with `members=on` | `members=on` kept |
| CF-05 | a quick profile turned named | `mode` dropped |
| CF-06 | a value holding `=` and spaces | written verbatim; `cfg` reads it back equal |
| CF-07 | the config directory is unwritable | dies before touching the config; no tmp file left |
| CF-08 | `admin-token --cmd $'x\ntoken_cmd=y'`; `config ttl $'7d\r'`; a config whose last line has no trailing newline | the first two die `config_value_bad`, config untouched; the third keeps its last line; the file mode is kept |

### Serve, link, pending, token (G6 to G10)

| # | Scenario | Expected |
|---|---|---|
| SS-01 to SS-08 | one fixture per phase row of `### Diagram`'s serve table | `serve.phase`, `serve.reason`; `[.state,.ready]` equals HEAD |
| LS-01 to LS-05 | live, expired cloud row, shadowed id, gated row with its app gone, a row with no check run | `link_state` as audit D4; `gate_missing` only when a check ran |
| PS-01 to PS-04 | an intent line owned by the live test shell; owner 0; a dead owner; a malformed line | `access_inflight 1`; `access_pending 1`; `access_pending 1`; `access_bad 1` |
| AD-01 to AD-03 | add killed before the row append; after it; bare `prune` after the first | `pub/<id>` trashed and its pointer dropped; nothing touched; `ops/` empty |
| AD-04 | two adds overlap (one held in a gated Access wait); a dead add journal exists | both adds succeed; neither refuses `op_running`; the dead add journal is left for `prune` |
| TK-01 to TK-05 | no token; a token and no cache; cache `invalid`; `expires_on` past; within 14 days | `missing`, `unchecked`, `invalid`, `expired`, `expiring` |
| TK-06 | each of the three teardowns (L4569, L4638, L4660) of a named profile whose dir holds `.health`; then `profiles --json` | the profile dir is gone; the profile is not listed |
| SS-09 | serve's stub cloudflared exits while the service is installed | `serve.phase` `failed`, `reason` `cloudflared_died` |

### Admin key and config (G13, G14)

| # | Scenario | Expected |
|---|---|---|
| AT-01 | `CLOUDFLARE_API_TOKEN` present and `admin_token_cmd` set to a command that would fail | the variable wins; the command never runs (a marker file it would touch stays absent) |
| AT-02 | only `admin_token_cmd` (a fixture command printing a token) on `setup --r2` in the dry seam | the command runs once; the setup proceeds; the token appears in no argv, file or output |
| AT-03 | the command exits 3 and prints text to stdout and stderr | dies `admin_token_cmd_failed` naming exit 3; neither stream's text is printed |
| AT-04 | neither source, on a `required` path (`setup --r2`, `--no-r2`, `teardown --purge`) | dies `admin_token_missing` with `share admin-token --cmd '<command>'` as next, before any write |
| AT-05 | `ls`, `add`, `prune`, `state`, `status`, `profiles --json` with `admin_token_cmd` set | the command never runs (marker absent) |
| AT-06 | `admin-token --test --json` with a fixture admin token in the dry seam; with a publisher token | `can` lists each probed capability true; the publisher token dies `admin_token_not_admin`; neither prints the token |
| AT-07 | `admin-token --cmd 'x'` on a config with `ttl=7d` and `members=on`; then `--clear` | both lines kept byte for byte; `admin_token_cmd=x` written, then dropped |
| AT-08 | neither source, on `setup <host>` (dry login cert), tunnel `teardown`, `setup --quick` | each proceeds as today; no `admin_token_missing` |
| AT-09 | `setup <host>` with only `admin_token_cmd`, no service, a stub `cloudflared` on `PATH` that writes its variable names and values to a file | the file has no `CLOUDFLARE_API_TOKEN` and no fixture token value |
| AT-10 | `SHARE_MINTER_TOKEN` present and `minter_token_cmd` set to a command that would fail; `minter-token --test` | the variable wins; the command never runs (marker absent) |
| AT-11 | only `minter_token_cmd` (a fixture command printing a token), `minter-token --test --json` in the dry seam; then a command that exits 3 and prints to stdout and stderr | runs once, `can.list_tokens` true, the token in no argv, file or output; then dies `minter_token_cmd_failed` naming exit 3 with neither stream's text |
| AT-12 | neither source, `minter-token --test`; then `ls`, `add`, `prune`, `state`, `status`, `profiles --json`, `admin-token --test` with `minter_token_cmd` set | dies `minter_token_missing` with `share minter-token --cmd '<command>'` as next; the listed verbs never run the command (marker absent) |
| AT-13 | `minter-token --cmd 'x'` on a config with `ttl=7d` and `admin_token_cmd=y`; then `--clear`; then `minter-token --cmd $'x\ny'` | both lines kept byte for byte; `minter_token_cmd=x` written, then dropped; the third dies `config_value_bad`, config untouched |
| CG-01 | `config ttl 7d`; `config ttl`; `config ttl --unset` | written through `config_put`; prints `7d`; dropped |
| CG-02 | `config ttl 7x` | dies `config_value_bad` with the valid forms; config untouched |
| CG-03 | `config storage_default cloud` on a profile with no bucket; with one | dies `config_value_bad`; written |
| CG-04 | `config admin_token_cmd x`; `config port 9` | dies `config_key_unknown` naming the settable keys; config untouched |

### Share Bar (G11a to G11c, swift)

| # | Scenario | Expected |
|---|---|---|
| SB-01 | every new key absent (today's fixtures) | every `Health` and derivation equals today's |
| SB-02 | `serve.phase` each value; an unknown value | the phase's copy; the unknown value falls back to today's derivation, never `Error: state not readable` |
| SB-03 | `role` `migrated` | `Moved to another machine`, neutral |
| SB-04 | `link_state` `expired`; an unknown value | Copy Link disabled; the unknown value treated as `live` |
| SB-05 | an alive op; a dead op | `Working: <verb> (<step>/<of>)`; an attention line with the `rerun` string as text only |
| SB-06 | a mutation's stderr ends with the JSON line; one with no JSON line | the message and `next` shown; today's last `share: ` line |
| SB-07 | Stop Waiting on a running add | the new copy |

### Later (G12)

| # | Scenario | Expected |
|---|---|---|
| LK-G-01 | `index` lock held by a live add | `locks[]` names it with the pid and age |
| LK-G-02 | a poll lands inside the 1.5 s copy checkmark (swift) | the checkmark completes |
| LK-G-03 | quick profile starting, then serving | `quick.phase` `pending`, then `live` with the URL |

## Failure modes

| Failure class | Detection signal | Mitigation / recovery |
|---|---|---|
| A stale journal blocks every run (false `op_running`) | JN-05, JN-06; a user report of `op_running` with no process | Liveness is `owner_live`'s pid, share process and start-time triple, never the pid alone |
| A journal never cleaned after a crash | `state.ops` lists dead entries | The next run of the same verb removes it; `status` prints the rerun; nothing else reads it |
| `config_put` reorders or duplicates a key an older CLI reads by first match | CF-02, CF-03 | Owned keys are rewritten at their first occurrence, later duplicates dropped, unowned lines never moved |
| A JSON error line reaches a reader that keeps the last stderr line | CD-06; the Share Bar alert shows JSON | The JSON line is unprefixed (MO:L87 skips it); `list_cloud_error` skips it; the line appears only under `SHARE_ERROR_JSON=1` |
| `state` grows a network call or a write | the three `writes nothing` checks; a `state` timing check | `.health` is read only; `profile_role` checks token existence only |
| Code list drifts from the skill | G5's code check | The suite fails on a code with no skill line |
| `.serve-exit` overwritten by a child process | CD-05 | The loop subshell unsets `SHARE_EXIT_FILE` |
| A Roll back or a later setup succeeds but a dead journal stays, so `status` and the Share Bar keep offering Resume | JN-11, JN-14 | `op_done` on success removes every dead journal of the profile except dead adds (DEC-20, DEC-33) |
| Start times compare unequal across locales or time zones, so a live op reads dead and runs twice | JN-12, JN-15 | `proc_start` pins `LC_ALL=C TZ=UTC0`; `owner_live` accepts the unpinned format for one release (DEC-23, DEC-34) |
| A rerun of teardown or migrate dies forever on a 404 from a delete an earlier run made | TD-01 | remote deletes treat 404 as done; `SHARE_OP_PAUSE` reaches every step (DEC-25) |
| The resolved admin token lives on in the serve daemon's environment | AT-09 | background spawns run under `env -u CLOUDFLARE_API_TOKEN` when the source is `cmd` (DEC-28), and under `env -u SHARE_MINTER_TOKEN` (DEC-35) |
| A config value with a line break injects a line that `token_read` evals | CF-08 | `config_put` refuses `\n` and `\r` in any value (DEC-18) |
| A journal run string is executed through a shell | JN-13, SB-05 | argv arrays; readers exec `share` with no shell; G11 shows the string as text only (DEC-21) |
| A crash loop loses its reason | CD-07, SS-09 | serve writes the child's death; only serve clears it after `/ready` (DEC-26) |
| A healthy profile reads `migrated` and refuses `start` | RL-09, RL-10 | explicit `migrated=` key; role recomputed after each config write (DEC-19, DEC-32) |
| Two overlapping adds refuse each other | AD-04 | `add` journals with `--concurrent` (DEC-22) |
| A torn-down profile still lists | TK-06 | teardown removes `.health` before `rmdir` (DEC-24) |
| bash 3.2 regression (empty array, heredoc in `$( )`) | `/bin/bash -n` and the restricted-PATH run | CLAUDE.md's two rules; `config_put` uses strings, not arrays |

## Compatibility

The binding constraints, read from the code (audit section 3):

```
 old Share Bar ──reads──► profiles --json { schema:1, profiles:[{name, state|error}] }
   SN:L166  state.schema > 1          -> that profile shows "Update Share Bar"
   MM:L221  top-level schema > 1      -> no sections at all
   MM:L38   unknown state.state value -> Health.error ("Error: state not readable")
   JSONDecoder                        -> unknown keys ignored
   MO:L87   alert text = last stderr line starting "share: "
 => add keys only; never bump schema; never add a state.state value; never add a
    trailing "share: " line an old app would show instead of the die line
```

One test per change:

| # | Change | Why nothing breaks | The one test that proves it |
|---|---|---|---|
| CP-01 | G3 `role`, `tier`; migrated -> `not_setup` | New keys only; `not_setup` is an existing value old Share Bars render neutral; config untouched | swift: decode `Fixtures/state.json` plus every new key with today's `Snapshot` and assert `Health == .notSetUp` for a migrated fixture; bash: `state_schema_ok` (tests/share.sh L1000) passes on a migrated HOME |
| CP-02 | G6 `serve {phase, reason}`, `.serve-exit` | `state`/`ready` computed exactly as today (every phase maps onto the old pair); `.serve-exit` is a new file no old CLI reads | bash: for each phase fixture, `jq '[.state,.ready]'` equals the output captured from HEAD |
| CP-03 | G2 and G9 `$root/ops/` journal | New directory; old CLIs ignore it; a die leaves a file, never a changed index or config | bash: kill `setup --r2` at each `op_step` in the dry seam, rerun, assert the happy end state and an empty `ops/` |
| CP-04 | G7 `link_state`, `reason` per row | Additive row keys; rows unchanged; `state_jq_row` (L1488) keeps every field | swift: today's `Share` decodes a row with the new keys; bash: an expired cloud row reads `link_state:"expired"` and every old field equals HEAD |
| CP-05 | G10 `token`, `compat`, `.health` | `state` reads a cache only, adds no network call, writes nothing | bash: the `writes nothing` checks (tests/share.sh L1025, L1036, L1081) stay green with `.health` present and absent |
| CP-06 | G8 `access_pending` fix, `access_inflight`, `access_bad` | The field keeps its documented meaning (SN:L52); old Share Bars stop showing a false line | bash: a pending line owned by the live test shell gives `access_pending 0`, `access_inflight 1`; an owner-0 line gives `access_pending 1` |
| CP-07 | G4 `config_put` | Same file, same `key=value`, same tmp + mv; only stops deleting unknown lines. Old CLIs still drop keys, so SPEC-009 also reads T2 from the marker | bash: a config with `ttl=7d`, `members=on`, `x_future=1` survives a `setup <host>` rerun byte for byte on those lines |
| CP-08 | G1 codes | Human stderr byte-identical unless `SHARE_ERROR_JSON=1`; the JSON line is not prefixed `share: `, so MO:L87 still picks the die line; exit status stays 1 | bash: every existing die-text grep passes unchanged; with the env set the last stderr line parses as JSON with `code` |
| CP-09 | G11a to G11c Share Bar consumes new keys | Each key optional; absent keys fall back to today's rules | swift: every existing `StateMappingTests` row passes on the old fixtures; one row per key present |
| CP-10 | G13 `admin_token_cmd`, G14 `share config` | New key and verbs; old CLIs ignore the key, and an old CLI's whitelist writer drops it, which only sends the Share Bar back to asking each time | bash: AT-07 and CG-01 keep every other line byte for byte |
| CP-11 | G2a `rerun_argv`, `rollback_argv`, `SHARE_PROGRESS` | Additive journal keys; the progress line exists only under the env, unprefixed | bash: JN-09 with the env unset is byte-identical to HEAD |

Old rows, old records, old CLIs: no row format, record format or bucket key changes. A v0.9 CLI never reads `ops/`, `.serve-exit`, `.health` or the new state keys. D7 (Worker rows) and D8 (member table) are SPEC-009's and ride its v5 bump.

## Out of Scope

- Worker named rows and the uniform 404 body (audit D7): SPEC-009 TASK-0d, inside the v5 bump.
- The member status table, lease body and invite codes (audit D8): SPEC-009.
- The Share Bar redesign: SPEC-009 TASK-4b1 to TASK-4b23; G11 only feeds today's `NSMenu`.
- Migrating every one of the remaining die sites to `die_code`: they move as they are touched (X2).
- Rewriting the 28 `r2on` sites to read `$role`: SPEC-009 TASK-1g does it with R7.
- A `schema: 2` state document (approach C).

## Decision Log

- DEC-1: Five shared mechanisms over nineteen bespoke fixes (approach B). Rejected: per-machine patches (the three classifier copies keep drifting); a schema 2 document (breaks every shipped Share Bar, SN:L166).
- DEC-2: `state` stays schema 1, gains keys only, never a `state.state` value; `codes_v` versions the code list instead. Rejected: a schema bump.
- DEC-3: `migrated` maps to `state: not_setup`. Old Share Bars render it neutral with Set Up (MM:L34, MM:L184), the right next action; `stopped` offers a Start that dies. Rejected: a new `migrated` state value (MM:L38 turns it into an error).
- DEC-4: `profile_role` lands now with R0 to R6 and the `member` row reserved; the 28 `r2on` sites move to `$role` only when SPEC-009 TASK-1g touches them. Rejected: rewriting all sites here (a large behavior-neutral diff with no test that catches a slip).
- DEC-5: one journal file per process, `$root/ops/<verb>.<pid>.json`, liveness by `owner_live`. Rejected: one file per verb (two racing runs would overwrite each other's record); the lock files (they answer "held", not "where it stopped").
- DEC-6: the JSON error line is a second, unprefixed stderr line, opt-in by `SHARE_ERROR_JSON=1`; readers that keep the last stderr line skip it, and `state` exposes `cloud_error_code`. Rejected: JSON on stdout (verbs print results there); always-on JSON (changes stderr for every human and old Share Bar).
- DEC-7: `cmd_serve` sets `SHARE_EXIT_FILE` for its own shell and unsets it in the loop subshell, so only serve's own die is recorded. Rejected: a global export (the hourly prune's die would overwrite the reason).
- DEC-8: `config_put` owned sets equal each writer's written plus dropped keys, so a config of known keys comes out byte-identical. Rejected: an allowlist of kept keys (the bug being fixed).
- DEC-9: `profile_role` checks the tunnel token by existence only (Keychain item or 600 file), never the secret and never `token_cmd`, because `state` must not prompt or run a command. Rejected: `token_read` (L293), which may `eval` a `token_cmd` that prompts.
- DEC-10: G2 splits into G2a (core), G2b (`setup --r2`, `--no-r2`), G2c (setup tunnel, teardown, `--purge`, migrate), one session each. Rejected: one G2 task (six verbs and their die-point loops do not fit one session).
- DEC-11: G11 feeds today's `NSMenu` and owns the decode and derivation types; SPEC-009 TASK-4b reuses them for the popover. Rejected: waiting for the redesign (the must-rank fixes would reach no user for a whole SPEC-009 cycle).

Entries DEC-12 to DEC-17 fold the gaps of `docs/design/share-bar-interactions.md` section 8 (written `gap Gn`, not this spec's task ids) that land here; SPEC-009 DEC-44 to DEC-53 hold the Share Bar side of each.

- DEC-12 (gaps G2, G7, G8): the Share Bar's Add a tenant (first run included) and its tier buttons run the existing journaled verbs, never a GUI-only flow: Set up a hostname is `setup-tunnel` (G2c), Join a team is SPEC-009's `join`, Turn on cloud storage is `setup-r2` (G2b), Turn on members is SPEC-009's `setup-members`; G2c's step names are what the add sheet shows. Rejected: a Share Bar wizard that calls Cloudflare itself (ADR-0003: the app goes through the CLI).
- DEC-13 (gap G5): SIGTERM, the Share Bar's Stop, leaves the journal at its step like any die; the journal carries an optional `rollback` so Roll back needs no per-verb knowledge in Swift. Rejected: an EXIT trap that removes the file (Resume would have nothing to read).
- DEC-14: `op_step` prints a progress line under `SHARE_PROGRESS=1` so a running command's own parent sees each step. Rejected: polling `share state` while a command runs (a bucket read and a `/ready` probe per poll); parsing human stdout (it is not a contract).
- DEC-15 (gap G3): the admin token comes from `CLOUDFLARE_API_TOKEN`, else from `admin_token_cmd`, a command and never the token; unset means the Share Bar asks per action and never stores it; only admin paths resolve it (ADR-0009 amended). Rejected: an admin token in the Keychain (stored on every Mac that ever ran an admin verb); reusing `api_token_cmd` (one key would then hold a publisher on one profile and an admin on another, and `r2_publisher_check` exists to keep them apart).
- DEC-16 (gap G6): `members_present` is a reserved code in `code_text` for SPEC-009's teardown refusal on a tenant with members, so the Share Bar maps one code to its refusal sheet. Rejected: matching the refusal's text.
- DEC-17: `share config` sets only `ttl` and `storage_default`, the two CLI defaults the Share Bar's General tab writes (interactions doc section 7); token commands keep their own verbs, which validate and test. Rejected: a general `config set` for any key (it would let the app write `tunnel_id` or `bucket` by hand).

Entries DEC-18 to DEC-29 fold the round-1 validation criticals (2026-11-14).

- DEC-18: `config_put` refuses a value holding `\n` or `\r` with `config_value_bad`, for every writer; today only `api-token --cmd` checks (L2447). A second line such as `token_cmd=<cmd>` would reach `token_read`'s eval (L295). `config_put` also takes a `config` lock and keeps the file mode. Rejected: a check in each verb (G13 and G14 would each need to remember it).
- DEC-19: `migrated` is an explicit config key `migrated=<target>`, written by `migrate_retire` and dropped by every setup writer; token absence is only the fallback for profiles moved before G3. Rejected: inferring from a missing token alone (a `token_cmd` origin, or a profile set up again after a move, keeps no stored token and its `start` would die `profile_migrated`); renaming `index.migrated` (it is the record of what moved).
- DEC-20: a successful verb removes the dead journals of the verbs it supersedes, so a Roll back clears the interrupted op. The per-verb list is replaced by DEC-33's one rule. Rejected: clearing in `op_begin` (a rollback that dies would erase the record of the first failure); leaving dead files for a manual `rm`.
- DEC-21: the journal's rerun and rollback are argv arrays (`rerun_argv`, `rollback_argv`); the strings are display only, quoted with `printf %q`. A journal never holds a token, secret or single-use code. Rejected: one shell string (the Share Bar would need `sh -c` on a file any local process can write, and the string loses `--profile` and the app's CLI path).
- DEC-22: `add` journals with `--concurrent`: no `op_running`, no touching other pids' files; only bare `prune` consumes a dead add journal. Rejected: the same-verb refusal for `add` (two adds overlap today, a gated add can wait minutes, and the next add would erase the dead add that `prune` must roll back).
- DEC-23: `proc_start` pins `LC_ALL=C` (`TZ=UTC0` added by DEC-34). `ps -o lstart=` prints in the caller's locale, and the Share Bar under launchd has no `LANG`. Rejected: comparing only the pid (pid reuse, JN-05).
- DEC-24: transient bookkeeping (journal files, `.serve-exit`) is removed with `rm -f`, never `to_trash`; every teardown removes `.health` before its `rmdir`. Rejected: `to_trash` (each clean setup, each add and each restart would put a file in the user's Trash).
- DEC-25: G2a adds the hidden test seam `SHARE_OP_PAUSE=<verb>:<n>`, which holds `op_step` at step n; every die-point loop uses it, and teardown and migrate deletes treat 404 as done. Rejected: per-verb seams and a notes entry for steps no seam reaches (Q-REL-5 would be untested exactly where a rerun dies on a 404).
- DEC-26: serve writes `cloudflared_died` or `caddy_failed` when `wait` returns, and removes a stale `.serve-exit` only once `/ready` answers. Rejected: clearing at start (a launchd crash loop would erase its own reason every 30 s).
- DEC-27: `admin_token_resolve` has a `required` mode (dies `admin_token_missing`) and an `optional` mode (runs `admin_token_cmd` only when set, else today's env token or browser-login cert). Rejected: one mode at the top of every admin path (`setup <host>`, `setup --quick` and tunnel teardown work today with no admin token and would break).
- DEC-28: when the admin token comes from `admin_token_cmd`, background spawns run under `env -u CLOUDFLARE_API_TOKEN`, so the serve daemon, caddy and cloudflared never hold it. Rejected: unexporting after the verb (setup starts serve before it returns, L4550).
- DEC-29: G13 moves to Phase 1, because SPEC-009 TASK-1c calls `admin_token_resolve`; G11 splits into G11a (decode and health), G11b (link and op lines) and G11c (mutation errors); tasks state their order with `(after ...)`. Rejected: G11 as one task (six behaviors over more than five Swift files, past the atomic size).
- DEC-30 (round 2, regressions of the round-1 folds): G1 splits into G1 (codes) and G1b (the serve exit record), since CD-07 put G1 past the atomic size; G2a tests its core through a hidden `state-fn op-run` driver, and JN-11 moves to G2b, which wires the first verb pair it needs; G3 declares `after G1, G4` (it writes `migrated=` through `config_put`); the serve table lists the r2 rows first, because an r2 profile has no serve process and the `stopped` row would shadow them. Rejected: leaving G2a's tests to wait for G2b (G2a would ship untested).
- DEC-31 (round 2 warnings that were slips in the round-1 folds): `config_put` calls `mk_root` before its lock; `tenant_config` owns `migrated`; the `profile_migrated` target is `cfg migrated`; a successful setup clears dead `teardown` and `migrate` journals (now DEC-33's one rule); serve itself clears `.serve-exit` after its own `/ready` probe, and `cmd_stop` writes after the serve pid is gone; the journal carries `id` for `add`; JN-12 proves the locale changes `ps`; AT-09 dumps from a stub `cloudflared`; `admin_token_resolve` takes one line and checks its charset. Rejected: leaving these to the builder (each one is a contradiction inside the spec).
- DEC-32 (round 2, a regression of DEC-19): `config_put` recomputes `profile_role` after it writes, so a setup that drops `migrated=` passes the `profile_migrated` guard in the same process; G2c also fixes the pre-existing empty `mids` expansion in `migrate` that aborts a rerun under bash 3.2. Rejected: moving the guards to the dispatcher (setup calls `cmd_start` directly, L4550, and would bypass them).

Owner decisions 2026-11-14 on the round 2 rescope proposals:

- DEC-33 (D1, owner decision 2026-11-14): one sweep rule. A successful journaled verb on a profile removes every dead journal of that profile, except dead `add` journals, which only `prune` consumes; `add` itself, journaled with `--concurrent`, runs no sweep. Replaces DEC-20's per-verb supersede list and DEC-31's setup-over-teardown patch. Why: each round found a pair the list missed (a dead teardown, then a successful setup, left Resume showing), and SPEC-009 adds a dozen verbs. Rejected: growing the per-verb list.
- DEC-34 (D2, owner decision 2026-11-14): `proc_start` pins `LC_ALL=C TZ=UTC0`; for one release `owner_live` also accepts the old unpinned format, compared in the caller's own environment, so pending lines and journals written by a pre-upgrade CLI still read alive. JN-12 varies the zone too and proves the locale and the zone change raw `ps` output, so it never passes vacuously. Why: `lstart` prints local time, so two processes in different zones disagree even under `LC_ALL=C`. Rejected: a hard switch (every pending line of a pre-upgrade add would read dead the day the CLI upgrades).
- DEC-35 (D5, owner decision 2026-11-14): config key `minter_token_cmd` on `admin_token_cmd`'s rule: `SHARE_MINTER_TOKEN` wins, else the command runs once per process, never stored, only on minter paths (member add, invite, rotate, renew, rm, adopt); `share minter-token --cmd|--clear|--test`; codes `minter_token_missing` and `minter_token_cmd_failed`. Closes SPEC-009 OQ-8; ADR-0009 amended. Why: the Share Bar runs Invite, Rotate and Renew and has no shell environment. Rejected: env only (no member action from the Share Bar); asking per action as the only mode.
- DEC-36 (D7, owner decision 2026-11-14): G12 stays in Phase 3, outside the current mega-goal. Why: no SPEC-009 task needs `locks[]`, the checkmark timer or the quick-URL phase.

## Open questions

| # | Question | Closes in |
|---|---|---|
| OQ-1 (closed by DEC-19) | A profile whose tunnel token comes from `token_cmd` keeps no Keychain item or file, so the existence check reads "no token" and a migrated detector would also fire on a normal `token_cmd` origin that has an `index.migrated` from an earlier move. Is `index.migrated` plus `tunnel_id` plus "no stored token, or `token_cmd` set and `index.migrated` newer than the config" enough, or does `setup <host>` after a migrate need to rename `index.migrated`? | closed: an explicit `migrated=` config key; RL-09, RL-10 |
| OQ-2 (closed by DEC-25) | Whether every write step of `setup <host>` (tunnel create, DNS, config) and `migrate` is reachable by an existing dry seam (`SHARE_HOST_DRY`, the migrate stubs) for the die-point loop, or G2c needs a `cf()` pause seam like `SHARE_R2_DRY_PAUSE` | closed: `SHARE_OP_PAUSE` in G2a reaches every step |

## Grounding

### Current behavior this spec changes (bin/share at the worktree, unchanged since the audit's base 85db782)

| Claim | Cite |
|---|---|
| `die` prints `share: <msg>` to stderr and exits 1 | L37 |
| `r2on` is set from `backend` and `bucket`; `mode` means the quick tunnel | L67, L77 to L79 |
| `running` is pidfile plus `kill -0` plus a `ps` match | L84 to L88 |
| `cmd_status` prunes first, then prints `not serving: share start` whenever host is set and nothing runs | L1437, L1445 |
| `cmd_state` classifies `serving` / `stopped` / `not_setup` from `running`, `host_name`, `mode` | L1454 to L1456 |
| `cmd_state` counts every pending line, intent lines of a live add included | L1477; `pending_count` with no argument, L2204 to L2212 |
| `cmd_state_r2` does the same for r2 profiles | L3472 |
| `state_jq_row` is the row shape every reader decodes | L1488 to L1490 |
| `cmd_start` dies `not in hosts=`; a failed start points at `serve.log` only | L1380, L1391 |
| `cmd_serve` dies on host, already serving, no tunnel token, port busy | L1179, L1180, L1195, L1199 |
| `write_config` keeps only `token_cmd`, `api_token_cmd` and the four tenant keys | L1677 to L1694 (L1678, L1689 to L1691) |
| `write_config_quick` writes three keys and nothing else | L1645 to L1654 |
| `write_config_r2` keeps only `api_token_cmd` and `r2_token_cmd` | L3817 to L3832 |
| `tenant_config` strips and appends the four tenant keys | L3867 to L3873 |
| `api-token --cmd` rewrites the config without its old `api_token_cmd` line | L2454 |
| `setup --r2` writes the config at step 11, the marker at 12, the route at 13 | L4151 to L4152, L4155, L4166 to L4170 |
| `tenant_die` prints the rollback line only in the dying process | L3957 to L3960 |
| `migrate_retire` forgets the tunnel token and keeps the config | L897 to L936, L932 |
| `token_read` may `eval` a `token_cmd` | L293 to L300 |
| `owner_live` checks pid, a share process, and the same start time | L2213 to L2216 |
| `list_cloud_error` keeps the last non-empty stderr line of the list subshell | L2918 |
| the skill tells agents to run `share status` | L4766, L4791 |
| hidden test verbs exist beside the public ones | L4818 to L4824 |
| `share state` ignores extra arguments | L4828 |
| about 380 die sites | `grep -c 'die ' bin/share` prints 388 lines (helpers included) |

Swift cites (`mac/Sources/ShareBarCore/`): `Snapshot.swift` L166 (schema gate), L52 (`access_pending` doc); `MenuModel.swift` L31 to L39 (`Health.of`), L38 (unknown state), L34 and L184 (not set up), L221 (top-level schema); `MutationOutcome.swift` L87 to L92 (last `share:` line), L111 to L113 (Stop Waiting copy). Cited from the audit, same base.

Test cites: `tests/share.sh` L1000 (`state_schema_ok`), L1025, L1036, L1081 (`writes nothing`), L1748 to L1754 (skill), L1849 (byte identity of existing installs), L3555 (migrate stubs).

### Negative controls (dry traces)

| # | Mutation | Fixture read | Code path | Test that goes red |
|---|---|---|---|---|
| NC-G1 | `die_code` prints the JSON line without `SHARE_ERROR_JSON` | a HOME outside `hosts=` | `share start` | `CD-01` (stderr differs from HEAD's capture) |
| NC-G2 | `op_begin` checks pid liveness only, not the start time | `ops/setup-r2.<test shell pid>.json` with a wrong `start` | `share setup <h> --r2 --bucket b` | `JN-05` (refused `op_running`) |
| NC-G3 | `profile_role` puts `origin` before `migrated` | HOME with `tunnel_id`, `index.migrated`, no token | `share state` | `RL` migrated row (`state: stopped`) |
| NC-G4 | `config_put` drops unowned keys | config with `x_future=1` | `share setup <host>` rerun | `CF-01` |
| NC-G5 | a code added to `code_text` with no skill line | `share state-fn codes` vs `share skill` | the G5 skill check | `every code in share state-fn codes appears in the skill` |
| NC-G6 | `op_done` not called on a clean run | a clean `setup --r2` in the dry seam | `ops/` after exit | `JN-01` (`ops/` not empty) |

## Review
Date: 2026-11-15 | Reviewer: /kit:review (Phase 1 diff, feat/state-groundwork-must)

### Verdict: SHIP

### Findings

## MEDIUM: serve polls /ready every 0.5 s for as long as a stale exit record outlives a down tunnel
**File:** bin/share (cmd_serve, the `.serve-exit` watcher)
**What:** with a stale record and a tunnel that never reports ready, the loop runs one curl per 0.5 s until the child exits.
**Why:** a crash-looping or down tunnel keeps one curl per half second running for hours.
**Fix:** back off to 5 s after the first 10 s of polling.
**Effort:** S

## MEDIUM: a profile moved before G3 forks `security` on every invocation
**File:** bin/share (profile_role)
**What:** the pre-G3 migrated fallback checks the Keychain item's existence on each load, `state` polls included.
**Why:** a locked login Keychain could prompt on a poll. The spec chose the existence check (DEC-9); it runs only when `index.migrated` exists and no `migrated=` key is set.
**Fix:** none now; a rerun of `migrate` or `setup` writes or drops the explicit key. Watch for reports.
**Effort:** S

## LOW: `serve_exit_write` prints the code into JSON unescaped
**File:** bin/share (serve_exit_write)
**What:** codes come from literals, but the `SHARE_PRUNE_DIE_CODE` and `state-fn die` seams accept any string.
**Why:** a seam value holding a quote writes a record that does not parse.
**Fix:** write only a snake_case code; anything else records `unknown`.
**Effort:** S

## LOW: a hand-written journal with a non-numeric step reaches `[[ -gt ]]`
**File:** bin/share (op_read, op_begin)
**What:** `op_read` checks the pid only; a step such as `1x` reaches an arithmetic compare.
**Why:** bash prints an arithmetic error on stderr; the run continues.
**Fix:** `op_read` also requires a numeric step and of.
**Effort:** S

## LOW: tunnel teardown now creates `$root/ops` on a profile with no root
**File:** bin/share (cmd_teardown, op_begin)
**What:** `op_begin` runs `mk_root`; a teardown of a profile that never published leaves an empty `ops/`.
**Why:** an empty directory under `~/share/profiles/<p>`; `profiles` lists config dirs, so no ghost profile.
**Fix:** none needed; noted.
**Effort:** S

## LOW: `teardown --purge` of two cloud links dies at the second `rm` (pre-existing)
**File:** bin/share (cmd_rm_r2 inside r2_purge)
**What:** reproduces on the base commit 84ebd9a; a rerun removes the next link.
**Why:** a purge needs one rerun per extra link.
**Fix:** a separate change; recorded in the implementation notes and the mega-goal ledger.
**Effort:** M

### Previously rejected
none (no `docs/verification/rejected-findings.md`)

### TODOs (open follow-ups)
- the pre-existing two-link purge defect
