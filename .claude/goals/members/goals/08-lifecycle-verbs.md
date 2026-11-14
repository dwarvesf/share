# SG-08 Pause, resume, invite, rotate, renew, adopt, min_cli (SPEC-009 TASK-3a to 3f, 4a)
Model: opus
Effort: high
**Branch:** feat/members-lifecycle
Design: bearing
Wall budget: 480 min
Port base: 30000

## Done =
SPEC-009 TASK-3a to 3f and 4a pass their AC. MB and DP rows green; a rotate of a paused member followed by a re-join ends `paused`. TASK-3f (WebSocket through a binding) runs live on Console Labs with `share-e2e-` names and records its result in the implementation notes on whichever branch it takes; cleanup asserted by name. With `SHARE_ERROR_JSON=1`, `cli_below_min` is the last stderr line's code.

## Proof
`docs/verification/members-lifecycle.md` with suite, negative controls, the 3f live record and `## Rollback`.

## Touches
bin/**
tests/**
docs/implementation-notes/multi-member.md
docs/verification/members-lifecycle.md
