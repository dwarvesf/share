# SG-03 Caddy listed rows and Worker v5 (SPEC-009 Phase 0)
Model: opus
Effort: high
**Branch:** feat/worker-v5-listed-rows
Design: bearing
Wall budget: 420 min
Port base: 22500

## Done =
SPEC-009 TASK-0a to 0f pass their AC. Worker v5 is the pure `decide()` with named rows and the uniform 404 body; every `v5` row in `tests/worker.mjs` asserts the row id, not only the status; the fake `vpc_service` binding and the R2 fake with `onlyIf.etagMatches` exist. SV-01 to SV-28 and DY-01 to DY-05 are green; SPEC-008 compat row 1 changes only for the Caddyfile. `share version` equals the newest CHANGELOG heading (OT-19). Where TASK-1a (SG-01) has not landed yet, build to the documented binding shape and note it; a later sample that disagrees lands as a Worker fix in SG-05.

## Scope edges
- Worker v5 is inert for T0 and T1 tenants; do not deploy anything live.
- TASK-0c and 0f use SPEC-010 G3, G4 and G7 per the spec's gate table; G7 has not landed yet, so take the fallback the gate table names.

## Proof
`docs/verification/worker-v5.md`: suite, `node tests/worker.mjs`, negative controls of the Worker rows red then green, `## Rollback` (a deployed v5 rolls back with `setup --force` to v4 only while no `vpc_service` binding exists).

## Touches
bin/**
tests/**
bin/release
CHANGELOG.md
docs/implementation-notes/multi-member.md
docs/verification/worker-v5.md
