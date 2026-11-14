# SG-02 State groundwork, must (SPEC-010 Phase 1)
Model: opus
Effort: high
**Branch:** feat/state-groundwork-must
Design: bearing
Wall budget: 480 min
Port base: 21000

## Done =
SPEC-010 Phase 1 tasks G1, G1b, G2a, G2b, G2c, G3, G4, G5 and G13 (admin and minter key commands, D5) pass their AC, in the task order the spec's `(after ...)` lines give. Every JN, CD, RL, CF, AT, TD and DP-G row those ACs cite has a named passing test in `tests/share.sh` under `=== state groundwork: <task> ===`. The die-point loops converge with an empty `ops/`. Every negative control NC-G1 to NC-G6 (and any added by the folds) has a recorded red run and green run. CP-01: the shipped v0.9.0 Share Bar decodes the new `state` (decode `Fixtures/state.json` plus the new keys with today's types). With `SHARE_ERROR_JSON` unset, stderr of every migrated guard is byte-identical to HEAD's capture. The bash 3.2 `migrate` empty-array must-fix in G2c is in.

## Scope edges
- `bin/share`, `tests/share.sh`, `CONTEXT.md` (glossary, created by G5), the implementation notes and the proof file.
- Do not start any Phase 2 task. Do not change Swift sources except a test fixture CP-01 needs.

## Proof
`docs/verification/state-groundwork-must.md` with the full suite green run, the restricted-PATH `/bin/bash` 3.2 run, and each negative control red then green.

## Touches
bin/**
tests/**
CONTEXT.md
docs/implementation-notes/state-groundwork.md
docs/verification/state-groundwork-must.md
