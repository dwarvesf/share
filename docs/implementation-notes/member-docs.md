# Member docs: implementation notes

The delta from SPEC-009 TASK-4c. Kept in its own file so parallel sub-goals editing multi-member.md do not conflict.

Written on main at 7b39971 from the validated specs. Docs only; `tests/` is untouched, because the "tenant docs" grep extension is the live e2e sub-goal's.

- Decision: the six verbs not yet merged (`member pause`, `resume`, `invite`, `rotate`, `renew`, `adopt`) are documented from `### Member status transitions` and the verb paragraphs of `## Technical Design`, and listed in `docs/verification/member-docs.md` so the final doc check re-reads them against the built code.
- Decision: `docs/QUALITY.md` already held 17 entries from the build; this change adds the seven missing ones (Q-SEC-7, Q-REL-4, Q-REL-5, Q-REL-6, Q-COMPAT-3, Q-COMPAT-4, Q-AX-1) so every Q- id of both specs is present. Their Check lines cite the spec's test row ids.
- Decision: `docs/SYSTEM-DESIGN.md` rev C applies the spec's delta table row by row (config `member_mode`, `u/purged.json`, `i/` fields, record `invite` and `rotation`, add and join write order, no hit for v:3, young tombstone rows, rotate). The model builds clean with `lib/system-design/build`; the drawing was not reviewed by eye.
- Decision: ADR-0009 moves to `accepted`; its text is unchanged, because the as-built deltas live here and in `docs/how-it-works.md`.
- Open: join does not print the Connectivity Directory trust note that the spec asks for (`rg` finds no such line in `bin/share`). `docs/setup.md` states the trust limit as an admin note instead of claiming join prints it. Owner: the live e2e sub-goal, or a small CLI change.
- Open: the spec amendments the build owes (LK-09 "before any call" read as before any write; the teardown finding fixed by the `u/` fallback) are not applied to the spec text; SPEC-009 is outside this sub-goal's Touches.
