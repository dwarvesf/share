# Console Labs brand scrub: verification

Branch `chore/console-brand-scrub`. Handout is a Console Labs product (https://console.so, repo consolelabs/handout). Docs, code strings, tests and demo no longer name the previous publisher; the brew tap moves to `consolelabs/tap`.

## Green run

| Check | Command | Exit | Verdict |
|---|---|---|---|
| Leftover scan | the `rg` below, minus the keep list | 0 hits outside the keep list | PASS |
| Bash parse | `/bin/bash -n bin/handout` (also `bin/release`, `mac/release.sh`, `tests/e2e-tenant.sh`, `tests/prod-snapshot.sh`) | 0 | PASS |
| Lint | `shellcheck bin/handout install.sh tests/share.sh tests/members.sh tests/e2e.sh tests/ci/*.sh demo/render.sh mac/*.sh` | 0 | PASS |
| Swift | `swift test --package-path mac` | 0 | PASS, `Executed 428 tests, with 0 failures` |
| Access, r2, tenant sections | `SHARE_TEST_PORT_BASE=45000 SHARE_TEST_ONLY='access: a login gate\|r2 backend: admin setup\|r2 backend: join\|tenant: ' bash tests/share.sh` | 0 | PASS, `1303 checks, PASS (filtered by SHARE_TEST_ONLY: 52 sections ran, the rest skipped)` |
| Migrate section | `SHARE_TEST_PORT_BASE=45000 SHARE_TEST_ONLY='migrate: moving' bash tests/share.sh` | 0 | PASS, `1303 checks, PASS (... 52 sections ran ...)` |
| Docs sections | `SHARE_TEST_PORT_BASE=45000 SHARE_TEST_ONLY='tenant docs\|docs' bash tests/share.sh` | 0 | PASS, `598 checks, PASS (... 26 sections ran ...)` |
| Cask dry run | `RELEASE_DRY=1 bash mac/release.sh v0.9.1` | 0 | PASS, prints `url "https://github.com/consolelabs/handout/releases/download/v#{version}/Handout-Bar-#{version}.zip"` and `depends_on formula: "consolelabs/tap/handout"` |

Leftover scan:

```sh
rg --hidden -n -i "dwarves|dwarvesf|d\.foundation|han\.ws|webuild" -g '!.git' -g '!.claude' \
  --glob '!docs/{specs,decisions,implementation-notes,verification,retro,research,briefs}/**' \
  --glob '!CHANGELOG.md' --glob '!LICENSE'
```

Output: only the kept names: kit paths in `AGENTS.md`, `CLAUDE.md`, `WORKFLOW.md`, `.kit.toml`; the Developer ID team and notary profile in `mac/build.sh` and `bin/release`; the copyright line in `mac/Info.plist`.

## Negative control

The same scan on `origin/main` (`git grep -n -i -E "dwarves|dwarvesf|d\.foundation|han\.ws|webuild" origin/main -- . ':!docs/specs' ...`) returns 238 hits in 66 files, so the scan can fail. The swift suite also failed twice on the first pass (derived profile and bucket slugs `s-console-so`, `share-s-d-foundation` still asserted after the hostnames changed), then passed once both sides moved together.

## Not proven

- The brew tap move itself (`consolelabs/homebrew-tap`, `tap_migrations`) is done outside this branch; no `brew` command ran here.
- `bin/release` and the real cask upload were not run; only the dry run of `mac/release.sh`.
- The demo tapes were not recorded; `demo/setup.gif` and `demo/use.gif` still show the old recording.
- Shot scripts and `.steps` fixtures under `mac/Tests/fixtures` were updated by the same rename but not run (they drive a live macOS desktop).
- The full suite was not run; only the sections that read changed lines.
- `tests/prod-snapshot.sh` changed its arguments to `<out-file> <zone> <host>...`; only its usage error path ran.

## Demo re-recorded (recorded run)
Both GIFs were recorded from this branch's `bin/` (`HANDOUT_DEMO_BIN`) against `handout-demo.console.so`, with a real tunnel and DNS record, then torn down.
```
Command: demo/render.sh setup; demo/render.sh use; source demo/env.sh && handout teardown --yes
Exit: 0
Output:
ready:      https://handout-demo.console.so/ is live. Next: handout add <file|dir>
https://handout-demo.console.so/377b02/team-guide/
unpublished 377b02
dns:     deleted handout-demo.console.so
tunnel:  deleted
Verdict: PASS
```
The first `use` recording showed two pandoc 3.14 lines, `[WARNING] Deprecated: --highlight-style`. `bin/handout` now picks `--syntax-highlighting` when pandoc offers it.
```
Command: SHARE_TEST_ONLY='^markdown$' bash tests/share.sh, with the version check forced to the old flag
Exit: 1
Output:
  FAIL  rendering prints no pandoc warning (pandoc 3.8 renamed --highlight-style): expected '0', got '1'
Verdict: PASS (negative control: red on the old flag, ok on the fix)
```
