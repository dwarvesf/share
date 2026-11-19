
<!-- kit:adopt -->
## Operating layer (dwarves-kit)

@AGENTS.md

Before touching code, classify the lane: `bash ~/.claude/dwarves-kit/bin/classify lane classify "<task>"`.
A full-lane change records its gates via `~/.claude/dwarves-kit/bin/gate ledger` or the ship-gate blocks the push.
<!-- /kit:adopt -->

`bin/handout` must parse under macOS `/bin/bash` (3.2) as well as brew bash: tests restrict `PATH` to hit it. Two constructs have already bitten: no empty arrays under `set -u`, and no heredoc inside `$( )`, emit heredocs to stdout or a file and read them back.

Process lifecycle traps that bit once each: an EXIT trap cannot read `local` vars after the function returns normally (pids the trap reaps must be globals); a background daemon loop with no redirect inherits serve's stdout and an orphaned grandchild then pins a caller's `$( )` pipe (redirect it to a log); `kill` on a subshell leaves its foreground child orphaned, so `pkill -P` the subshell first; a `( )` one level further down is out of `pkill -P`'s reach, so run it as a job and `wait` on it under a TERM trap that kills and reaps it (`set +u` first: bash 3.2 errors on an unset `$!`).

Commits carry no co-author trailers and no "Generated with" lines, whatever tool wrote them. The author is the operator; agent tooling stays invisible in git history.
