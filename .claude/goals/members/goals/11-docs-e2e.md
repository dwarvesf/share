# SG-11 Docs and the live e2e suite (SPEC-009 TASK-4c, 4d)
Model: sonnet
Effort: high
**Branch:** docs/members-docs-e2e
Design: obvious
Wall budget: 480 min
Port base: 34500

## Done =
TASK-4c: README, `docs/how-it-works.md`, `docs/setup.md` (member onboarding in one pasted line), `docs/SYSTEM-DESIGN.md` rev C as built, ADR-0009 Status accepted, `CONTEXT.md`, `docs/QUALITY.md` with every Q- entry of both specs; the "tenant docs" grep in `tests/share.sh` covers every member verb, flag and config key. TASK-4d: `tests/e2e-members.sh` refuses any name without the `share-e2e-` prefix and deletes by name in an EXIT trap that prints leftovers; ML-1 to ML-12 green twice in a row on Console Labs, with the member as a second HOME on this Mac with its own cloudflared (as ML-3 allows); a listing by name afterwards is empty.

## Proof
`docs/verification/members-e2e.md` with both runs (`Command:`/`Exit:`/`Verdict:`), the cleanup listing, and the UAT line.

## Touches
README.md
docs/**
CONTEXT.md
tests/e2e-members.sh
tests/share.sh
