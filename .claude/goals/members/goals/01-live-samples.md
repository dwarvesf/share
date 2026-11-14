# SG-01 Live samples on Console Labs (SPEC-009 TASK-1a)
Model: opus
Effort: high
**Branch:** docs/members-live-samples
Design: obvious
Wall budget: 180 min
Port base: n/a (no suite run needed; run shellcheck on any script you commit)

## Done =
Every question of TASK-1a, (a) to (h), is answered in `docs/implementation-notes/multi-member.md` under `## TASK-1a live samples`, each with the exact call shape and a masked excerpt; this closes SPEC-009 OQ-1 to OQ-5 and OQ-7, and also states which call returns what TASK-1f1 needs to find a token by name (D3). A listing by name on Console Labs shows no `share-e2e-` object and no spike leftover (`share-spike-vpc` tunnel, VPC Service and Worker; user token `share-spike-mint`): the owner approved deleting them (D11).

## Scope
- Reuse the spike objects first if they shorten a sample, then delete all of them by name.
- If the admin token lacks Connectivity Directory or Workers scope, mint a throwaway `share-e2e-admin-<8hex>` user token with the minter for the samples, and delete it at the end.
- (e) needs 25 bindings: use 25 throwaway VPC Services on one throwaway tunnel; delete them by name.
- Keep the sample scripts in your scratch dir; describe each call shape in the notes so TASK-4d can reuse it.

## Stop and halt the run if
(a), (b) or (c) fails: write the failure and the design consequence to HANDOFF-SG-01.md and DECISIONS.md, do not flip the box. SG-05 cannot start without these answers.

## Proof
`docs/verification/members-live-samples.md`: `## Recorded run` with one `Command:`/`Exit:`/`Verdict:` block per sample (token masked), plus the final listing-by-name proof of cleanup.

## Touches
docs/implementation-notes/multi-member.md
docs/verification/members-live-samples.md
