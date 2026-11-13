# share: implicit state machines, and how to make each one explicit

Scope: the read-only worktree `multi-member-brief` (HEAD 85db782). Starts where `docs/research/2026-11-13-current-state-machines.md` (the map) stops: the map names roles, link lifecycles, the Worker table and token consequences. This note covers what the map does not make explicit, plus every status SPEC-009 introduces.

Cite form: `L123` = `bin/share` line 123. `MM:L31` = `mac/Sources/ShareBarCore/MenuModel.swift`, `SN:` = `Snapshot.swift`, `MO:` = `MutationOutcome.swift`, `PB:` = `Publish.swift`, `SIC:` = `mac/Sources/ShareBar/StatusItemController.swift`, `S9:L312` = `docs/specs/SPEC-009-multi-member.md`. `map 2.7` = section 2.7 of the map.

Shape imitated: playdate-agent `hold-and-grant-machines.md` and `bridge-job-transitions.md`: named states, one owner, a `can_become` style transition table, guards, and one test per transition (the bridge note's "the unit test lists all 49 pairs").

## 0. Verdict in five lines

1. The CLI already computes most states correctly; what is implicit is the output. Every human and machine reader re-derives state from booleans (`state` + `ready` + `serves_here` + `backend` + `r2`) and from stderr text, so the Share Bar, `status`, and the skill disagree today (rows 1, 2, 3).
2. The worst gaps are progress gaps: a multi-step verb that dies leaves a half state that `state` reports as healthy (row 4: `setup --r2` dies after the config write, `state` says `r2: true`, cloud adds print links that 404).
3. SPEC-009 multiplies both problems: 13 stored member statuses with no transition table, and one outright contradiction (rotate ends in `active`/`paused`, but join refuses anything but `invited`, S9:L312 vs S9:L323).
4. The fix is five shared mechanisms, not nineteen bespoke ones: one owner function per machine, an additive `state` contract under schema 1, a step journal, stable error codes, and a config writer that keeps keys it does not own.
5. Nothing on disk or on the wire breaks: `state` stays schema 1 and gains keys only, the `state` enum gains no value, die text stays byte-identical unless the caller opts in, and the Worker change rides SPEC-009's v5 bump.

## 1. Inventory

Severity: must = a wrong action or silent breakage follows; should = confusing UX/AX with a workaround; later = cosmetic or rare.

| # | Machine | Where | Encoded today | States (named here) | What goes wrong because it is implicit (evidence) | Sev |
|---|---|---|---|---|---|---|
| 1 | Serving state, tunnel profile | `running` L84-88, `wait_running` L1347-1358, `cmd_state` L1450-1490, `cmd_status` L1435-1448, `Health.of` MM:L31-39 | pidfile + `kill -0` + `ps` match; metrics `/ready`; `quick.url`; `svc_installed`; `host_ok`; re-derived in bash text, bash JSON, and Swift | not_setup, stopped, failed (service installed, job not running), starting, tunnel_down, serving, elsewhere | `cmd_status` prints `not serving: share start` whenever host is set and nothing runs (L1445), also on a machine not in `hosts=`, where `cmd_start` then dies `not in hosts=` (L1380). A crash-looping service (port busy, no tunnel token, L1194-1199) shows `Stopped` + Start in the Share Bar; the reason sits only in `serve.log` (L1388, L1365). Three copies of the classification (bash text, bash JSON, Swift) drift independently | should |
| 2 | r2 profile readiness | `cmd_state_r2` L3464-3478, `cmd_status_r2` L3448-3462, MM:L37, MM:L51 | `state:"serving"` whenever `hostname` is set; `ready` = healthz 200 | configured_up, worker_down, worker_skewed, not_setup | An r2 profile with its Worker down shows `Tunnel not connected` (MM:L51): the profile has no tunnel. Version skew is printed by `status` (L3456) but absent from `state`, so the Share Bar and agents never see it | should |
| 3 | Profile role and tenant tier (R0-R6 today, R7 and T2 in SPEC-009) | load-time flags L60-79; map 1.1; `migrate_retire` L897-936; PB:L53-56, PB:L142 | combinations of `hostname`, `tunnel_id`, `mode`, `backend`, `bucket`, `index.migrated`; never one value; Share Bar infers from `backend`/`r2`/`mode` | none, quick, origin, tenant_origin (R3), r2_profile (R4/R5), migrated (R6), member (R7); tier t0/t1/t2 | After `migrate`, config stays (L897-936 never trashes it), so `state` says `stopped` (L1455), the Share Bar raises `Needs attention (Stopped)` with a Start button, and Start dies `no tunnel token` (L1194-1195) because the token was forgotten (L932). SPEC-009 adds R7 detection on top of the same flags (S9:L256-280: 28 `r2on` sites); `StorageField.member` already means R5 (PB:L35-36, L142), a name SPEC-009 reuses for a different role | must |
| 4 | Multi-step verb progress (setup tunnel, `setup --r2`, `--no-r2`, teardown, `--purge`, migrate) | `cmd_setup_tenant` L3977-4199 (steps 11-16 at L4151-4198), `tenant_die` L3957-3960, map 1.4/1.5 | where the process died; the artifact set is the only record | idle, running(step n), died(step n), done | `setup --r2` writes the config at step 11 (L4152) before the route at step 13 (L4166). A die between leaves `state` reporting `r2: true` and `storage_default`; a `share add --cloud` then succeeds and prints a URL the Worker never sees (no route), so it 404s at the tunnel. The rollback line exists only in the dying terminal's scrollback (L3959); `status` cannot repeat it | must |
| 5 | Local add pipeline, and the Share Bar's Stop Waiting | `cmd_add` L465-585, `release_locks` L233; MO:L111-113 | artifact presence (`.stage.X`, `pub/<id>`, row, pointer, pending line) | staged, reserved (pointer), published-bytes, listed, done, died(step) | Stop Waiting says "run it again from the terminal to finish" (MO:L112), but a rerun mints a new id (map 5.5), so the first attempt's `pub/<id>` stays reachable and unlisted, never pruned (map 6.18, L549 vs L568). The copy promises a convergence the verb does not have | should |
| 6 | Access pending line | `pending_*` L2177-2216, `pending_count` L2204-2212, `access_pending_note` L2416-2420, SIC:L276-283 | column 2 shape (`-:<nonce>` vs uuid), column 3 owner pid (`0` = deferred), owner liveness | intent, bound, deferred, orphan, bad | `state` passes `pending_count` with no argument (L1477, L3472): every line, including the live intent line of a gated add in progress. During the up-to-900 s gate wait the 60 s poll (SIC:L110-116) shows `1 Access app(s) await deletion (share prune)` for an add that is working normally | should |
| 7 | Token health (Access token, publisher token, SPEC-009 minted member token) | `api_token_resolve` L1905-1934, `r2_expiry_note` L2504-2520, `r2_menu_token` L2871-2877, map 4.4 | resolved per call; expiry checked only by `api-token` | missing, unchecked, ok, expiring, expired, invalid, admin_refused | An origin whose publisher token expired keeps listing local rows; its next local add dies before any write (L534). The Share Bar learns this only from the failed add's alert; `state` carries no token field, only a free-text `cloud_error` (L2918). SPEC-009 adds `expires_on` and `renew` (S9:L242, MB-19) with nowhere in `state` to show it | should |
| 8 | Per-row link state | `list_bucket` L2879-2895, `r2_reconcile` L2967-2997, `access_ls_check` L2422-2437, MM:L117-128, MM:L97 | expiry compared ad hoc by each reader; shadow and gate loss printed to stderr only on an interactive `ls` with an env token (L705) | live, expired (awaiting prune), shadowed, gate_missing; SPEC-009 adds revoked, paused, origin | Expired cloud rows stay in `state.shares` until a publisher prunes (L2885-2892 lists `crows` with no expiry filter); the Worker already 404s them (L2713). The menu shows `expired` but keeps Copy Link enabled (MM:L97 checks only the URL shape). A gated row whose Access app vanished is PUBLIC (map 2.7), and only a terminal with `CLOUDFLARE_API_TOKEN` hears it. SPEC-009's `revoked` lives in an opts token (S9:L200) with no `state` field | must |
| 9 | Version and compat skew (CLI, Worker, record `v`, `min_cli`, deploy nonce) | map 3.5, L3455-3456, S9:L176, S9:L398 | per-reader `v` checks; healthz pair compared in `status` only; no CLI version constant (S9:L361) | ok, worker_older, worker_newer, cli_below_min, unknown | `state` never reports skew; once SPEC-009's `min_cli` refuses writes (TASK-4a), the Share Bar keeps offering Share File... and the add fails with a stderr line | should |
| 10 | Worker per-request decision | `handle` L2667-2720, `pass` L2646-2662 | a cascade of `if`s; 8 different reasons answer `404` with a null body | rows 1-16 of map 3.2, plus v5 rows S9:L206-222 | A visitor sees a blank 404 whether the link expired, was removed, was forged, or its gate failed. Tests assert status codes only, so a change that moves a request from one 404 row to another passes silently. SPEC-009 adds 8 rows to the same cascade | should |
| 11 | Share Bar UI machine (loading, stale, failure, working, stop-waiting, checkmark, hits) | MM:L214-265, `RefreshGate`, SIC:L52-81, SIC:L846-858 | mostly explicit (`MenuModel`, `Working`, `RefreshGate`); the checkmark is a timer racing `applyModel` | loading, fresh, stale, failed(cliNotFound/oldCLI/other), working, stop_waiting, flashing | A poll landing inside the 1.5 s checkmark (SIC:L848-856) repaints the icon early. Every failure kind is parsed from stderr text: `share: CLI not found` (SN:L217), the help banner prefix (SN:L220), `share: WARNING` (MO:L77-82), the last `share: ` line (MO:L87-92) | later |
| 12 | Publish eligibility (dialog, drop, batch) | PB:L44-56, PB:L140-151, SIC:L646-660 | `state == stopped || serving` with no error | eligible, ineligible(reason) | A migrated profile (row 3) is eligible; SPEC-009 paused/left/removed members are eligible and the add then dies (WM-01). The dialog cannot say why a profile is missing | should |
| 13 | Local locks | `lock_take` L210-226, `add_held` L2965 | symlink `.lock-<name>` naming a pid | free, held(live), stale | A 60 s wait then a die; `state` cannot show who holds `index` | later |
| 14 | Quick URL lifecycle | L1213-1229, `serving_host` L247 | `quick.url` exists only while serving; new each start | none, pending, live(url) | Copy is already guarded (`<pending>`, MM:L97); old links die on restart, which the skill explains (L4792) | later |
| 15 | SPEC-009 member status | S9:L177, S9:L184, verb write orders S9:L284-329, TASK-1e S9:L373 | 13 stored strings, `prev_status`, derived EXPIRED/ONLINE/OFFLINE; per-verb prose only | resting: invited, active, paused, removed, left; intent: adding, joining, pausing, resuming, inviting, rotating, renewing, removing | No from-set per verb: TASK-1e's "continue only if the new status is still valid for the verb" (S9:L373) has no table to check. Rotate ends at `prev_status` (S9:L323) and tells the member to run `join` again, but join step 3 requires status `invited` (S9:L312), so every re-join after rotate dies. `prev_status` overwrite on a rerun of an interrupted `...ing` is unspecified | must |
| 16 | SPEC-009 admin lease and intent | `lock/admin` S9:L180, DEC-20 S9:L759, invariant 5 S9:L166 | lease object + record `...ing`: two encodings of "a verb runs" | free, held(live), stale, taken_over | A crashed verb leaves `...ing` plus a stale lease; the next admin learns which verb and step only by reading two objects and guessing; `member ls` shows status, not the step | should |
| 17 | SPEC-009 invite | S9:L179, Worker row 3 S9:L209, SV-14 to SV-18 | `i/<h>` presence, claim etag, record `invite.hash`, derived EXPIRED | none, sealed, claimed, expired, deleted | Redeem answers 404, 410, or 503 (S9:L209); a 503 leaves the object claimed (SV-18), so the code is spent though the member got nothing. No join error copy or code is specified for each | should |
| 18 | SPEC-009 join progress | join steps S9:L305-315, DEC-21 S9:L760 | local file presence (config, Keychain items, service) plus record status | redeemed, stored, recorded(joining), serving, probed, active | Bare `share join` "resumes" (S9:L244) by inferring the step from which files exist; the invite code is single-use, so a wrong inference costs an admin round trip (DP-join-1) | must |
| 19 | Config file as a state store | `write_config` L1677-1694, `write_config_r2` L3817-3832, `tenant_config` L3867-3873 | `key=value`; each writer re-emits a whitelist | per key: absent, set | `write_config` keeps only `token_cmd`, `api_token_cmd`, and four tenant keys (L1689-1691): a `setup <host>` rerun already drops a hand-set `ttl=`, `r2_token_cmd=`, `r2_key_id=` (map 0.2). SPEC-009 puts `members=on`, `role=member`, `member_id`, `member_mode` in the same file (S9:L190-198) and amends no writer, so a v0.10 `setup <host>` rerun on a T2 origin silently drops `members=on` and with it the teardown, migrate and `--no-r2` refusals | must |

Counts: 19 machines. 6 must (3, 4, 8, 15, 18, 19), 10 should (1, 2, 5, 6, 7, 9, 10, 12, 16, 17), 3 later (11, 13, 14).

## 2. Decisions per machine

Nine decisions cover sixteen machines; rows 11, 13 and 14 stay as they are (section 5 lists the small later items). Each decision names: states, the one owner, transitions, guards, what `state --json` / `ls` / Share Bar show, the human copy, and the stable code.

### D1. One role function (rows 3, 12)

Owner: `profile_role` in `bin/share`, called once at load right after L79; every `r2on`/`backend`/`mode` site that asks "what kind of profile" reads `$role` instead. SPEC-009's R7 detector lands inside it, not as a 29th flag.

| role | detector (first match) | `state.state` (unchanged enum) |
|---|---|---|
| `member` | config `role=member` and `member_id` present | as today |
| `migrated` | `index.migrated` exists, `tunnel_id` set, no tunnel token resolves | `not_setup` (was `stopped`) |
| `r2_profile` | `backend=r2` | `serving` (as today) |
| `quick` | `mode=quick` | as today |
| `tenant_origin` | `tunnel_id` and `bucket` | as today |
| `origin` | `tunnel_id` | as today |
| `none` | else | `not_setup` |

Tier (origin roles only): `t0` no bucket, `t1` bucket, `t2` bucket and (config `members=on` or marker `members:true`, see D9).

Guards: `start`, `serve`, `service install`, `add` on `migrated` refuse before any write. Code `profile_migrated`, copy: `share: this profile moved to <target> (rows in index.migrated); nothing serves here. Next: share --profile <p> teardown --yes`.

Display: `state` gains `role` and `tier`. `status` prints `role: tenant origin (R2 on, members on)`. Share Bar: `PublishChoice.isEligible` and `storageField` switch on `role` when present and fall back to today's rules when absent; a `migrated` profile renders `Moved to another machine` (neutral). `StorageField.member` is renamed `cloudOnly` in Swift (source-only rename, no wire key).

Gains. UX: a migrated profile stops nagging and stops offering a Start that dies. DX: one function replaces 28 flag sites as the place to add R7. AX: an agent reads `role` instead of reconstructing the R-table.

Why `migrated` maps to `not_setup`: old Share Bars already handle that value as neutral with a Set Up item (MM:L34, MM:L184), which is the correct next action; `stopped` sends them to a Start that dies. This changes classification, not the enum.

### D2. Serving state with a reason (rows 1, 2)

Owner: `serve_state` (pure: reads role, `running`, `/ready` or healthz, `svc_installed`, `host_ok`, `$root/.serve-exit`). `cmd_status`, `cmd_state`, `cmd_state_r2` all call it; nothing else classifies.

| phase | condition | `state.state` (old enum) | `ready` |
|---|---|---|---|
| `not_setup` | role none or migrated | `not_setup` | false |
| `elsewhere` | set up, not running, `host_ok` false | `stopped` | false |
| `failed` | service installed, not running, `.serve-exit` holds a code | `stopped` | false |
| `stopped` | set up, not running | `stopped` | false |
| `starting` | running, not ready, pid younger than 30 s | `serving` | false |
| `tunnel_down` | running, not ready, older | `serving` | false |
| `worker_down` | role r2_profile, healthz not 200 | `serving` | false |
| `serving` | running and ready, or r2 healthz 200 | `serving` | true |

Transitions: `start`/login -> starting -> serving; serving -> tunnel_down (cloudflared loses the edge) -> serving; any running phase -> stopped (`stop`) or failed (serve dies); failed -> starting (`start`). `serve` records its own exit: the die helper writes `{"code":"port_busy","at":<epoch>}` to `$root/.serve-exit` when `SHARE_EXIT_FILE` is set (cmd_serve sets it); `stop` writes `{"code":"stopped"}`.

Reason codes: `ok`, `tunnel_down`, `worker_down`, `port_busy`, `metrics_port_busy`, `no_tunnel_token`, `caddy_failed`, `cloudflared_died`, `not_in_hosts`, `stopped`.

Display: `state.serve = {phase, reason}`. `status` copy per phase, `elsewhere` fixed: `not serving here: this machine is not in hosts=<list>; links work while a machine in hosts= serves`. Share Bar: a new `Health` arm reads `serve.phase` when present: `worker_down` -> `Worker not answering`, `failed` -> `Stopped: <reason copy>` with `Start`. Absent key -> today's table.

Gains. UX: the menu says why (`port 8787 in use`), and r2 profiles stop saying "tunnel". DX: one classifier, tested per row, instead of three. AX: an agent gets `reason: port_busy` and does not tail `serve.log`.

### D3. The step journal (rows 4, 5, 18, and the local side of 16)

Owner: three helpers, `op_begin <verb> <rerun>`, `op_step <n> <name>`, `op_done`, writing one JSON file per running process under `$root/ops/<verb>.<pid>.json`:

```
{"v":1,"verb":"setup-r2","step":13,"of":16,"name":"route",
 "pid":4242,"start":"<ps lstart>","started":1763000000,
 "rerun":"share setup s.example.com --r2 --bucket b"}
```

Each verb declares its steps once (`op_steps_setup_r2` prints `n name` lines); the same list numbers `op_step`, renders `status`, and drives the die-point tests (kill at step n, rerun, assert convergence: the SPEC-009 DP pattern, generalized).

```
 op_begin ──► op_step 1 ──► ... ──► op_step n ──► op_done (file trashed)
    │              │                     │
    └──── die / kill / Stop Waiting ─────┴──► file stays: phase died(step n)
 next run of the same verb: finds a dead file for the same verb -> prints
 "previous <verb> died at step n (<name>); continuing" and replaces it
 a live file for the same verb and profile -> refuse, code op_running
```

Liveness reuses `owner_live` (L2213): pid alive, a share process, same start time.

Wired to: setup (tunnel), `setup --r2`, `--no-r2`, teardown, `--purge`, migrate, `join` (row 18: bare `share join` reads the journal step, not file presence), and `add` (row 5). For `add`, bare `prune` finishes or rolls back a dead add: step before the row append -> trash `pub/<id>` if no row, drop its own pointer through `r2_pointer_drop`, leave Access lines to the existing sweep.

Display: `state.ops = [{verb, step, of, name, alive, rerun}]`. `status`: `setup --r2 stopped at step 13 of 16 (route); rerun: share setup s.example.com --r2 --bucket b, or roll back: share setup s.example.com --no-r2`. Share Bar: an alive op of another process -> `Working: setup --r2 (13/16)`; a dead one -> attention `Interrupted: setup --r2 at route`, with the rerun line copyable. Stop Waiting copy (MO:L111) becomes: `The add stops where it is; share prune cleans up what it left.`

Code: `op_interrupted` (with `verb`, `step`), `op_running`.

Gains. UX: "where it died" becomes one line any later command repeats. DX: each verb's step list is data, and one test loop covers every die point. AX: an agent sees `ops[0].rerun` and runs it, with no scrollback.

### D4. Per-row link state (row 8, and SPEC-009 link states)

Owner: `link_state` inside `list_rows`, the one place every row passes (L2897). Inputs: the row, `now`, the shadow set `list_bucket` already computes (L2886), opts tokens, and on R7 the member's own record status.

| link_state | condition | Worker/Caddy answer |
|---|---|---|
| `live` | none below | 200 |
| `expired` | `expires > 0 && expires <= now` | 404 (Worker L2713; Caddy after prune) |
| `shadowed` | a local row whose id also holds a v:1 cloud record | the cloud record wins (L2711) |
| `gate_missing` | gated row whose Access app is gone (only when a check ran) | PUBLIC on a tunnel profile |
| `revoked` | opts `revoked` (SPEC-009) | 404 |
| `paused` | v:3 row whose origin member is paused (R7 knows its own) | 503 paused |

`reason` carries the detail (`revoked_by=<by>`, `cloud_id_wins`). `origin` (SPEC-009) is the member name or empty.

Display: `state.shares[].link_state`, `.reason`, `.origin`; `ls` adds a STATE column only when a row is not `live`. Share Bar: `expired`/`revoked` rows disable Copy Link and Open, trailing text `expired` / `removed by <who>`; `gate_missing` turns the section to attention (`Public: login gate missing`).

Gains. UX: no Copy Link on a dead link. DX: one function for expiry instead of one per reader. AX: an agent tells "listed" from "served" without knowing the Worker table.

### D5. Token and compat objects (rows 7, 9)

Owner: `token_state` and `compat_state`, reading a cache `$config_dir/.health` (JSON, 0600, no secret: `{token:{source, verified_at, expires_on, verify:"ok|invalid"}, worker:{pair, deploy, at}, min_cli}`) written by `api-token`, `status`, `setup`, interactive `prune`, and on R7 the member loop. `state` reads the cache only (it stays read-only and adds no network call).

| token.status | rule |
|---|---|
| `missing` | no source resolves (same order as `r2_menu_token`, L2871) |
| `unchecked` | a source resolves, no cache |
| `invalid` | cache `verify:"invalid"` |
| `expired` / `expiring` | cache `expires_on` past / within 14 days (the existing threshold, L2504) |
| `ok` | else |

`compat.status`: `ok`, `worker_older`, `worker_newer`, `cli_below_min`, `unknown`.

Display: `state.token = {source, status, expires_on}`, `state.compat = {cli, worker, status, min_cli}`. Share Bar: `expired`/`invalid`/`cli_below_min` mark the profile attention and make it ineligible for publishing with the reason (`Token expired: share api-token`). Codes: `token_missing`, `token_expired`, `token_invalid`, `token_admin_refused`, `cli_below_min`, `worker_older`.

Gains. UX: the menu warns before an add fails. DX: one rule for "is the token usable" instead of three resolvers' side effects. AX: `share state` answers "can I publish here" without trying.

### D6. Access pending states (row 6)

Owner: `pending_state <line>` returning `intent`, `bound`, `deferred` (owner 0), `orphan` (owner dead), `bad`. `pending_count` takes a state list.

Display: `state.access_pending` = deferred + orphan (what its Swift doc already says it is, SN:L52: "waiting for deletion"); new `state.access_inflight` = intent + bound with a live owner; `state.access_bad` = bad. `ls`/`status` print the deletion note only for deferred and orphan.

Gains. UX: no "run prune" during a normal gated add. DX: the five line states are named once. AX: an agent never runs a sweep against a working add.

### D7. Named Worker rows (row 10)

Owner: a pure `decide(request, env, rec)` in the Worker source returning `{row, status}`; `handle` performs it. Row ids are constants (`ALIAS_301`, `WRONG_HOST`, `BAD_PATH`, `HEALTHZ`, `PASS_NON_ID`, `PASS_MISS`, `BAD_JSON`, `PASS_V2`, `V2_EXPIRED`, `BAD_RECORD`, `GATE_DENIED`, `V3_PAUSED`, `V3_UNBOUND`, `V3_DOWN`, `REDEEM_*`, `CLOUD_OBJECT`).

Visitor answer: status codes unchanged. Every Worker 404 gets one plain-text body, `no such link (it may have expired or been removed)`, the same for every 404 row, so no row is revealed (an id-existence oracle over 24-bit ids would be a leak). No reason header.

Tests: `tests/worker.mjs` asserts the row id, not only the status.

Gains. UX: visitors read a sentence instead of a blank page. DX: a regression that moves a request between two 404 rows goes red. AX: an agent changing the Worker edits one table-shaped function.

### D8. Member status, lease, invite (rows 15, 16, 17; SPEC-009)

Owner: `member_can <status> <verb> <actor>` in `bin/share`, a `case` table (bash 3.2: no associative arrays), called by `reg_status` before every record write. The same table is the doc table; the test iterates all 13 x 12 pairs.

```
            add            join(member)        join(member)
  (none) ─────► adding ───► invited ───► joining ───► active ◄────────────┐
                 │            ▲  │                     │ │  ▲            │
                 │   invite   │  │ rm                 │ │  │ resume      │
                 │  inviting ─┘  ▼                    │ │  └── resuming ◄┐│
                 │            removing ──► removed ───┼─┼──► (purge)    ││
                 │                ▲                   │ └► pausing ► paused
                 └── rm ──────────┘   (rm from every   │       rotate: active|paused
                                       status except   │       ─► rotating ─► invited
                                       removed)        ▼          (prev_status kept)
                                                   left (leave)
```

Transition table (from-set per verb; any `...ing` of the same verb is also allowed, which is a rerun):

| verb | actor | from | intent | to |
|---|---|---|---|---|
| add | admin | (none) | adding | invited |
| invite | admin | invited, joining, left | inviting | invited |
| pause | admin | active | pausing | paused |
| resume | admin | paused | resuming | active |
| rotate | admin | active, paused | rotating | invited (prev_status = active or paused) |
| renew | admin | invited, active, paused | renewing | the status it started from |
| rm | admin | every status but removed | removing | removed |
| purge | admin | removed | (none) | record deleted |
| adopt | admin | (none) | (none) | active (cloud) |
| join step 3 | member | invited | joining | (step 6) prev_status if set, else active |
| leave | member | active, paused | (none) | left |
| sync | admin | any | (none) | deploy wins for paused/active only (S9:L329) |

Guards: a verb that finds the record in a different verb's `...ing` refuses with code `member_busy`, copy `share: <name> is mid-<verb> (step <n>) since <time>; finish it: share member <verb> <name>`, except `rm` (wins from any status, CC-04) and `sync` (reports). The member may never write once the record is `removing` or `removed`. `prev_status` is written only when entering an `...ing` from a resting status, never rewritten by a rerun, cleared on reaching a resting status. EXPIRED, ONLINE, OFFLINE stay derived (DEC-19).

Rotate fix: rotate ends in `invited` with `prev_status` kept; join's final write restores it, so a paused member stays paused after re-joining (MB-12's intent) and join step 3 keeps one rule (`invited`).

