# Testing

The suite runs on one machine with no credentials. It never reaches a live Cloudflare account, a live server, your Keychain or your login session. The live legs are separate scripts you run by hand.

## Tiers

| Tier | Command | When | Time |
|---|---|---|---|
| Parse and lint | `/bin/bash -n bin/handout`, `shellcheck bin/handout install.sh` | every change | seconds |
| Shard check | `bash tests/ci/shard-check.sh` | a new or renamed suite section | seconds |
| Filtered suite | `SHARE_TEST_ONLY='<regex>' bash tests/share.sh` | while iterating | seconds to minutes |
| Full suite | `bash tests/share.sh` | once before the PR | about 26 minutes in one run; CI shards it |
| Swift unit tests | `swift test --package-path mac` | a change in `mac/`, or in the JSON the CLI prints | minutes |
| Compat check | `bash mac/compat-check.sh <tag>` | a change to `state` or `profiles --json` | minutes |
| App screenshots | `bash mac/shots.sh <scenario> <step file>` | a change to what Handout Bar shows | needs Accessibility for your terminal |
| Live legs | `tests/e2e.sh`, `e2e-r2.sh`, `e2e-tenant.sh`, `e2e-migrate.sh` | by hand, before a release that touches the area | needs a Cloudflare zone and token |

Run the filtered suite while iterating and the full suite once before the PR, never per edit.

## The suite

`tests/share.sh` is one bash file. It sets `SHARE_ROOT`, `SHARE_CONFIG_DIR`, `SHARE_PORT`, `SHARE_TUNNEL=0` and a throwaway `SHARE_SERVICE_LABEL`, puts stubs for `launchctl`, `systemctl`, `security` and `op` first on `PATH`, and at the end checks that no `foundation.d.share*` job appeared in the real launchd or systemd and no `share*` Keychain item changed. `tests/members.sh` is sourced by it and holds the members sections.

- A section is a `section "<name>"` block. A line `skip <name>` means the filter left it out.
- `SHARE_TEST_ONLY` takes an extended regex on section names. A name in a group pulls the whole group, because some sections read the variables an earlier one set.
- `SHARE_TEST_PORT_BASE` moves the port range (default 18787). The highest port a run uses is the base plus 10009.
- A run ends with a timing table and the line `<n> checks, PASS`. A run that dies early prints `ABORTED after <n> check(s)` and exits 2.
- Do not run two suites at once with the same base. A check that no suite server is left over also trips on a second run.
- The Cloudflare calls go to dry seams that answer from fixtures: `SHARE_R2_DRY=1` (the dry account and bucket), `SHARE_ACCESS_DRY=1` (Access), `SHARE_HOST_DRY=1` (DNS and tunnel rules). A test names the calls it expects and the order.
- Docs are tested. The suite greps `README.md`, `docs/setup.md` and `docs/how-it-works.md`: every `state` field, every member verb and flag, and every tenant command must appear in the docs and in the CLI. Rename or drop a documented flag and a row fails, naming it.
- Most rows come with a negative control: the suite breaks a copy on purpose (a doc without a field, a CLI without a flag) and requires the check to go red.

## CI shards

CI splits the suite into shards, one per line of `tests/ci/shards.txt` (a name and a section regex). `bash tests/ci/run-shard.sh <name>` runs one locally with the same filter. `chain` cannot shrink: the core, r2, groundwork and late groups share state, so its time is the floor of a pull request. A new section joins exactly one shard; `bash tests/ci/shard-check.sh` fails when a section runs in none or in two, and `bash tests/ci/shard-check-test.sh` proves it with negative controls. `bash .github/scripts/ci-changes-test.sh .github/workflows/ci.yml` checks the `changes` step against fake diffs (it needs `python3` with `yaml`).

## The Worker

`node tests/worker.mjs` drives the real Worker, emitted from `bin/handout`, against in-memory bindings: path and record refusals, hits, expiry, the Access JWT check, member pointers. The suite runs it in its `worker` section when Node is on `PATH` (in CI a missing Node fails the run). It also builds an older Worker from a pinned commit to prove a new CLI and an old Worker still talk; that row skips when the commit is not fetched.

## Handout Bar

`swift test --package-path mac` runs the unit tests of the core: decoding what the CLI prints, the menu model, the popover state. `mac/compat-check.sh <tag>` builds the core sources of a shipped release and decodes today's CLI output with them, so an app already installed keeps working against a newer CLI. `mac/shots.sh` starts the app against a fake CLI under `mac/Tests/fixtures/bin/`, replays real clicks through the Accessibility API, and saves a light and a dark screenshot. A step file marked `negative` is a negative control the runner expects to fail. Put screenshots a change owes under `docs/verification/`.

## Live legs

These create real Cloudflare resources on throwaway names, prove each step through the API, then tear down and prove nothing is left. CI never runs them: it has no zone or token. Each script's header lists its inputs.

| Script | Proves | Run before a release that touches |
|---|---|---|
| `tests/e2e.sh` | Setup, publish, fetch, remove and teardown on a real zone, with an optional private-link leg | setup, teardown or serving |
| `tests/e2e-r2.sh` | The R2 backend: admin setup, a publisher joining, the Worker's rules, hits, teardown and purge | the R2 backend |
| `tests/e2e-tenant.sh` | One hostname per tenant: R2 on at the origin, members, outage behavior, the alias fold, rollback | `setup --r2`, `--alias`, the tenant Worker |
| `tests/e2e-migrate.sh` | `migrate`: the rollback and a full move with the 530 gap measured | `migrate` |
| `tests/prod-snapshot.sh <out-file> <zone> <host>...` | Nothing: a read-only snapshot of a live tenant's Cloudflare and machine state, taken before a production step so a rollback is exact | a production move |

Use hostnames on a zone you control, the token scopes each header names, and never a hostname that serves real links. A snapshot file holds account ids and Access app ids: keep it out of git.

## What a PR owes

| Change | Run |
|---|---|
| Any CLI change | parse, lint, then the full suite |
| A new suite section | `bash tests/ci/shard-check.sh`, and add the section to one shard |
| A new or changed flag, verb or `state` key | the full suite: the docs rows fail until the docs name it |
| `mac/` | `swift test --package-path mac`, and `bash mac/compat-check.sh <last tag>` when the decoded JSON changed |
| A change to a Worker rule | `node tests/worker.mjs`, then the live leg that covers it before the release |
| A behavior change | a proof file with a negative control under `docs/verification/` ([../verification/README.md](../verification/README.md)) |
