# Contributing

Thanks for helping. This page holds the mechanics (branches, commits, tests, the changelog and releases) and the code guidelines. The team rules live in one place: the repo section of [`AGENTS.md`](AGENTS.md). New here? Read [`docs/team/onboarding.md`](docs/team/onboarding.md) first.

## Branches and worktrees

- One worktree per branch, under `.claude/worktrees/<name>`. Do not switch branches in the main checkout.
- Branch names are `<type>/<short-slug>`: type is `feat`, `fix`, `refactor`, `docs`, `test`, `chore`. Two to five kebab-case words.
- A squash merge makes the PR title the commit subject on `main`, so write the title in the commit format below. `bin/release` reads these subjects to pick the version and write the changelog.

## Commits

- Conventional commits: `type(scope): subject`, 72 characters or less. `feat` bumps the minor version, anything else the patch, `!` the major.
- One logical change per commit.
- Write the message to a file and use `git commit -F <file>`.
- No co-author trailer and no "Generated with" line. The author is the person who ran the tool.

## Never stage

- Secrets: tokens, `.env` files, a real config directory, anything from `~/.config/share`.
- Real hostnames, emails or names of people. Docs and tests use `s.example.com` and `a@example.com`.
- `mac/.build/`, `mac/build/`, `demo/.frames/`: build output.
- A snapshot from `tests/prod-snapshot.sh`: it holds account ids and Access app ids.

## Before a PR

Run these tiers (details in `docs/team/testing.md`):

| Change | Run |
|---|---|
| Any change to `bin/handout` or `install.sh` | `/bin/bash -n bin/handout && /bin/bash -n install.sh`, `shellcheck bin/handout install.sh`, then `bash tests/share.sh` |
| A new suite section | `bash tests/ci/shard-check.sh`, and add the section to one shard in `tests/ci/shards.txt` |
| Any change in `mac/` | `swift test --package-path mac` |
| A change to what `state` or `profiles --json` print | also `bash mac/compat-check.sh <last tag>` |
| A change to a Worker rule, setup or teardown | also the live leg that covers it (`tests/e2e*.sh`), by hand |
| Any new or changed flag, verb or `state` key | the full suite: it fails until the docs name it |

The PR body follows `.github/pull_request_template.md`. What a PR carries: [`AGENTS.md`](AGENTS.md#what-a-pr-carries).

Run the suite on its own. It sets its own port base (`SHARE_TEST_PORT_BASE`), so a second run at the same time needs a different one.

## Code guidelines

Each rule describes what the code does today or what a test or an ADR enforces.

### Bash

- `bin/handout` must parse under the macOS system bash (3.2). No empty arrays under `set -u`. No heredoc inside `$( )`: emit it to stdout or a file and read it back.
- A trap cannot read `local` variables after the function returns, so pids a trap must reap are globals.
- A background daemon loop needs a redirect to a log. Without one it inherits the caller's stdout, and an orphaned grandchild holds the caller's pipe.
- `kill` on a subshell leaves its foreground child running. `pkill -P` the subshell first.
- Shellcheck is clean. A disable comment names the code and says why.
- Errors are values with a stable name. A refusal has a snake_case code in `code_table`, a message that names its fix (a command or a URL), and a line in the skill. A renamed or removed code bumps `codes_v`.

### State and multi-step verbs

- A verb that changes Cloudflare state in several steps writes a step journal under `$root/ops/` and prints its rerun and its rollback. A dead run is found by `state`, never by guessing.
- A config writer rewrites only the keys it owns and keeps every other line byte for byte.
- Records the Worker reads carry a version. A record newer than the reader knows blocks the orphan sweep with a warning that names its key, so nothing is deleted on a guess.

### Secrets

- A token comes from an environment variable or a command the user configures (`api-token --cmd`, `admin-token --cmd`). It is stored only in the Keychain or a mode-600 file, never printed, never put on a command line a `ps` can read.
- A log line never holds a token, an invite code or a bucket secret.

### Tests

Tiers and commands: `docs/team/testing.md`. Proof files: `docs/verification/README.md`.

- A behavior gets a check in the suite, next to the section it belongs to. A check names the behavior it pins.
- A Cloudflare call goes through the dry seams (`SHARE_R2_DRY`, `SHARE_ACCESS_DRY`, `SHARE_HOST_DRY`) in the suite. A test never reaches a live account.
- A check that guards a claim comes with a negative control: break a copy on purpose and require the check to go red.
- The suite never touches a real `launchctl`, `systemctl`, Keychain item or `op`. Keep the stubs first on `PATH`.

### Swift (Handout Bar)

- The app reads only through the CLI: `handout profiles --json` and the CLI's own verbs. It never touches `~/share` and never sees a Cloudflare token.
- A change to what the CLI prints must not break an app already shipped. `mac/compat-check.sh <tag>` decodes today's output with the sources of that tag.
- UI states are tested through the model, and shown by `mac/shots.sh` against the fake CLI.

### Comments and names

- A comment says why: the constraint or failure behind the line. Do not restate the code.
- Code may name the spec that holds a contract. It never names an issue or a PR.
- The names kept from the share era stay as they are: [`docs/team/development.md`](docs/team/development.md#names-kept-from-the-share-era).
- No em or en dashes in code, comments or docs ([`AGENTS.md`](AGENTS.md#never)).

## Docs and changelog

- Fix the docs a change makes wrong, in the same PR. The suite reads `README.md`, `docs/setup.md` and `docs/how-it-works.md`.
- `CHANGELOG.md` is generated by `bin/changelog` from the commit subjects. Never edit it by hand.
- Specs, decisions and proof files are dated records. Add to them. Do not rewrite them.

## Releases

Only a maintainer cuts a release. See `docs/team/release.md`.
