# Development

Everything technical that the root `README.md` leaves out: how the parts fit, how to run from source, how to test, how CI works, what the repo looks like. For the product and the install, start at the root `README.md`.

## How it works

Four things make it work. `bin/handout` is one bash script (it must parse under macOS `/bin/bash` 3.2). It copies files into `~/share/pub`, writes a Caddyfile, talks to the Cloudflare API, and prints the link. `caddy` serves the tree on localhost. `cloudflared` carries it out through a named tunnel. On an R2 profile a Worker, whose JavaScript `bin/handout` carries inside itself and deploys, serves a private bucket instead. Handout Bar is a Swift menu bar app that only calls the CLI.

```
 your machine                                                       Cloudflare
 +------------------------------------------------+                +--------------------------+
 | bin/handout (bash)                             |  API (curl)    | DNS, tunnel, Access      |
 |   add, setup, member, state ...                | -------------> | R2 bucket, Worker        |
 |   writes ~/share/pub and the Caddyfile         |                |                          |
 |        |                                       |                |                          |
 |        v                                       |   tunnel       |                          |
 |   caddy on 127.0.0.1:<port> <- cloudflared ----|--------------> | s.example.com            |
 |        ^                                       |                +--------------------------+
 |        | JSON: state, profiles --json          |
 | Handout Bar (Swift, mac/)                      |
 +------------------------------------------------+
```

How each part works, with the config keys and the security model: [../how-it-works.md](../how-it-works.md). The UML set: [../SYSTEM-DESIGN.md](../SYSTEM-DESIGN.md).

## Requirements

| Need | For |
|---|---|
| bash 3.2 or newer (macOS `/bin/bash` is the floor) | the CLI and every script |
| `caddy`, `cloudflared`, `jq`, `curl` | running the CLI; the install script pulls them with Homebrew |
| `shellcheck` | lint, the same as CI |
| Node 22 | `tests/worker.mjs`, which drives the real Worker against in-memory bindings |
| Swift 5.9 or newer on macOS 13 or newer | Handout Bar (`mac/Package.swift`) |
| `pandoc`, `gh` | optional: markdown rendering, the private-repo warning; the suite runs its markdown checks only when pandoc is there |
| A Cloudflare account, a zone, an API token | only for the live legs (`tests/e2e*.sh`) and for trying `setup` for real |

## Run from source

```sh
git clone https://github.com/consolelabs/handout.git && cd handout
./install.sh                # symlinks bin/handout into ~/.local/bin, so git pull updates it
bin/handout version         # the CLI version (X.Y.Z)
bin/handout --help          # the verbs
```

Your own installed Handout and a checkout on the same machine share `~/share` and `~/.config/share` unless you say otherwise. To try a change without touching your links, give the run throwaway values, as `demo/env.sh` does: `SHARE_ROOT`, `SHARE_CONFIG_DIR`, `SHARE_PORT` and `SHARE_SERVICE_LABEL`. The test suite does the same and also stubs `launchctl`, `systemctl`, `security` and `op`, so a test run never reaches your login session or your Keychain.

## Names kept from the share era

The tool was `share` before it was Handout. The command, the package and the docs changed. These names did not, because live installs, deployed Workers and invites already sent depend on them. Renaming one strands an install or breaks a link, so each is a one-way door: change it only with a spec, a migration step and the owner's yes.

| Kept | Where it shows | Why |
|---|---|---|
| `~/share`, `~/share/pub`, `~/share/profiles/<p>` | The data root: every snapshot and the index | Links serve from `pub/`; moving it breaks every live link |
| `~/.config/share` | Config, login certificate, token file, `.health` | A profile is its config; a new path means a new setup |
| Every `SHARE_*` variable (`SHARE_ROOT`, `SHARE_CONFIG_DIR`, `SHARE_PROFILE`, `SHARE_MINTER_TOKEN`, `SHARE_R2_MAX_FILES`, ...) | Environment, scripts, CI, the login service | Users and scripts set them |
| Keychain items `share-tunnel*` and `share-api*` | The tunnel token and the API token | A renamed item reads as a missing token |
| Service labels `foundation.d.share*` and the log subsystem `foundation.d.share.bar` | launchd and systemd units, `log stream` | The login service is installed under that label |
| Worker, tunnel, VPC Service and Access app names (`share-<host>`, `share <id> <host> <nonce>`), the bucket marker `share.json`, the `/_share/redeem` route | Cloudflare | Already deployed; the Worker and the CLI match them |
| `X-Share-Deploy`, `X-Share-Worker`, `X-Share-Gate`, `X-Share-Served`, `X-Share-Tunnel` | Response headers | Monitors and the CLI read them |
| `share-invite-id:` in the invite hash, and every refusal code | Sealed invites, `state`, scripts | An invite already sent must still open; codes are a contract |
| `mac/Sources/ShareBar*` | Swift source directories and module names | Source layout only; users never see it |