Lease: the `lock/admin` body becomes `{v:1, holder, verb, member, step, taken}`, updated by `lease_renew` at each step. The record gains `step` (and `step_name`) beside `status`. `member ls` prints `an: pausing, step 2 of 3 (deploy), lease held by mini:4242 (live)` or `(stale since 14:02; rerun: share member pause an)`.

Invite and join codes (the member's terminal copy):

| redeem answer | code | copy |
|---|---|---|
| 404 | `invite_unknown_or_used` | `this invite was already used or never existed; ask the admin: share member invite <name>` |
| 410 | `invite_expired` | `this invite expired; ask the admin: share member invite <name>` |
| 503 | `invite_unavailable` | `the invite could not be released (it is now spent); ask the admin: share member invite <name>` |
| mac mismatch | `invite_tampered` | `this invite was altered; ask the admin for a new one` |
| record 412 | `member_changed` | `the admin changed this member during the join; nothing was kept here` |

Display: `member ls --json` objects gain `step`, `lease`; on R7, `state.member = {id, name, mode, status, step, token_expires}` (S9:L158's `member_status` becomes `member.status`, additive). Share Bar: a member profile shows its status line; `paused`/`left`/`removed` make it ineligible for publishing (row 12) with the reason.

Gains. UX: every member state has one sentence and one next command. DX: TASK-1e gets a table to test instead of "still valid for the verb". AX: an agent sees `member_busy` with the verb to rerun, and `member ls --json` names the stuck step.

### D9. Config writer that keeps what it does not own (row 19, plus T2 authority)

Owner: `config_put <owned keys> <key=value...>`: rewrites the owned keys, keeps every other line in file order, tmp + `mv -f` as today. `write_config`, `write_config_r2`, `write_config_quick` and `tenant_config` become calls to it, each declaring its owned set (`write_config` owns the tunnel keys, and drops `mode` explicitly when converting a quick profile).

T2 authority: `tier` is `t2` when config `members=on` OR the marker reads `members:true`; when the two disagree, `state.tier_drift = true`, code `config_drift`, copy `share: the bucket says members are on but this config does not; repair: share setup <host> --r2 --bucket <b> --members`. The guards in teardown, migrate and `--no-r2` already read the bucket on a T2 origin; they check the marker, so a dropped config key cannot open them.

Gains. UX: a setup rerun stops eating `ttl=` and `r2_token_cmd=`. DX: one writer to review. AX: an agent can hand-add a documented key without a later rerun deleting it.

## 3. Compatibility

The binding constraints, read from the code:

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

| Change | Why nothing breaks | The one test that proves it |
|---|---|---|
| D1 `role`, `tier`; migrated -> `not_setup` | New keys only; `not_setup` is an existing value old Share Bars render neutral; config untouched | Swift: decode `Fixtures/state.json` plus every new key with the current `Snapshot` and assert `Health == .notSetUp` for a migrated fixture; bash: `state_schema_ok` (tests/share.sh L1000) still passes on a migrated HOME |
| D2 `serve {phase, reason}`, `.serve-exit` | `state`/`ready` values computed exactly as today (the table maps every phase onto the old pair); `.serve-exit` is a new file no old CLI reads | bash: for each phase fixture, `jq '[.state,.ready]'` equals the pre-change output captured from HEAD |
| D3 `$root/ops/` journal | New directory; old CLIs ignore it; a die leaves a file, never a changed index or config | bash: kill `setup --r2` at each `op_step` in the dry seam, rerun, assert the happy end state and an empty `ops/` |
| D4 `link_state`, `reason`, `origin` per row | Additive row keys; rows themselves unchanged; `state_jq_row` keeps every existing field | Swift: old `Share` decode of a row with the three keys; bash: an expired cloud row reads `link_state:"expired"` and every old field equals HEAD |
| D5 `token`, `compat`, `.health` cache | `state` reads a cache only, adds no network call and writes nothing (keeps the "writes nothing" check, L1025) | bash: `not_setup: writes nothing` and the stopped/serving variants stay green with a `.health` file present and absent |
| D6 `access_pending` semantic fix, `access_inflight`, `access_bad` | The field keeps its documented meaning (SN:L52); old Share Bars just stop showing a false line | bash: a pending line owned by the live test shell -> `access_pending 0`, `access_inflight 1`; an owner-0 line -> `access_pending 1` |
| D7 Worker named rows, 404 body | Rides SPEC-009's v5 bump (TASK-0d), so no extra `WORKER_VERSION`; status codes unchanged; v4 deployments untouched until an admin redeploys | worker.mjs: every existing status row passes on the v5 source, plus one assert per row id |
| D8 member table, rotate fix, lease body, `step` field | All objects are new in SPEC-009 (no deployed `u/`, `i/`, `lock/admin` exists); readers validate fields and ignore extras | bash: iterate all (status, verb, actor) pairs through `member_can`; DP-rotate plus a re-join asserts `paused` survives |
| D9 `config_put` | Same file, same `key=value`, same tmp + mv; only stops deleting unknown lines. Old CLIs still drop keys, so T2 is also read from the marker | bash: a config with `ttl=7d`, `members=on`, `x_future=1` survives `setup <host>` rerun byte for byte on those lines; a T2 origin whose config lost `members=on` still refuses teardown |
| X2 error codes | Human stderr is byte-identical unless the caller sets `SHARE_ERROR_JSON=1`; the extra line is JSON, not prefixed `share: `, so MO:L87 still picks the die line; exit status stays 1 | bash: every existing die-text grep passes unchanged; with the env set, the last stderr line parses as JSON with `code` |

Old rows, old records, old CLIs: no row format, record format, or bucket key changes in D1-D9. `index.tsv` gains only SPEC-009's `revoked` token, which `rows_in` already passes (S9:L809). A v0.9 CLI never reads `ops/`, `.serve-exit`, `.health`, or the new state keys.

## 4. Cross-cutting decisions (each lifts UX, DX and AX at once)

X1. One state contract, schema 1, additive forever. `share state` (and `state --json` as an accepted alias) is the only machine-readable surface for a profile; `profiles --json` embeds it unchanged; `member ls --json` is the only one for members. Every object that has a lifecycle carries `phase` (or `status`) from a closed list plus a `reason` code. A `codes` key (`"codes_v":1`) versions the code list, not the schema. The codes live in one bash `case` function `code_text <code>` that returns the human copy and the next-command template; the skill and docs are generated from or checked against it by the suite.

X2. Every refusal carries a stable code and a next command. `die_code <code> <message> [next]`: prints the same `share: <message>` line as today; with `SHARE_ERROR_JSON=1` it appends one JSON line `{"error":{"code":..,"message":..,"next":..}}`; with `SHARE_EXIT_FILE` set it records the code (D2). Start with the state-transition guards (about 75 dies already name `$me`, 46 say rerun, of 378 total); the rest migrate as they are touched. Exit status stays 1. The new Share Bar sets the env var and shows `next` as a copyable line; old ones see today's text.

X3. Every multi-step command records its step (D3). The step list is the verb's documentation, its `status` line, and its die-point test matrix at once.

X4. Agents read machine state only from JSON. `share skill` (L4748-4801) currently tells agents to run `share status` (L4766, L4791), a human text verb that also prunes (L1437). Rewrite the skill's "Before anything" to `share state` and list the `phase`/`reason`/`link_state`/`code` values with one line of meaning each; `status` stays the human view.

X5. One owner function per machine, pure where possible, reachable by a hidden test verb (precedent: `r2-rows`, `r2-id`, `worker-src`, L4821-4824): `share state-fn role|serve|link|pending|member-can <args>`. Swift mirrors only display rules, never classification: when `role`, `serve`, `link_state` are present the app uses them; its own derivation stays only as the fallback for an older CLI.

## 5. Proposed amendments and the groundwork spec

### SPEC-009 amendments

| # | Amendment | Where | Rank |
|---|---|---|---|
| A1 | Add the D8 transition table as the contract of `reg_status`; AC: a test iterates every (status, verb, actor) pair; `member_busy` refusal for a different verb's `...ing` (rm and sync excepted); the `prev_status` rule | TASK-1e AC; new edge rows MB-24 (busy), MB-25 (prev_status on rerun) | must |
| A2 | Rotate ends in `invited` with `prev_status`; join's final write restores it. Amend S9:L323, MB-12, join step 3 note | TASK-3c, TASK-1h, `sm-member` delta | must |
| A3 | Records carry `step`/`step_name`; join resumes from the D3 journal, not file presence (DEC-21 amended); every DP row also asserts that `member ls` or `status` names the died step and the rerun | TASK-1e, TASK-1h, DP rows | must |
| A4 | `state` additions stay schema 1 and never add a `state.state` value; `member_status` becomes `state.member.status`; rows gain `link_state` with `revoked`/`paused`; OC-06 extended: a current Share Bar fixture decode with every new key, and an unknown `state.state` value test proving why none is added | TASK-0c, TASK-4b, OC-06 | must |
| A5 | T2 = config `members=on` OR marker `members:true`; drift reported as `config_drift`; TN-09 gains "die between marker and config: refusals still hold" | TASK-1d, TN-09 | must |
| A6 | Config writers keep keys they do not own (D9) before any new key lands; AC: `members=on`, `role=member`, `member_id`, `member_mode` survive a `setup` rerun and an `api-token --cmd` write | new TASK-0f (Phase 0) | must |
| A7 | Every new refusal (member verbs, join, min_cli) uses `die_code`; `member ls --json` `drift[]` entries are codes | TASK-1c, TASK-1i, TASK-4a | must |
| A8 | Lease body names verb, member, step; `member ls` prints live or stale holder with the rerun | TASK-1c, CC-09 | should |
| A9 | The invite/join code and copy table (D8) as the join refusal contract; MB-07 asserts code per refusal | TASK-1h, MB-07 | should |
| A10 | Worker v5 `decide()` with named rows and the uniform 404 body (D7) inside the one v5 bump | TASK-0d | should |
| A11 | R7 `state.token` with `expires_on` (D5) so MB-19's warning reaches the Share Bar, not only `status` | TASK-3d, TASK-4b | should |
| A12 | RowGlyph word for v:3 rows: `on <member>'s machine` (today `on this tenant's machine`, `RowGlyphs.swift` L40) | TASK-4b | should |
| A13 | R7 config stores the bucket as `member_bucket=` so an older CLI on a member machine computes `r2on=0` and never writes v:2 pointers the origin would reap (L78-79) | TASK-1g | later |

### Groundwork spec (outside SPEC-009; ship before SPEC-009 Phase 1, since A3, A6 and A7 build on it)

| # | Task | Rank |
|---|---|---|
| G1 | `die_code`, `code_text`, `SHARE_ERROR_JSON`, `SHARE_EXIT_FILE`; migrate the state-transition guards first | must |
| G2 | Step journal `$root/ops/` (`op_begin`/`op_step`/`op_done`), wired to setup, `setup --r2`, `--no-r2`, teardown, `--purge`, migrate; `state.ops`, `status` line; die-point loop in the suite | must |
| G3 | `profile_role` + `role`/`tier` in `state`; migrated maps to `not_setup` and refuses start/serve/add with `profile_migrated` | must |
| G4 | `config_put` replacing the four whitelist writers (fixes `ttl=`, `r2_token_cmd=`, `r2_key_id=` loss today) | must |
| G5 | Skill rewrite: agents read `share state`; codes listed; suite checks every code in `code_text` appears in the skill | must |
| G6 | `serve_state` + `serve {phase, reason}` + `.serve-exit`; `status` elsewhere copy fix | should |
| G7 | `link_state` per row (expired, shadowed, gate_missing) | should |
| G8 | `pending_state`; `access_pending` = deferred + orphan; `access_inflight`, `access_bad` | should |
| G9 | `add` journal and the bare-prune cleanup of dead adds; Stop Waiting copy fix | should |
| G10 | `.health` cache with `token` and `compat` objects | should |
| G11 | Share Bar consumes `role`, `serve`, `ops`, `link_state`, `token`, `compat`, and the JSON error line, each with today's derivation as the fallback; Swift fixture tests for present and absent keys | should |
| G12 | Later: `locks[]` in `state` (holder pid, age), checkmark timer owned by `MenuModel` so a poll cannot cut it short, quick-URL `phase` | later |

Counts: SPEC-009 amendments 7 must, 5 should, 1 later; groundwork 5 must, 6 should, 1 later.

Proposed: write the groundwork as SPEC-010 and land G1 to G5 before SPEC-009 TASK-0b, because SPEC-009's DP tests, join resume, and member refusals all need the journal, the codes, and the key-preserving writer to exist first. Proposed: fold A1 and A2 into SPEC-009 now, before TASK-1e is written, because the rotate and join contradiction becomes a shipped bug the day TASK-3c lands.
