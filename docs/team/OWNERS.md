# Owners

## Rule

- Every script, workflow and scheduled or deployed job has one owner.
- An owner is a person, named here. The owner keeps it working, reviews changes to it, and retires it.
- A PR that adds a script, a workflow or a job adds its row in the same PR. The reviewer checks it.
- Claiming ownership is editing the row in a PR. No row is empty: a path with no owner is nobody's problem until it breaks.
- Every owner is `Han` for now. Handing a row to a teammate is a one-line PR.

## CLI and installer

| Path | What it does | Owner |
|---|---|---|
| `bin/handout` | The CLI: setup, add, serve, access, R2, members, state, the Worker source it deploys | Han |
| `bin/share` | A symlink to `bin/handout`: the `share` alias that existing installs keep calling | Han |
| `bin/release` | Cut the next release: version from commit subjects, changelog, tag, tap formula, cask | Han |
| `bin/changelog` | Print `CHANGELOG.md` from tag history | Han |
| `install.sh` | Install dependencies and put the CLI on `PATH` (a symlink from a clone, a download over curl) | Han |

## Tests

| Path | What it does | Owner |
|---|---|---|
| `tests/share.sh` | The self-test suite: every behavior except the live Cloudflare legs, isolated by `SHARE_ROOT` and `SHARE_CONFIG_DIR` | Han |
| `tests/members.sh` | The members sections, sourced by `tests/share.sh` | Han |
| `tests/worker.mjs` | Drive the real Worker against in-memory bindings | Han |
| `tests/e2e.sh` | Live leg: setup, publish, fetch, remove and teardown on a real zone | Han |
| `tests/e2e-r2.sh` | Live leg: the R2 backend, a publisher joining, teardown and purge | Han |
| `tests/e2e-tenant.sh` | Live leg: one hostname per tenant, members, the alias fold | Han |
| `tests/e2e-migrate.sh` | Live leg: `migrate`, its rollback and a full move | Han |
| `tests/prod-snapshot.sh` | Read-only snapshot of a live tenant's Cloudflare and machine state before a production step | Han |
| `tests/ci/shards.txt` | The CI shards: a name and a section regex per line | Han |
| `tests/ci/run-shard.sh` | Run one CI shard locally | Han |
| `tests/ci/shard-check.sh` | Fail when a suite section runs in no shard or in two | Han |
| `tests/ci/shard-check-test.sh` | Negative controls for the shard check | Han |
| `.github/scripts/ci-changes-test.sh` | Run the `changes` step of CI against fake diffs | Han |

## Handout Bar

| Path | What it does | Owner |
|---|---|---|
| `mac/build.sh` | Build the universal app, assemble the bundle, sign and notarize on request | Han |
| `mac/release.sh` | Sign, notarize, upload the zip to the release, bump the cask | Han |
| `mac/compat-check.sh` | Decode today's CLI output with the sources of a shipped release | Han |
| `mac/shots.sh` | Drive the app against a fake CLI with real clicks and save light and dark screenshots | Han |
| `mac/icons.sh` | Draw the app icon from code and build `AppIcon.icns` | Han |
| `mac/Tools/make-icons.swift` | The icon drawing program that `mac/icons.sh` compiles | Han |
| `mac/Tests/fixtures/bin/` | The fake CLI the screenshot scripts answer from | Han |
| `mac/Tests/fixtures/ax/axdrive.swift` | The Accessibility driver: real clicks and key presses | Han |
| `mac/Tests/fixtures/popover/run-shots.sh` | The popover screenshot run: step files through `mac/shots.sh` | Han |
| `mac/Tests/fixtures/popover/parity-sample.swift` | The color sampler for the popover design parity check | Han |
| `mac/Tests/fixtures/popover/popover-b-sample.swift` | The color sampler for the popover B parity check | Han |
| `mac/Tests/fixtures/settings/parity/sample.swift` | The color sampler for the Settings parity check | Han |
| `mac/Tests/fixtures/popover/parity-shots.sh` | Render the popover through the app's debug hook for the design parity check | Han |
| `mac/Tests/fixtures/popover/popover-b-shots.sh` | Render the popover B screens through the debug hook, light and dark | Han |
| `mac/Tests/fixtures/popover/popover-b-parity.sh` | Compare the popover B screens with the design page, sampled in sRGB | Han |
| `mac/Tests/fixtures/popover/status-item-check.sh` | Check the status item and its dot through the Accessibility tree | Han |
| `mac/Tests/fixtures/settings/run-shots.sh` | The Settings screens screenshot run | Han |
| `mac/Tests/fixtures/settings/parity/render-reference.sh` | Render the design page headless, one image per screen and appearance | Han |
| `mac/Tests/fixtures/settings/parity/compare.sh` | Build side-by-side sheets of a capture and its reference | Han |
| `mac/Tests/fixtures/states/states-shots.sh` | Render the state screens through the debug hook | Han |

## Demo

| Path | What it does | Owner |
|---|---|---|
| `demo/render.sh` | Record a tape with vhs and build the GIF with ffmpeg | Han |
| `demo/env.sh` | The hidden prelude of every tape: its own config, root, port and service label | Han |
| `demo/setup.tape` | The install and setup story | Han |
| `demo/use.tape` | The hand out, visit, count and take-down story | Han |
| `demo/README.md` | How to re-record the demo | Han |
| `demo/.gitignore` | Keeps the frames that vhs captures out of git | Han |
| `demo/setup.gif` | The recorded setup story, shown in the root README | Han |
| `demo/use.gif` | The recorded use story, shown in the root README | Han |
| `demo/visitor.png` | What a visitor sees on a folder link | Han |
| `demo/team-guide/README.md` | The sample folder the use tape hands out | Han |
| `demo/team-guide/checklist.md` | A second file in the sample folder | Han |
| `demo/team-guide/img/flow.svg` | The image the sample folder's README shows | Han |

## Workflows and jobs

| Name | Where it runs | Trigger | Owner |
|---|---|---|---|
| CI (`.github/workflows/ci.yml`) | GitHub-hosted runners; the repo is public | Each pull request and each push to `main` | Han |
| CI job `changes` | A job in `ci.yml` | Every run | Han |
| CI job `lint` | A job in `ci.yml` | Every run | Han |
| CI jobs `test`, `test-macos` | Jobs in `ci.yml` | A pull request that can affect the CLI | Han |
| CI job `test-full` | A job in `ci.yml` | A push to `main` | Han |
| CI job `mac` | A job in `ci.yml` | A diff that touches `mac/` | Han |
| Release (`.github/workflows/release.yml`) | GitHub-hosted runner | A pushed `v*` tag | Han |
| Homebrew formula and cask | The `consolelabs/homebrew-tap` tap, bumped by `bin/release` and `mac/release.sh` | Each release | Han |
