# SG-07 Revoke, reconcile, rm, purge, leave (SPEC-009 Phase 2)
Model: opus
Effort: high
**Branch:** feat/members-rm-reconcile
Design: bearing
Wall budget: 480 min
Port base: 28500

## Done =
SPEC-009 TASK-2a to 2e pass their AC. RC-01 to RC-15, CC-06 to CC-08, FG and DP-rm rows green; a dry listing of every object kind for the member is empty after `member rm` (Q-SEC-5). A 401 never reads as removal (D4): it sets `token.status` `invalid`; "removed" only from the member's own record. The member serve loop runs under `env -u CLOUDFLARE_API_TOKEN`.

## Proof
`docs/verification/members-rm-reconcile.md` with suite, negative controls red then green.

## Touches
bin/**
tests/**
docs/implementation-notes/multi-member.md
docs/verification/members-rm-reconcile.md