The `share` command stays a working alias, so `share add` and `share join <host> <code>` keep working.

History of `bin/handout`: `git log --follow` and plain `git blame` stop at the rename commit. Use `git blame -C -C bin/handout` or `git log -- bin/share` to reach the older history.

## Build and release scripts

| Script | Does |
|---|---|
| `install.sh` | Dependencies through Homebrew, then the CLI on `PATH` (a symlink from a clone, a download over curl) |
| `bin/release` | Cut the next release from the commit subjects: tag, changelog, tap formula, cask. Details: [release.md](release.md) |
| `bin/changelog` | Print `CHANGELOG.md` from tag history; never hand-edited |
| `mac/build.sh <version>` | Build the universal app and assemble the bundle (`--sign`, `--notarize` for a release) |
| `mac/release.sh <tag>` | Sign, notarize, upload the zip, bump the cask |
| `mac/compat-check.sh <tag>` | Decode today's CLI output with the sources of a shipped release |
| `mac/shots.sh` | Drive the app against a fake CLI with real clicks and save screenshots |
| `mac/icons.sh <outdir>` | Draw the app icon from code (`mac/Tools/make-icons.swift`) and build `AppIcon.icns` |
| `demo/render.sh` | Re-record the README GIFs ([../../demo/README.md](../../demo/README.md)) |

## Test

Fast loop while iterating on the CLI:

```sh
/bin/bash -n bin/handout && /bin/bash -n install.sh   # the system bash 3.2 must still parse them
shellcheck bin/handout install.sh
SHARE_TEST_ONLY='<regex of section names>' bash tests/share.sh   # only the sections that match
```

Before a PR, run the whole suite once, and `swift test --package-path mac` when you touched `mac/` or the JSON the CLI prints:

```sh
bash tests/share.sh
swift test --package-path mac
```

The suite starts its own server on a spare port (`SHARE_TEST_PORT_BASE`, default 18787) and ends with the line `<n> checks, PASS`. Run two at once only with two different port bases. Tiers and what each one proves: [testing.md](testing.md).

## CI

`.github/workflows/ci.yml` runs on GitHub-hosted runners. This repo is public, so they cost nothing. Never move it to a self-hosted runner: a fork's pull request would run its code on that machine.

| Job | Runs when | Does |
|---|---|---|
| `changes` | every run | Decides which of the jobs below a diff can affect: a `mac/` only change skips the bash suite, a CLI change skips Swift, a workflow edit runs all |
| `lint` | every run | `shellcheck` on the CLI, the installer, the suites, the shard scripts, the demo and `mac/*.sh`; the shard check |
| `test` | a pull request that can affect the CLI | The suite in shards on Ubuntu (the names and section filters are in `tests/ci/shards.txt`) |
| `test-macos` | the same | The bash 3.2 parse check and one shard on macOS |
| `test-full` | a push to `main` | The whole suite on Ubuntu and macOS |
| `mac` | a diff that touches `mac/` | `swift test` and an unsigned build |

A new suite section must join exactly one shard, or `bash tests/ci/shard-check.sh` fails the lint job. `.github/workflows/release.yml` publishes the GitHub release when a `v*` tag is pushed. Lint a workflow change with `actionlint`.

## Project layout

```
bin/handout               The CLI (one bash file), plus bin/release and bin/changelog
install.sh                Dependencies and the symlink or download
mac/                      Handout Bar: Swift package (Sources/ShareBar, Sources/ShareBarCore, Tests), build and release scripts
tests/                    share.sh (the suite), members.sh (sourced by it), worker.mjs, e2e*.sh (live), ci/ (shards)
demo/                     README GIF tapes and the team-guide sample
docs/                     Index at docs/README.md
.github/                  CI workflows, PR template, issue forms
CONTEXT.md                The glossary
CHANGELOG.md              Generated by bin/changelog
```
