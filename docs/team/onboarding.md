# Onboarding

Product context, status and direction: start with [HANDOVER.md](HANDOVER.md).

For a new engineer. This page gets you from a fresh clone to green tests in about an hour. Deep detail lives in the pages it links. The last sections list what to learn and the tooling to install.

## Prerequisites

Install these, then run each check. Every command should succeed.

| Tool | Why | Check |
|---|---|---|
| bash 3.2 or newer | The CLI must parse under the macOS system bash (3.2) as well as a newer one | `/bin/bash --version` on macOS; `bash --version` elsewhere |
| `caddy`, `cloudflared`, `jq`, `curl` | The CLI serves with caddy, publishes with cloudflared, reads JSON with jq. `brew install caddy cloudflared jq` | `caddy version`, `cloudflared --version`, `jq --version`, `curl --version` |
| `shellcheck` | Lint, the same as CI | `shellcheck --version` |
| Node 22 | `tests/worker.mjs`, which the suite runs. CI fails a run with no Node | `node --version` |
| Swift 5.9 or newer, macOS 13 or newer | Handout Bar (`mac/`). Skip it if you only touch the CLI | `swift --version` |
| `pandoc`, `gh` | Optional. Without pandoc the suite skips its markdown checks. `gh` opens PRs | `pandoc --version`, `gh --version` |

## First hour

Run these from the repo root on a fresh clone. Each one exits 0. If a port is busy, set `SHARE_TEST_PORT_BASE=<port>` before `bash tests/share.sh`.

```sh
/bin/bash -n bin/handout && /bin/bash -n install.sh
shellcheck bin/handout install.sh
bash tests/ci/shard-check.sh
bin/handout version
bash tests/share.sh
swift test --package-path mac
```

What you should see:

| Command | Output |
|---|---|
| `bash tests/ci/shard-check.sh` | `shard-check: <n> sections, <n> shards, each section in exactly one`, exit 0 |
| `bin/handout version` | `0.9.0` (the number moves with each release) |
| `bash tests/share.sh` | ends with `<n> checks, PASS`; the full run takes about half an hour on one Mac and starts its own server on a spare port. For a quick loop, run one filtered section: `SHARE_TEST_ONLY=docs bash tests/share.sh` ends with `<n> checks, PASS (filtered by SHARE_TEST_ONLY: <n> sections ran, the rest skipped)` |
| `swift test --package-path mac` | a last line shaped `Executed <n> tests, with 0 failures`; the first build takes a few minutes |

The suite is isolated: it sets its own root, config directory, port and service label, and stubs `launchctl`, `systemctl`, `security` and `op`. It never touches the links or the Keychain of a Handout you already run on the same machine.

## Before your first PR

Read [`CONTRIBUTING.md`](../../CONTRIBUTING.md): the mechanics and the code guidelines. Then run the parse, lint and suite commands above before every push.

## Architecture map

One CLI and one app. The CLI has two ways to serve links. Pick the one you need.

```
 Path 1: tunnel profile (the default; your machine serves)

 visitor --> Cloudflare edge --> tunnel --> cloudflared --> caddy --> ~/share/pub
                                            (login service)   bin/handout

 Path 2: r2 profile and the tenant's cloud links (your machine can be off)

 visitor --> Cloudflare edge --> Worker (JS carried in bin/handout) --> private R2 bucket
                                  |
                                  +--> members' machines, through a Workers VPC binding
```

| Component | Where | What it does |
|---|---|---|
| CLI | `bin/handout` | One bash file: setup, add, serve, access, R2, members, state, prune. It carries the Worker source it deploys |
| Installer | `install.sh` | Dependencies and the symlink or download |
| Handout Bar | `mac/Sources/ShareBar`, `mac/Sources/ShareBarCore` | Swift menu bar app; reads `handout profiles --json` and acts through the CLI's own verbs |
| Suite | `tests/share.sh`, `tests/members.sh`, `tests/worker.mjs` | Local self-test; CI splits it into shards (`tests/ci/`) |
| Live legs | `tests/e2e*.sh` | Run by hand against a real Cloudflare zone |
| Release | `bin/release`, `bin/changelog`, `mac/release.sh` | Version, tag, tap formula, cask |

More: [development.md](development.md) (how the parts fit), [../how-it-works.md](../how-it-works.md) (config keys, security model, the Worker, members), [../SYSTEM-DESIGN.md](../SYSTEM-DESIGN.md), [../../CONTEXT.md](../../CONTEXT.md) (the glossary).

## Which tests for which change

The table in [testing.md](testing.md), section "What a PR owes", lists them. The short form:

| Change | Run |
|---|---|
| Anything in `bin/handout` | parse, lint, then `bash tests/share.sh` |
| A new suite section | `bash tests/ci/shard-check.sh`, and add the section to one shard |
| Anything in `mac/` | `swift test --package-path mac` |
| A documented flag, verb or `state` key | `bash tests/share.sh`: the docs rows fail until the docs name it |

The suite checks that `README.md`, `docs/setup.md` and `docs/how-it-works.md` name every member verb and every `state` field. A change that adds a flag adds its doc line in the same PR.

