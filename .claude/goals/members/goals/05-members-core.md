# SG-05 Members core (SPEC-009 Phase 1)
Model: opus
Effort: high
**Branch:** feat/members-core
Design: bearing
Wall budget: 600 min
Port base: 25500

## Done =
SPEC-009 TASK-1b, 1c1, 1c2, 1d, 1e, 1f1, 1f2, 1f3, 1g, 1h and 1i pass their AC, in the order the spec gives. The `member_can` triple iteration matches the doc table. Every DP-add and DP-join row converges with no orphan tunnel, VPC Service, binding, token, invite or pointer. Q-SEC-6: a grep of argv logs, `r2-calls.log` and captured output finds no token, code or key. Tokens are found by name only (D3); minter key from `SHARE_MINTER_TOKEN` or `minter_token_cmd` (D5). Any TASK-1a answer (SG-01 notes) that differs from the documented shape is folded into the code, and into the Worker if needed.

## Precondition
SG-01 is checked in ROADMAP.md and its notes answer (a), (b) and (c). If not, stop and write the blocker.

## Scope edges
Dry seams only; no live Cloudflare call in this sub-goal.

## Proof
`docs/verification/members-core.md`: suite, restricted-PATH run, each negative control red then green, `## Rollback` (`--no-members`).

## Touches
bin/**
tests/**
docs/implementation-notes/multi-member.md
docs/verification/members-core.md
