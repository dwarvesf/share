# SG-04 State groundwork, should, bash (SPEC-010 G6 G7 G8 G9 G10 G14)
Model: sonnet
Effort: high
**Branch:** feat/state-groundwork-should
Design: bearing
Wall budget: 420 min
Port base: 24000

## Done =
SPEC-010 G6, G7, G8, G9, G10 and G14 pass their AC: SS, LS, PS, AD, TK and CG rows green; for each serve-phase fixture `jq '[.state,.ready]'` equals HEAD's output; the three `state writes nothing` checks stay green with `.health` present and absent; `.health` is one file updated per top-level key with `jq`, tmp + `mv -f`, so SPEC-009 can add a `members` key; SPEC-009 TASK-0c's G7 fallback (from SG-03) is replaced by the real `link_state`.

## Scope edges
No Swift (G11a to G11c are SG-06). G12 stays out (D7).

## Proof
`docs/verification/state-groundwork-should.md` with the suite run and negative controls.

## Touches
bin/**
tests/**
docs/implementation-notes/state-groundwork.md
docs/verification/state-groundwork-should.md