## Running your own stack

The suite needs no account. To try a change against Cloudflare you need your own:

- **No domain:** `bin/handout --profile dev setup --quick` serves at a random `trycloudflare.com` URL. It needs no login, no token and no DNS.
- **A domain on Cloudflare:** an API token with the scopes in [../setup.md](../setup.md), section 1, then `CLOUDFLARE_API_TOKEN=... bin/handout --profile dev setup dev.example.com`. Use a hostname nobody else uses, and a named profile, so a setup you already run is never touched.
- **R2, members, private links:** [../setup.md](../setup.md), sections 4e to 4i.

Never test on a hostname that serves real links. The live legs (`tests/e2e*.sh`) ask for a hostname whose first label starts with `share-e2e` and tear it down.

Keep tokens out of git and out of prompts. Handout reads them from an environment variable or from a command you configure (`api-token --cmd`, `admin-token --cmd`), and stores a token only in the Keychain or a mode-600 file.

## Where work lives

GitHub Issues are the work queue: `gh issue list --assignee @me --label ready --state open` lists yours, and assigning yourself is the claim. The Task form ([`.github/ISSUE_TEMPLATE/task.yml`](../../.github/ISSUE_TEMPLATE/task.yml)) gives the shape: Goal, Done when, Scope. Larger work starts as a spec in `docs/specs/` and a decision in `docs/decisions/`; the rules are in [`AGENTS.md`](../../AGENTS.md), section "This repo: team rules for agents".

## What to learn

What each teammate should be able to do, where to learn it, and how to show it. It is a floor, not a course.

| Skill | Why it matters here | Learn it from | Proof you have it |
|---|---|---|---|
| Brief an agent: goal, done check, stop condition, scope fence | An agent with no done check stops early or never. A fence keeps it away from the names that live installs depend on | The Task form, [Names kept from the share era](development.md#names-kept-from-the-share-era) | Write a brief for a small issue. It names the files the agent may touch, one command that proves done, and when to stop |
| Verify agent output | The agent says "done" before it is. You are the check | [testing.md](testing.md), [`../verification/README.md`](../verification/README.md) | Take one agent PR. Run its command yourself, read the diff, break the code on purpose and show the test go red |
| bash 3.2 discipline | The CLI runs under the macOS system bash | [`CLAUDE.md`](../../CLAUDE.md): no empty arrays under `set -u`, no heredoc inside `$( )` | Run `/bin/bash -n bin/handout` after each edit |
| Process lifecycle in bash | Serve starts background daemons; a trap or a pipe that holds on strands a caller | [`CLAUDE.md`](../../CLAUDE.md), the traps that bit once each | Explain why a daemon loop needs a redirect to a log |
| The Cloudflare model | Tunnel, DNS, Access, R2, Workers, Workers VPC: each has its own token scope and its own failure | [../how-it-works.md](../how-it-works.md), [../setup.md](../setup.md) | Draw the path of one link on a tunnel profile and on an r2 profile |
| Step journals and refusal codes | Multi-step verbs can die half-way; every refusal names its next command | [../../CONTEXT.md](../../CONTEXT.md) (`step journal`, `code`, `serve phase`) | Let a dry multi-step run die half-way, then find its `rerun` in `state.ops` |
| Secrets hygiene | A token in a prompt or a commit is a leak | [Running your own stack](#running-your-own-stack) | Run `git status` before each commit and see no key file staged |
| Know when to stop and get a second person | A renamed Keychain item or Worker route strands a live install | [One-way doors in `AGENTS.md`](../../AGENTS.md#one-way-doors) | Given three sample changes, sort them into reversible and one-way |
| Write a demo | A PR is its own proposal | [`../../demo/README.md`](../../demo/README.md) | Record a 30 second GIF or paste command output of your feature running |

Pick one more skill each week and do its exercise. The exercises are for you. Nobody grades them.

## Tooling

| Tool | Purpose | Status | Setup |
|---|---|---|---|
| Claude Code or another coding agent | Builds the change | Install yourself | Read [`AGENTS.md`](../../AGENTS.md) first |
| dwarves-kit plugin | Extra gates (proof of done, lane gates) that read `.kit.toml` | Optional | The repo's own rules sit in `AGENTS.md`; the kit adds checks, nothing here needs it |
| `gh` CLI | PRs, issues, merges | Install yourself | `gh auth login` with access to this repo |
| `shellcheck` | Lint, as CI | Install yourself | [Prerequisites](#prerequisites) |
| Swift toolchain | Handout Bar | Install yourself | [Prerequisites](#prerequisites) |
| `vhs`, `ffmpeg` | Re-record the README GIFs | Optional | [`../../demo/README.md`](../../demo/README.md) |
| PR template, issue forms | The PR sections; the Task and Bug shapes | In repo | `.github/pull_request_template.md`, `.github/ISSUE_TEMPLATE/`. Nothing to set up |
| CI | Lint, the suite in shards, the Swift tests | In repo | `.github/workflows/ci.yml`; see [development.md](development.md#ci) |
