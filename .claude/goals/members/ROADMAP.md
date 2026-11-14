# Mega-goal: multi-member tenants

Destination: SPEC-010 groundwork, then SPEC-009 phase by phase, ending with a live member on s.console.so.
Specs: `docs/specs/SPEC-010-state-groundwork.md`, `docs/specs/SPEC-009-multi-member.md` (both VALIDATED, owner decisions D1 to D5 and D7 applied).
Run config: merge_autonomy full-auto (owner: "auto approve till the end", 2026-11-14), MEGA_MERGE_POSTURE auto-to-final, WAVE_CAP 2.
Terminus: deployable. Sub-goal 12 is the live acceptance on a real tenant; the owner pre-approved it. No release tag is cut inside this mega-goal (D10).
Done = a box is `[x]` only with `-- PR #<n>` of a merged PR.

- [ ] SG-01 Live samples on Console Labs (SPEC-009 TASK-1a) , auto , depends none
- [ ] SG-02 State groundwork must (SPEC-010 G1 G1b G2a G2b G2c G3 G4 G5 G13) , auto , depends none
- [ ] SG-03 Caddy listed rows and Worker v5 (SPEC-009 TASK-0a to 0f) , auto , depends SG-02
- [ ] SG-04 State groundwork should, bash (SPEC-010 G6 G7 G8 G9 G10 G14) , auto , depends SG-03
- [ ] SG-05 Members core (SPEC-009 TASK-1b to 1i) , auto , depends SG-04 SG-01
- [ ] SG-06 Share Bar foundations (SPEC-010 G11a G11b G11c, SPEC-009 TASK-4b1 to 4b5) , auto , depends SG-04
- [ ] SG-07 Revoke, reconcile, rm, purge, leave (SPEC-009 TASK-2a to 2e) , auto , depends SG-05
- [ ] SG-08 Pause, resume, invite, rotate, renew, adopt, min_cli (SPEC-009 TASK-3a to 3f, 4a) , auto , depends SG-07
- [ ] SG-09 Share Bar popover (SPEC-009 TASK-4b6 to 4b13) , auto , depends SG-06
- [ ] SG-10 Share Bar settings and flows (SPEC-009 TASK-4b14 to 4b23) , auto , depends SG-09
- [ ] SG-11 Docs and the live e2e suite (SPEC-009 TASK-4c, 4d) , auto , depends SG-08 SG-10
- [ ] SG-12 Live acceptance on s.console.so (SPEC-009 TASK-4e) , auto , depends SG-11
