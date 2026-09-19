
<!-- kit:adopt -->
## Operating layer (dwarves-kit)

@AGENTS.md

Before touching code, classify the lane: `bash ~/.claude/dwarves-kit/bin/classify lane classify "<task>"`.
A full-lane change records its gates via `~/.claude/dwarves-kit/bin/gate ledger` or the ship-gate blocks the push.
<!-- /kit:adopt -->

`bin/share` must parse under macOS `/bin/bash` (3.2) as well as brew bash: tests restrict `PATH` to hit it. Two constructs have already bitten: no empty arrays under `set -u`, and no heredoc inside `$( )`, emit heredocs to stdout or a file and read them back.
