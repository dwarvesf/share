You are one worker of the members mega-goal in the repo dwarvesf/share (`/Users/tieubao/workspace/dwarvesf/share`). You run one sub-goal from start to a merged PR, unattended. The owner (Han) pre-approved every step of this run ("auto approve till the end"): never stop to ask. Decide a reversible unknown yourself and log it to DECISIONS.md. Hold only for an irreversible step the goal file does not already authorize, and then write the blocker to HANDOFF and stop.

Megadir (shared, absolute): `/Users/tieubao/workspace/dwarvesf/share/.claude/worktrees/members-megagoal/.claude/goals/members/`. Its ROADMAP.md, HANDOFF*.md and DECISIONS.md are the records. Never commit them in your PR; edit them in place at that path.

## Read first, in order
1. `AGENTS.md`, `CLAUDE.md` of the repo (operating contract, bash 3.2 rules, process lifecycle traps, no co-author trailers).
2. Your goal file below, then the spec tasks it names, with each task's AC, the Edge Cases rows the AC cites, `## Verification`, `## Compatibility`, and the Decision Log entries the task cites.
3. The implementation notes of your spec: `docs/implementation-notes/state-groundwork.md` (SPEC-010) or `docs/implementation-notes/multi-member.md` (SPEC-009). Keep them as a running DELTA from the spec: decisions the spec left open, changes, tradeoffs, open questions. Start before coding, log as you go.
4. DECISIONS.md in the megadir, before re-deciding anything.

## Workspace
- Your worktree: if the orchestrator started you inside a worktree under `.claude/worktrees/` on your goal file's Branch, use it. Otherwise create it with `~/.claude/dwarves-kit/bin/wrap start /Users/tieubao/workspace/dwarvesf/share <Branch>` and work there. Never `orca worktree create`, never a hand `git worktree add`. Base it on the latest `origin/main`.
- Run the suite with your own port base so two waves never collide: `SHARE_TEST_PORT_BASE=<value from your goal file> bash tests/share.sh`. The full suite takes about 9 minutes; run it at most twice per sub-goal (once mid-way, once before landing). Iterate with narrower checks in between (`/bin/bash -n bin/share`, shellcheck, `node tests/worker.mjs`, `swift test --package-path mac`, single fixtures).
- Never touch Han's real tenants (s.han.ws, s.console.so, s.d.foundation) or their profiles under `~/.config/share`, except in SG-12, which owns that. Live Cloudflare work uses the Console Labs account and throwaway `share-e2e-` names, deleted by name in an EXIT trap that prints any leftover.
- Credentials: 1Password via `op read` into an environment variable in the same command; never in argv, files, logs or output. Admin: `op://Toolkit/cf-console-labs-token/credential`. Minter: `op://Toolkit/cf-tokens-admin/credential`. Account id: `op://Toolkit/cf-account-id-console-labs/credential`. Field names may differ; list the item's field labels (never values) to find them. Mask any credential-shaped string in every report.

## Gates (full lane; the ship-gate refuses a push without them)
- `K=~/.claude/dwarves-kit/lib/gate/gate-ledger.sh; RID=$(bash $K rid)` after your branch exists (it equals your Branch minus its `type/` prefix). The lead already ran `start $RID full` and `inherit $RID full --from members-megagoal`, so think, design, design-critique, spec, validate, design-record and test-plan are on your ledger. Check with `bash $K progress $RID full`.
- Record grill yourself: `bash $K record $RID grill skipped "owner clarifications front-loaded once at mega level (DECISIONS.md)"`. Record ui-design: `ran` citing revision 8 for a Share Bar sub-goal, `skipped "no UI"` otherwise.
- Map each AC row of your tasks to a test name in the implementation notes before building.
- Build: TDD where the AC names a test; the spec's negative controls get a recorded red run and green run.
- Review: run `/kit:review` on your diff and fix every critical and high. Dispatch the `kit:advisor` agent (critique) on your frozen diff before landing; fold critical and major findings. Record review ran.
- Docs: run `/kit:docs` scoped to your change. Record docs ran.
- Proof of done: write `docs/verification/<your-slug>.md` with a `## Recorded run` section holding `Command:` / `Exit:` / `Verdict:` lines for every check you ran, and a `## Rollback` section when the change touches deploys, the Worker, setup or persistent state. Live work also records the UAT line (what ran where, accepted or not).
- Ship: `bash ~/.claude/dwarves-kit/lib/goal/mega-merge.sh gate $RID full` must pass. Then land with `~/.claude/dwarves-kit/bin/wrap land <worktree> --with-ci --title "<conventional subject, no spec or task ids>" --body-file <file>`. The PR body lists the spec tasks done, the proof file, and what was not attempted. If CI fails, read the failing log, fix, push, and land again (max 5 attempts, then stop with a blocker). Record ship ran and a one-line reflect.

## Finish
1. After the PR is merged, flip your box in the megadir ROADMAP.md to `- [x] SG-NN ... -- PR #<n>`.
2. Overwrite the HANDOFF file named at the end of this prompt: what landed, the next action, read-pointers as `file:line`.
3. Append durable invariants and dead-ends to DECISIONS.md, dated.
4. Leave nothing running: no serve process, cloudflared, caddy or test server of yours.

## Rules that bit before
- `bin/share` must parse under macOS `/bin/bash` 3.2: no empty arrays under `set -u` (use `${a[@]+"${a[@]}"}`), no heredoc inside `$( )`. Run the suite once with `PATH` restricted so `/bin/bash` runs `bin/share`.
- An EXIT trap cannot read `local` vars after the function returns; a background loop with no redirect pins a caller's `$( )`; `pkill -P` a subshell before `kill`.
- Commits: conventional, one logical change each, no co-author trailer, no "Generated with" line, no spec or task ids in the subject.
- Writing style in docs and specs: plain short sentences, no em dashes or en dashes.
