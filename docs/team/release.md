# Releasing

One command cuts a release: `bin/release`, from a clean, synced `main`. It works out the version, writes the changelog, tags, publishes the GitHub release through CI, bumps the Homebrew formula, and builds, signs and notarizes Handout Bar for the cask. Only a maintainer runs it.

```sh
git switch main && git pull --ff-only
bin/release          # shows the version and the commits, asks y/N
bin/release --yes    # no prompt
```

## Versioning

SemVer, `MAJOR.MINOR.PATCH`, computed from the conventional-commit subjects since the last tag.

| Subjects since the last tag | Bump |
|---|---|
| any `type!:` or `BREAKING` | major |
| any `feat:` or `feat(scope):`, no breaking | minor |
| anything else (`fix`, `perf`, `refactor`, `revert`, `docs`, `test`, `chore`) | patch |
| none | the script refuses |

The version lives in `bin/handout` as `SHARE_VERSION` (the variable name is one of the [names kept from the share era](development.md#names-kept-from-the-share-era)). The release commit rewrites it, and the suite checks it against the newest heading of `CHANGELOG.md`. A tag is `v<MAJOR.MINOR.PATCH>`. Write commit subjects for the changelog: `feat(scope): what a user gets`, 72 characters or less.

## What the script does

| Step | What happens | Stops when |
|---|---|---|
| 1. Preflight | On `main`, clean tree, equal to `origin/main`, at least one tag, at least one commit since it | Any of these fails |
| 2. Confirm | Prints `<last tag> -> <next tag>` and the subjects; asks unless `--yes` | You answer anything but y |
| 3. Changelog | `bin/changelog --next <tag>` regenerates `CHANGELOG.md`, `SHARE_VERSION` is set, one commit `docs: changelog for <tag>` is pushed to `main` | `SHARE_VERSION` cannot be set |
| 4. Tag | Annotated tag on that commit, pushed. The `Release` workflow (`.github/workflows/release.yml`) publishes the GitHub release with generated notes | |
| 5. Formula | Fetches the tag tarball, computes its sha256, edits `url` and `sha256` of the formula in `dwarvesf/homebrew-tools` through a throwaway clone, opens a PR and squash-merges it | The tarball cannot be fetched |
| 6. Cask | On a Mac that holds the Developer ID identity, runs `mac/release.sh <tag>`. Elsewhere it prints `CASK NOT RELEASED: run mac/release.sh <tag> on a signing Mac` and exits 3 | The identity is missing (the formula still shipped) |

Step 3 is the one direct push to `main` the repo allows. Every other change goes through a pull request.

## Handout Bar

`mac/release.sh <tag>` signs and notarizes the app through `mac/build.sh`, uploads the zip to the tag's GitHub release, then bumps the cask in the tap and adds a caveats line to the formula, each through a throwaway tap clone and a PR. It is idempotent: a rerun for the same tag updates an open cask PR, and a merged cask for the tag is a no-op. A notarization failure prints the notary log, skips the upload and the cask, and exits non-zero.

| Setting | What it is |
|---|---|
| `TEAM_ID`, `SIGN_ID` | The Developer ID Application identity `mac/build.sh` signs with, read from your login keychain |
| `NOTARY_PROFILE` | A `notarytool` keychain profile |
| `NOTARY_KEY`, `NOTARY_KEY_ID`, `NOTARY_ISSUER` | An App Store Connect API key, used instead of the profile when all three are set |
| `NOTARY_KEY_OP` | An `op://` reference that `mac/release.sh` reads into a mode-600 temp file for unattended runs |
| `RELEASE_DRY=1` | Skip the build, the upload and every tap write; print the cask and the upload command |

The defaults for the identity and profile belong to the maintainer. Override them to release under another identity. The keys stay in the maintainer's password manager and never enter the repo.

## If it stops

| Where it stopped | What to do |
|---|---|
| Steps 1 and 2 | Fix the cause and run again. Nothing changed. |
| After step 3, before the tag | The changelog commit is on `main`. Tag it by hand: `git tag -a <tag> -m <tag>` and `git push origin <tag>`, then do steps 5 and 6 by hand. |
| After step 4 | The release exists. Fix the tap by hand: edit the formula `url` and `sha256` in a PR to `dwarvesf/homebrew-tools`, then run step 6. |
| Step 6, no identity | Run `mac/release.sh <tag>` on the signing Mac. |
| Step 6, notarization failed | Read the notary log it printed, fix, rerun `mac/release.sh <tag>`. |

A wrong release is fixed with a new patch release. Do not move or delete a tag that was pushed.

## What works with what

| Part | Version | How it ships | Compatibility |
|---|---|---|---|
| CLI (`bin/handout`) | `SHARE_VERSION`, one number for the repo | The tag, the tap formula, `install.sh` from `main` | `state` keeps `schema: 1`; a renamed or removed refusal code bumps `codes_v`, never `schema` |
| Handout Bar | The tag it was built for | The cask, a notarized zip on the GitHub release | It reads the CLI only. `mac/compat-check.sh <tag>` proves a shipped app still decodes today's CLI output |
| Worker (R2 profiles and tenants) | A version and sha, shown by `/healthz` as `X-Share-Worker` | Deployed by whoever holds the admin token, with `handout setup` | After a release that changes the Worker, the admin reruns the same `setup`; publishers see a line when the deployed Worker differs from their CLI |
| Members | `min_cli` in the bucket marker, written when the admin turns members on | `handout setup <host> --r2 --bucket <name> --members` | A CLI older than `min_cli` still reads but refuses any write with `cli_below_min`; `member rm`, `purge` and `leave` are exempt |

**Rule: the formula bump and the Handout Bar cask ship in the same release.** The old Share Bar app does not read the new CLI's `handout:` prefix or the `handout join` invite line. A formula bump without the cask leaves cask users on a menu bar app that cannot read the CLI. If step 6 stops (no signing identity), finish `mac/release.sh <tag>` before you announce the release.

There is no central Worker to deploy. Every tenant's admin runs the Worker in their own Cloudflare account.

## Homebrew names and migration

The tap `dwarvesf/homebrew-tools` is settled. It holds `Formula/handout.rb`, which installs `handout` and a `share` symlink (on the v0.9.0 tarball it installs `bin/share` as `handout`), and `Casks/handout-bar.rb`. `formula_renames.json` maps `share` to `handout` and `cask_renames.json` maps `share-bar` to `handout-bar`, so an existing install moves on `brew update`.

Homebrew refuses formulae from an untrusted tap, and trust is per name. A new user runs `brew trust dwarvesf/tools`, then `brew install dwarvesf/tools/handout` (cask: `brew install --cask dwarvesf/tools/handout-bar`). A user upgrading from `share` runs:

```sh
brew trust --formula dwarvesf/tools/handout && brew trust --cask dwarvesf/tools/handout-bar && brew migrate share && brew reinstall handout
```

`brew migrate` moves the keg. The reinstall adds the `handout` command. `share` keeps working throughout and login services are unaffected.

## Open

- The licence is MIT today. Paid layers may need a change: [../product/DIRECTION.md](../product/DIRECTION.md), Open decisions.
