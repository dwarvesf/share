# Proof of done: member docs (SPEC-009 TASK-4c, without the suite docs grep)

Branch: docs/member-docs, on main at 7b39971.
Notes: docs/implementation-notes/member-docs.md

Docs only. `tests/` is untouched; the "tenant docs" suite grep is the live e2e sub-goal's.

## Doc claims a later check re-reads against the built code

These verbs were not merged when the docs were written. They are documented from SPEC-009 (`### Member status transitions` and the verb paragraphs of `## Technical Design`). All six are built now; the docs grep in `tests/share.sh` ("tenant docs") re-reads every verb, flag and code against `bin/share`, and the "not built yet" wording is removed.

| Verb or claim | Written in | Source |
|---|---|---|
| `member pause`, `resume` | how-it-works members bullet, setup 4i table, README | SPEC-009 MB-10, MB-11, LK-14 |
| `member invite [--port] [--invite-ttl]` | same, plus the join refusal table | MB-09, OT-04 |
| `member rotate` | same | MB-12, MB-26, MB-36 |
| `member renew [--token-ttl]` | same | MB-30, MB-37 |
| `member adopt --token-id` | same | DEC-24 |
| join prints the Connectivity Directory trust note | setup 4i states it as an admin note instead | spec: join says so; `bin/share` does not yet |
| spec amendments owed: LK-09 "before any call"; the teardown finding fixed by the `u/` fallback | not applied (SPEC-009 is outside Touches) | HANDOFF-SG-07 |

## Recorded run

```
Command: python3 -I links.py   (every relative link and #anchor in README.md, docs/how-it-works.md, docs/setup.md, docs/SYSTEM-DESIGN.md, docs/QUALITY.md, CONTEXT.md, ADR-0009, this file, the notes)
Exit:    0
Verdict: PASS (29 links checked, 0 broken)
```

```
Command: bash ~/.claude/dwarves-kit/lib/system-design/build --model docs/SYSTEM-DESIGN.md --base $(git merge-base HEAD origin/main) --out <scratch>/uml.html
Exit:    0
Verdict: PASS (rev C parses and lays out; no warning)
```

```
Command: kit:doc-verifier over the diff (README, setup, how-it-works, SYSTEM-DESIGN, QUALITY, CONTEXT, ADR-0009) against bin/share and SPEC-009
Exit:    0
Verdict: FAIL:fixable on the first pass (4 wrong claims: a missing proof file, QUALITY check ids absent from the suite, the profile_not_empty fix line); all 4 fixed, and the unbuilt verbs marked in README and setup
```

```
Command: kit:advisor (critique) over the frozen diff
Exit:    0
Verdict: 3 major (unbuilt verbs read as built in README and setup; dangling proof-file link), all folded; glossary (14 SPEC-009 + 8 SPEC-010 terms) and QUALITY (24 Q- ids) complete
```

Completeness counts, run after the fixes:

```
Command: rg -c "^- ID: .Q-" docs/QUALITY.md ; rg -c "^- \`" CONTEXT.md
Exit:    0
Verdict: PASS (24 quality entries, the count both specs list; 26 glossary lines, which include all 14 SPEC-009 terms and all 8 SPEC-010 terms)
```

```
Command: git diff origin/main -U0 | rg "^\+" | rg -c "—|–"
Exit:    1 (no match)
Verdict: PASS (no em or en dash added)
```
