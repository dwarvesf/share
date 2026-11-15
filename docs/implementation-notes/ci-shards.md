# Implementation notes: CI shards for the bash suite

Delta from the goal file. Proof: `docs/verification/ci-shards.md`.

| # | Decision | Why |
|---|---|---|
| 1 | Three PR shards, not six: `chain`, `members-a`, `members-b`. | The goal assumed the suite splits into 120 s pieces. The `core`, `r2`, `groundwork` and `late` groups cannot split: `late` pulls the other three, and a run of `r2` alone aborts (`QPATH: unbound variable`, defined in core) while `groundwork` alone hangs at `serve on a busy port` (9 checks in 20 min). Both were run with the pull lines removed in a clone. The chain is about 63 percent of the suite, so more shards add runner minutes and no speed. |
| 2 | The wall time of a PR run is the `chain` shard, not 2 to 3 minutes. | Splitting the chain needs edits to the group lines and sections in `tests/share.sh`, which is outside this goal's files. Recorded as a follow-up with the evidence above. |
| 3 | macOS runs the whole suite on main only. A PR runs a bash 3.2 parse check plus the `members-b` shard on macOS (job `test-macos`). | The goal's own fallback: the macOS chain would outlast the Ubuntu chain. The advisor flagged dropping macOS from PRs (the bash 3.2 rule, the `invite_code` hang); the parse check and one shard keep a macOS signal while finishing before the Ubuntu chain. The `chain` sections still reach macOS only on main. |
| 4 | `shard-check.sh` resolves `# group` and `# pull` the way `sec_init` does, from the live header. | A shard that names one section of a group runs the whole group, so a plain regex match would call a pulled section "uncovered". |
| 5 | Job names change: `test (<shard>)` on PRs, `test-full (<os>)` on main. | The repo has no branch protection, so no required check names break. |
| 6 | `shard-check-test.sh` holds the negative controls. | A new section in no shard, a section in two shards, and a shard naming no section each turn the check red. |
