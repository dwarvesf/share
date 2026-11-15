# Audit to spec trace: what SPEC-009 and SPEC-010 still miss

Input: `docs/research/2026-11-13-implicit-state-machines.md` (19 rows, 6 `must`) traced against SPEC-009 and SPEC-010 at commit 0945149. Read this before the mega-goal roadmap is final.

## Coverage

| row | sev | covered by | verdict | gap |
|---|---|---|---|---|
| 1 | should | SPEC-010 G6, G1, G11 | full | |
| 2 | should | G6, G10, SPEC-009 4b2 | full | |
| 3 | must | G3, `profile_migrated`, 4b2, 1g | partial | `migrated` detector unresolved (OQ-1) |
| 4 | must | G2a, G2b, DP-G-01, `tenant_rollback` | partial | journal only reports; nothing refuses `add --cloud` after a dead `setup-r2` |
| 5 | should | G9, G11, SPEC-009 0b | full | |
| 6 | should | G8 | full | |
| 7 | should | G10, 3d, G1 | partial | a failed add with 401 never writes `.health` |
| 8 | must | G7, G11, 4b9, 0c | partial | gate-lost half unfixed; G7 sits in Phase 2 |
| 9 | should | G10, 0a, 4a, 4b2 | partial | G10 has no CLI version source and no compat tests |
| 10 | should | 0d, DEC-38 | full | |
| 11 | later | G12, G1, G11 | partial | stderr-text parsing untouched (accepted as later) |
| 12 | should | G3, 4b2, WM-01 | full | |
| 13 | later | G12 | full | |
| 14 | later | G12 | full | |
| 15 | must | 1e `member_can`, DEC-29/30/41 | full | |
| 16 | should | DEC-36, 1c, 1i | full | |
| 17 | should | DEC-37, 1h | full | |
| 18 | must | DEC-31, 1h, G2a | partial | join step 2 is one journal step with three writes |
| 19 | must | G4, 0f, DEC-33/34 | full | |

## Gaps to fold before coding

1. **Row 3, OQ-1.** A `token_cmd` origin keeps no stored token, so an old `index.migrated` makes a working origin read as `migrated`, and `start`/`add` refuse. Decide OQ-1 in SPEC-010 `### profile_role` before the RL fixtures are final.
2. **Row 4, dead `setup-r2`.** `op_interrupted` is listed in G1 but no guard uses it. Add to G2b: refuse `add --cloud` and cloud publish while a dead `setup-r2` op sits at step 11 or 12. SPEC-009 4b2 eligibility reads `ops`.
3. **Row 8, gate lost.** G7 sets `gate_missing` only when a check ran, and `state` makes no network call, so the Share Bar never learns a gated row went public. Add to G7/G10: an interactive `ls` or `prune` with a token stores the last check result in `.health`, and `state` reads it.
4. **Row 8, phase.** Row 8 is `must`, but G7 and G11 are Phase 2. SPEC-009 line 7 omits G6 to G8, yet TASK-0c extends G7's `link_state`. Add G7 to SPEC-009 `Depends on` and TASK-0c; move the expired and Copy Link slice of G7/G11 into Phase 1.
5. **Row 9, version source.** G10 emits `compat.cli`, but `SHARE_VERSION` is SPEC-009 TASK-0a. Name the version source in G10 (or move 0a into SPEC-010) and add compat rows to the G10 AC.
6. **Row 7, 401 on add.** Add to G10 AC: a failed add with 401 sets `verify:"invalid"` in `.health`.
7. **Row 18, join step 2.** Unseal, two Keychain stores and the config write share one `op_step`; a die inside leaves `step=2` with the unsealed bundle lost. Split step 2 in the SPEC-009 `seq-join` table, one `op_step` per write, with a DP-join row per cut.
8. **Concurrent add (no audit row).** With the G9 `add` journal, `op_begin` refuses `op_running`, so a second concurrent `share add` dies instead of waiting on the index lock. Add to G9 AC: journal `add` per invocation, or exempt it from `op_running`.

## Status 2026-11-15

Checked against main at f8042fa before the SG-18 run. Five of the eight gaps were already handled, three needed a fix, and one optional leg of gap 3 was added.

| Gap | Status | Where |
|---|---|---|
| 1 (row 3, OQ-1) | handled | OQ-1 closed by SPEC-010 DEC-19; the RL-09 and RL-10 rows cover a `token_cmd` origin |
| 2 (row 4, dead `setup-r2`) | fixed by SG-18 | SPEC-010 G2b and DEC-37, row JN-16; `op_interrupted_guard` in `cmd_add` |
| 3 (row 8, gate lost) | the `ls` half was already in G7 and G10; the prune leg is fixed by SG-18 | SPEC-010 G7, DEC-38, row LS-06: the bare `prune` verb runs `access_ls_check`, from an exported token only |
| 4 (row 8, phase) | handled | G7 added to SPEC-009 `Depends on` and TASK-0c |
| 5 (row 9, version source) | handled | SPEC-009 TASK-0a gives `SHARE_VERSION` and `share version`; the G10 suite checks `worker_older`, `worker_newer` and `cli_below_min` |
| 6 (row 7, 401 on add) | fixed by SG-18 | SPEC-010 G10 and DEC-39, row TK-07; `r2_auth_verdict` after a failed upload, record PUT or pointer PUT |
| 7 (row 18, join step 2) | fixed by SG-18 | SPEC-009 DEC-82; `op_steps_join` has nine rows; rows DP-join-1a to 1d |
| 8 (concurrent add) | handled | SPEC-010 DEC-22 and row AD-04; `add` journals with `--concurrent` |
