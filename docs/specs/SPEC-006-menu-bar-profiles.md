# Spec: Share Bar sees every profile and adds gated shares

Generated: 2026-09-30
Status: DRAFT
Lane: full (a new CLI JSON contract the app depends on; an authz choice made in the UI)
References: `docs/specs/SPEC-003-menu-bar.md` (the app, `share state`, header and row rules); `docs/specs/SPEC-005-profiles.md` (`--profile`, `share profiles`, the overrides `profiles` unsets); `docs/specs/SPEC-004-access.md` (`--access` grammar, the O1/O3 guided messages, the gate wait); `docs/decisions/ADR-0003-menu-bar-reads-through-cli.md`.
Supersedes: SPEC-005 `## Failure modes` row "a named profile's outage: none from Share Bar (it watches the default only)" and SPEC-005 `## Out of scope` item "Share Bar reading a named profile". After this spec ships, Share Bar watches every profile.

## Problem

Share Bar runs `share state` with no profile, so it shows the default profile only. On the Mini the default is not set up and the live setup is the `dfoundation` profile at `s.d.foundation`. The app there shows "Not set up" with a slashed icon while `s.d.foundation` serves, and it cannot add, list, or remove a `dfoundation` share. It also cannot add a login-gated share: `--access` (SPEC-004) exists only on the command line. A `dfoundation` outage is invisible unless the operator runs `share profiles`.

## Solution

### Approaches considered

| Approach | What it is | Tradeoff |
|---|---|---|
| A. `share profiles` (TSV) for names, then `share --profile <p> state` per profile | no CLI change | N+1 spawns per refresh, N timeouts to coordinate, and the TSV has no schema, so an old CLI and a new one look alike |
| B. `share profiles --json`: one read verb returns every profile's `state` object | one spawn per refresh, one timeout, one coalesced call, as today | a second JSON contract on the CLI, additive to an existing verb |
| C. The app lists `~/.config/share/profiles` itself | no CLI change | breaks ADR-0003: the app would learn the CLI's layout and its override rules |

### Chosen approach + why

B. The CLI stays the only code that knows what a profile is (ADR-0003). The app replaces its one coalesced `state` call with one coalesced `profiles --json` call and renders a section per profile. Every verb the app runs carries `--profile <name>` first, so the app never depends on an inherited `SHARE_PROFILE`. The app builds `--access <rule>` from a small dialog and passes it through. It never reads, stores, or prompts for a Cloudflare token: the CLI resolves it (`api_token_cmd`, the Keychain item, or the environment, SPEC-004), and a missing token reaches the user as the CLI's guided block, verbatim.

### Extensibility & boundaries

- Growth dimension: profiles. Each costs one `state` child inside `profiles --json` and one menu section.
- Units: `cmd_profiles --json` (bash); `ProfilesSnapshot` decode, `Health`, sectioned `MenuModel`, `AccessRule`, `PublishChoice`, the verbatim failure detail (all `ShareBarCore`, unit-tested); the publish dialog, sections, and per-profile actions (`ShareBar`, checked by hand).
- Out of bounds: creating a new named profile, token handling, changing the rule of a live share.

## Picture

```
 poll 60s / wake / menu open
        |
        v
 CLI.profiles()  (coalesced, 20s timeout)
        |
        v
 share profiles --json ---- for each profile: env -u SHARE_ROOT ... SHARE_PROFILE=<p> bash share state
        |
        v
 {"schema":1,"profiles":[{"name":"default","state":{...}}, {"name":"dfoundation","state":{...}}]}
        |
        v
 MenuModel: one section per profile, worst health -> icon
        |
        +-- row actions ----------> share --profile <p> rm|refresh|hits <id>
        +-- Start / Stop ---------> share --profile <p> start|stop
        +-- Set Up... (not set up) -> share --profile <p> setup <host>|--quick   (existing window)
        +-- drop / Share File... -> publish dialog (profile, who can open)
                                       |
                                       v
                          share --profile <p> add [--access <rule>] <path>
                                       |
                          exit 1 + stderr (O1, O3, gate timeout) -> alert shows stderr verbatim
```

## Technical Design

### Interfaces (I/O contract)

**`share profiles --json`** (new flag on an existing verb). Prints on stdout, exit 0 whenever the listing itself ran:

```json
{
  "schema": 1,
  "profiles": [
    {"name": "default", "state": {"schema": 1, "state": "not_setup", "ready": false, "mode": "named", "host": null, "hosts": "", "serves_here": true, "service": false, "access_pending": 0, "shares": []}},
    {"name": "dfoundation", "state": {"schema": 1, "state": "serving", "ready": true, "mode": "named", "host": "s.d.foundation", "...": "..."}},
    {"name": "Bad", "error": "state exited 1"}
  ]
}
```

| Field | Values |
|---|---|
| `schema` | integer, 1. Removing or renaming a field bumps it; adding one does not |
| `profiles[]` | same order and same members as the text `share profiles`: `default` first, then every directory under `<config base>/share/profiles` in glob order |
| `profiles[].name` | the directory name, or `default` |
| `profiles[].state` | exactly the stdout of that profile's `share state` (SPEC-003, plus SPEC-004's `access` and `access_pending`), present when that child exited 0 and printed valid JSON |
| `profiles[].error` | `state exited <n>` (or `state printed invalid JSON`), present instead of `state` otherwise |

Rules: each child runs as the text form runs it today (`SHARE_ROOT`, `SHARE_CONFIG_DIR`, `SHARE_PORT`, `SHARE_HOSTNAME`, `SHARE_HOSTS`, `SHARE_SERVICE_LABEL` unset; `SHARE_PROFILE=<name>`). The verb inherits `state`'s invariants: it never prunes, writes, creates a file, needs a TTY, or touches the clipboard. The text form without `--json` is unchanged. Any other argument dies with `usage: share profiles [--json]`.

**CLI verbs the app runs.** Every call is `share --profile <name> <verb> ...`, `default` included:

| Action | argv |
|---|---|
| refresh the menu | `profiles --json` (the one read that is not per profile) |
| hits | `--profile <p> hits <id>` |
| Copy Link, Open | none (the row's `url`) |
| Refresh, Remove | `--profile <p> refresh <id>`, `--profile <p> rm <id>` |
| Start, Stop | `--profile <p> start`, `--profile <p> stop` |
| publish | `--profile <p> add <path>`, or `--profile <p> add --access <rule> <path>` |
| Set Up... | `--profile <p> setup <host>` or `--profile <p> setup --quick` |

**Child environment.** SPEC-003's rules, plus: the app removes `SHARE_PROFILE`, `SHARE_ROOT`, `SHARE_CONFIG_DIR`, `SHARE_PORT`, `SHARE_HOSTNAME`, `SHARE_HOSTS`, and `SHARE_SERVICE_LABEL` from every child's environment. `profiles --json` ignores those overrides, so a write that honored them would land in a root the menu never shows. Manual checks isolate the app with a throwaway `HOME` instead of `SHARE_ROOT`.

**`ShareBarCore` Swift API** (additions; existing types keep their fields):

```swift
struct Share      { ...; access: String? }                    // "access" from state; nil = public
struct Snapshot   { ...; accessPending: Int? }                // "access_pending"
struct ProfileEntry: Decodable { name: String; state: Snapshot?; error: String? }
struct ProfilesSnapshot: Decodable { schema: Int; profiles: [ProfileEntry] }
extension ProfilesSnapshot { static func from(_ r: CLIResult) -> Result<ProfilesSnapshot, Failure> }
enum Health { case ok, tunnelDown, stopped, error, elsewhere, notSetUp }   // isAttention, isNeutral
struct Section { profile; host; status; health; rows: [Row]; more; showStart; showStop; showSetUp; accessPending }
struct MenuModel { init(profiles: ProfilesSnapshot?, failure: Failure?, now: Date, working: Working?) ;
                   header; sections: [Section]; icon; canPublish: Bool; showCopyInstallCommand; showCopyUpgradeCommand; isLoading }
enum AccessRule { static func isWellFormed(_ s: String) -> Bool }
enum PublishChoice { static func eligible(_ p: ProfilesSnapshot) -> [String];
                     static func initialProfile(last: String?, eligible: [String]) -> String?;
                     static func args(profile: String, rule: String?, path: String) -> [String] }
struct MutationAlert { ...; detail: String? }                  // the full stderr, shown verbatim
extension CLI { static func profiles(timeout: TimeInterval? = 20) async -> CLIResult }   // coalesced, replaces state()
```

**Decode and failure.** `ProfilesSnapshot.from` keeps SPEC-003's order: the not-found sentinel, then exit 1 with the help banner (`.oldCLI`), then a clean decode on exit 0, else `.other(lastErrorLine)`. One rule is new: exit 0 with stdout that does not start with `{` is `.oldCLI` too, because a CLI from before this spec prints the TSV listing and ignores `--json`. A per-profile `state` with `schema` > 1 marks that profile `error` with the status `Update Share Bar`; a top-level `schema` > 1 is the global `Update Share Bar` header.

**Health per profile**, first match wins:

| Health | When | Status text | Counts for the icon |
|---|---|---|---|
| `error` | the entry has `error`, or its `state.schema` > 1 | `Error: <error>` or `Update Share Bar` | attention |
| `notSetUp` | `state` is `not_setup` | `Not set up` | neutral |
| `elsewhere` | not `serving` and `serves_here` false | `Not serving on this Mac (hosts=<hosts>)` | neutral |
| `stopped` | `stopped` | `Stopped` | attention |
| `tunnelDown` | `serving`, `ready` false | `Tunnel not connected` | attention |
| `ok` | `serving`, `ready` true | `Serving` | ok |

**Icon** (supersedes SPEC-003's rule): `connected` when at least one profile is `ok` and none needs attention; `disconnected` otherwise, which covers no set-up profile at all (the old "Not set up" icon). Neutral profiles never slash the icon, so the Mini's unset default does not hide a healthy `dfoundation`.

**Menu header** (the first line, and the status item's accessibility label), first match wins: `Working…` rules below; then SPEC-003's `Loading…`, `share CLI not found`, `Update share CLI`, `Update Share Bar`, and the failure line for the `profiles --json` call itself; then `Needs attention: <name> (<status>)` for one attention profile or `Needs attention: <name>, <name>` for several; `Serving at <host>[, <host>...]` over the `ok` profiles; `Not serving on this Mac` when every set-up profile is `elsewhere`; else `Not set up`.

**Working header.** While a mutating verb runs: `Working…`. While the running verb is a gated add: `Working… (a login gate can take minutes)`, because SPEC-004's gate waits up to 15 minutes before it publishes.

**Sections.** One per `profiles[]` entry, in order. A section starts with a disabled title line `<name> · <host or -> · <status text>`. Under it:

- rows as SPEC-003 renders them, newest first, capped at 25 when only one profile is set up and at 10 per section otherwise, then a disabled `N more (<cmd> ls)` line, where `<cmd>` is `share` for the default and `share --profile <p>` otherwise;
- a gated row (non-nil `access`) shows a `lock.fill` template image; its submenu gains a first, disabled line `Login required: <rule>`; its accessibility title is `<title>, <trailing>, login required`; its Remove text is `Remove <name>? The copy goes to the Trash and its login gate is deleted.`;
- `Start Sharing` or `Stop Sharing` per SPEC-003's `showStart`/`showStop`, applied to that profile;
- `Set Up…` when the profile is `notSetUp`: the existing setup window, its argv prefixed with `--profile <p>` and its hostname field prefilled from the section's host;
- a disabled line `<n> Access app(s) await deletion (<cmd> prune)` when `access_pending` > 0;
- an `error` section shows its title line only.

Rows and hits are keyed by (profile, id), because two profiles can mint the same 6-hex id.

**Global items**, below the sections: `Stop Waiting…` (SPEC-003 rules, one mutation queue for all profiles), `Share File…` ⌘N (disabled when `canPublish` is false), `Copy Install Command` / `Copy Upgrade Command` (as today), `Open at Login`, `About Share Bar`, `Quit Share Bar`.

**Publish dialog.** Every drop and every Share File… selection opens one `NSAlert` with an accessory view, one dialog per batch:

- message: `Publish <name>?` for one file; `Publish the folder <name> for 30 days?` when the batch holds a folder (this replaces the separate folder confirm); `Publish <n> items?` for several files;
- `Profile` popup: the eligible profiles, each as `<name> · <host>`. Eligible: `stopped` or `serving` with no `error` (`add` auto-starts a stopped profile; an `elsewhere` profile keeps SPEC-003's post-add notice). Preselected: the last profile published to, else the first eligible one;
- `Who can open` popup: `Anyone with the link` or `Only people who log in`. Choosing the second enables a `Rule` text field with the placeholder `group:<name>, email:a@x.io,b@y.io, or domain:<domain>`. For a quick-mode profile the second choice is disabled and a note reads `Login needs a named setup, not quick mode`;
- the popup and rule start at the last choice for the selected profile; switching profiles reloads that profile's last choice;
- `Publish` is disabled while the rule is not well formed (`AccessRule.isWellFormed`: after trimming, `group:`, `email:`, or `domain:` followed by at least one character, and no whitespace). The CLI owns the full grammar; its refusal reaches the user verbatim;
- `Publish` stores the profile and, per profile, the rule (empty for anyone) in `UserDefaults` (`publish.lastProfile`, `publish.rule.<profile>`), then runs one `add` per path through the mutation queue, in order;
- when `canPublish` is false (no eligible profile), a drop shows `No share profile is ready. Set one up first.` and publishes nothing.

**Failure alerts** (amends SPEC-003's rule for mutating verbs). The alert title stays `lastErrorLine`, now the last stderr line that starts with `share: ` (the die line; the O1 block's first line), falling back to today's rule. When stderr holds two or more non-empty lines, `MutationAlert.detail` carries the whole stderr, verbatim and untrimmed except for trailing newlines, shown as selectable monospaced text in the alert. This carries the O1 no-token block (with its `share --profile <p> api-token` commands and form URL), the O3 group-not-found block, and the gate-timeout line exactly as the CLI printed them. The app adds no wording of its own to a CLI failure.

### Data model changes

None on disk. The app gains two `UserDefaults` keys (`publish.lastProfile`, `publish.rule.<profile>`); neither holds a secret.

### API changes

`share profiles --json`. `share profiles`, `share state`, and every other verb are unchanged.

### UI changes

```
 On the Mini today:

 Serving at s.d.foundation                      (header; icon: antenna, not slashed)
 ───────────────
 default · - · Not set up                       (disabled title)
   Set Up…
 ───────────────
 dfoundation · s.d.foundation · Serving         (disabled title)
   [lock] ops-report.pdf     2d left  ▸         Login required: group:dwarves-ops
   notes.html               11h left  ▸         Copy Link / Open in Browser / Refresh
   … 3 more (share --profile dfoundation ls)    hits line / Remove…
   Stop Sharing
   1 Access app(s) await deletion (share --profile dfoundation prune)
 ───────────────
 Share File…                          ⌘N        -> publish dialog
 Copy Install Command                           (CLI missing only)
 Open at Login  ✓
 ───────────────
 About Share Bar
 Quit Share Bar                       ⌘Q

 Publish dialog:
 ┌──────────────────────────────────────────────────────┐
 │ Publish ops-report.pdf?                              │
 │ Profile:        [ dfoundation · s.d.foundation  v ]  │
 │ Who can open:   [ Only people who log in        v ]  │
 │ Rule:           [ group:dwarves-ops               ]  │
 │                                  [Cancel] [Publish]  │
 └──────────────────────────────────────────────────────┘
```

### Infrastructure changes

None. The cask, build, and release scripts are unchanged.

## Setup of a new profile

Out of scope. The app sets up only a profile that already exists and is `not_setup` (on the Mini, the default), by reusing SPEC-003's setup window with `--profile <p>`. Creating a new named profile is one CLI command, `share --profile <name> setup <hostname>` (SPEC-005 `### Selecting a profile`; `docs/setup.md` "Profiles"), and the menu picks the new profile up on its next refresh. A name field would duplicate the CLI's slug validation for a once-per-account step.

## Token handling

The app never handles the Cloudflare API token. It never reads `api_token_cmd`, never touches the `share-api` Keychain item, and never sets `CLOUDFLARE_API_TOKEN`. When `add --access`, or `rm` of a gated share, finds no token, the CLI exits 1 with the O1 block (SPEC-004 `### Guided messages`); the failure alert shows it verbatim, and the user runs the named `share --profile <p> api-token` command in a terminal. `api_token_cmd` may prompt (for example a 1Password unlock); that prompt belongs to the command, and the app waits for it like any mutating verb.

## Task Breakdown

- [ ] TASK-001: `share profiles --json` in `bin/share` plus the usage line; a `tests/share.sh` section. Accept: test rows 1 to 3.
- [ ] TASK-002: `ShareBarCore` decode: `Share.access`, `Snapshot.accessPending`, `ProfileEntry`, `ProfilesSnapshot.from`, `CLI.profiles()` coalesced, the child-environment strip. Accept: rows 4 to 7, 20.
- [ ] TASK-003: `ShareBarCore` model: `Health`, sections, header, icon, caps, gated-row text, `Working…` variants. Accept: rows 8 to 14.
- [ ] TASK-004: `ShareBarCore` publish and failure: `AccessRule`, `PublishChoice`, `MutationAlert.detail`. Accept: rows 15 to 19.
- [ ] TASK-005: `ShareBar` app: sections, per-profile actions with `--profile`, the publish dialog (drop and Share File…), the lock marker, the verbatim alert, Set Up… with the profile prefix. Accept: rows 21 to 24 run by hand against a throwaway `HOME` with two quick profiles, recorded in `docs/verification/menu-bar-profiles.md`.
- [ ] TASK-006: docs. README "Menu bar app" (profiles, the publish dialog, `share profiles --json`); `docs/how-it-works.md` (the `profiles --json` contract); SPEC-005's superseded Failure-modes row and Out-of-scope item point here; the verification record. Accept: a `tests/share.sh` grep finds each `profiles --json` field name in `docs/how-it-works.md`.
- [ ] TASK-007: UAT on the Mini (row 25). Accept: every step passes and is recorded in the verification record.

## Test plan

Coverage matrix. Unit rows run in `bash tests/share.sh` or `swift test --package-path mac` (new files under `mac/Tests/ShareBarCoreTests/`, fixture `Fixtures/profiles.json` built from a real `profiles --json` run). Manual rows run the built app against a throwaway `HOME`.

| Row | Level | Scenario | Assert |
|---|---|---|---|
| 1 | bash | `profiles --json` under a fresh `HOME`: default unset, profiles `a` and `b` set up `--quick --no-service`, `b` serving | `jq -e` passes; names are `default`, `a`, `b` in order; each `state` equals that profile's own `share --profile <p> state` output; `SHARE_ROOT` exported by the test does not leak into any entry |
| 2 | bash | a directory `profiles/Bad` (fails the slug) | its entry is `{"name":"Bad","error":"state exited 1"}`; the others still carry `state`; exit 0 |
| 3 | bash | `profiles --json` writes nothing; `profiles --bogus` | `find $HOME -newer <marker>` is empty; `--bogus` exits 1 with `usage: share profiles [--json]`; plain `profiles` output is byte-identical to before |
| 4 | swift | decode the fixture, plus an unknown extra field at each level | two sections' worth of `ProfileEntry`; `access` and `accessPending` decoded; the extra fields ignored |
| 5 | swift | exit 0 with TSV stdout; exit 1 with the help banner; the not-found sentinel; exit 2 with a stderr line | `.oldCLI`, `.oldCLI`, `.cliNotFound`, `.other("share: ...")` |
| 6 | swift | two concurrent `CLI.profiles()` calls against a stub that logs each spawn | one spawn |
| 7 | swift | a stub CLI that echoes its argv, driven by each action's argv builder | every per-profile argv starts `--profile <p>`, `default` included; `profiles --json` has no `--profile` |
| 8 | swift | health table: one fixture per row of `Health` | the status text and attention/neutral class match the table |
| 9 | swift | Mini fixture: default `not_setup`, `dfoundation` serving and ready | icon `connected`; header `Serving at s.d.foundation`; the default section has `showSetUp` |
| 10 | swift | `dfoundation` stopped; then serving with `ready` false; then an `error` entry | icon `disconnected`; header `Needs attention: dfoundation (Stopped)`, then `(Tunnel not connected)`, then `(Error: state exited 1)` |
| 11 | swift | two attention profiles; all set-up profiles `elsewhere`; no profile set up | `Needs attention: a, b`; `Not serving on this Mac` with icon `disconnected`; `Not set up` with icon `disconnected` |
| 12 | swift | one set-up profile with 30 rows; two set-up profiles with 30 rows each | 25 rows and `5 more (share ls)`; 10 rows each and `20 more (share --profile <p> ls)` |
| 13 | swift | a gated row and a public row | gated: `access` set, accessibility title ends `, login required`, submenu first line `Login required: group:ops`, Remove text names the login gate; public: none of these |
| 14 | swift | `working` = a plain verb; a gated add; also a top-level `schema: 2` | `Working…`; `Working… (a login gate can take minutes)`; `Update Share Bar` when idle |
| 15 | swift | `AccessRule.isWellFormed` over `group:ops`, `email:a@x.io,b@y.io`, `domain:d.foundation`, ` group:ops ` (trimmed), `group:`, `group: ops`, `ops`, `url:x`, empty | true, true, true, true, false, false, false, false, false |
| 16 | swift | `PublishChoice.eligible` over serving, stopped, `elsewhere` stopped, `not_setup`, `error` | the first three only, in `profiles[]` order |
| 17 | swift | `initialProfile` with the last profile eligible, torn down, and nil | the last; the first eligible; the first eligible; nil when none is eligible |
| 18 | swift | `PublishChoice.args` with and without a rule | `["--profile","p","add","/x"]`; `["--profile","p","add","--access","group:ops","/x"]` |
| 19 | swift | failure alerts: the O1 block verbatim from SPEC-004 as stderr, exit 1; a one-line die; the gate timeout after two waiting lines | O1: title is its first line, `detail` equals the stderr byte for byte (trailing newline aside); one-line: `detail` nil; timeout: title is the die line, `detail` holds all three lines |
| 20 | swift | `childEnvironment` with every stripped `SHARE_*` variable set, plus `SHARE_BIN` and `HOME` | the seven are gone; `SHARE_BIN`, `HOME`, and SPEC-003's `PATH`, `LANG`, `SHARE_CLIPBOARD` rules hold |
| 21 | manual | throwaway `HOME`, quick profiles `a` (serving) and `b` (stopped) | two sections; icon slashed; header names `b`; `Start Sharing` in `b` starts `b` only (`share --profile a state` unchanged) |
| 22 | manual | drop a file; pick `b`; then drop again | the share lands in `b` (`share --profile b ls`); the link is on the pasteboard; the second dialog preselects `b` |
| 23 | manual | quick profile chosen in the dialog; a malformed rule | `Only people who log in` disabled with its note; for a named profile, `Publish` stays disabled until the rule is well formed |
| 24 | manual | Remove and hits on a row in `b` while `a` has a row with the same name | each acts on `b` only; hits shows `b`'s count |
| 25 | UAT | Han, on the Mini (see below) | every step passes |

### UAT on the Mini (row 25, Han runs it)

Precondition: the default profile is not set up; `dfoundation` serves `s.d.foundation`; the new build is installed.

| Step | Action | Expect |
|---|---|---|
| U1 | open the menu | two sections: `default · - · Not set up` with `Set Up…`, and `dfoundation · s.d.foundation · Serving` with its shares; icon is the plain antenna |
| U2 | run `share --profile dfoundation api-token --check` in a terminal | if it fails: drop a file, pick `Only people who log in`, rule `email:<your address>`; the alert shows the O1 block verbatim and nothing is published; then run the `share --profile dfoundation api-token ...` command it names; if it passes, skip to U3 |
| U3 | drop a small file; profile `dfoundation`; `Only people who log in`; rule `group:dwarves-ops` (or `email:<your address>` if that group does not exist yet) | header shows `Working… (a login gate can take minutes)`; afterwards the link is on the pasteboard; the row has the lock and `Login required: <rule>`; the link in a private window redirects to `dwarves.cloudflareaccess.com` |
| U4 | drop another file | the dialog preselects `dfoundation` and the same rule; choose `Anyone with the link`; the row has no lock and the link opens without login |
| U5 | `share --profile dfoundation stop` in a terminal, wait up to 60s | icon slashes; header `Needs attention: dfoundation (Stopped)`; `Start Sharing` under `dfoundation` brings it back and the icon clears |
| U6 | Remove the gated row | the confirm names the login gate; the row disappears; `share --profile dfoundation ls` no longer lists it |

## Verification

```sh
bash tests/share.sh
shellcheck bin/share install.sh tests/share.sh tests/e2e.sh demo/render.sh mac/*.sh
swift test --package-path mac
bash mac/build.sh 0.0.0
```

Negative controls: (1) classify `notSetUp` as attention: row 9 fails (the Mini icon slashes). (2) drop `--profile` from the add argv: rows 7 and 18 fail. (3) show `lastErrorLine` only, no `detail`: row 19 fails. (4) keep `SHARE_ROOT` in the child environment: row 20 fails. (5) let `profiles --json` pass `SHARE_ROOT` to its children: row 1 fails.

## After state

- The Mini's Share Bar shows `dfoundation` serving with a plain antenna icon; today it shows `Not set up` with a slashed icon.
- A drop onto the icon can publish to any set-up profile, public or behind a login, and the next drop remembers the choice.
- A `dfoundation` outage slashes the icon and names the profile in the header.
- `share profiles --json` exists; SPEC-005's "Share Bar watches the default only" no longer holds.

## Edge Cases

1. The default is unset and a named profile serves (the Mini): neutral default, `connected` icon.
2. One profile's `state` fails: its section shows `Error: ...`; the other sections render and act.
3. A hand-made profile directory with a bad name: an `error` entry; the app offers it no action, so it never runs `--profile <bad>`.
4. Only quick-mode profiles: the login choice is disabled; public publishing works.
5. No eligible profile: `Share File…` is disabled and a drop explains why.
6. The remembered profile was torn down: the dialog falls back to the first eligible one.
7. Two profiles hold the same share id: rows and hits are keyed by (profile, id).
8. No token for a gated add or a gated Remove: the O1 block, verbatim; nothing changes.
9. A rule group that does not exist: the O3 block, verbatim; nothing is published.
10. A gated add waits minutes: the `Working…` variant; Stop Waiting TERMs the group; SPEC-004 publishes only after the gate, so nothing is served, and the next `add` or `prune` removes the waiting app.
11. A CLI from before this spec: `profiles --json` prints TSV; header `Update share CLI` with the upgrade command.
12. A folder in a batch: the dialog's message names it; one confirmation covers the batch.
13. `SHARE_ROOT` or `SHARE_PROFILE` in the app's environment: stripped; the menu and the writes agree.
14. `access_pending` > 0: the section names the count and the prune command.
15. A gated snapshot Refresh: allowed; the app keeps its gate (SPEC-004 `refresh`).

## Failure modes

| Failure class | Detection signal | Mitigation / recovery |
|---|---|---|
| one profile's `state` fails or hangs past curl's 1s ready probe | `error` entry; the 20s `profiles` timeout | that section shows the error; the icon slashes; the rest render; a timeout keeps the last snapshot, as SPEC-003 |
| a named profile goes down | health `stopped` or `tunnelDown` | icon slashes within 60s; the header names the profile; Start in its section |
| no token for `--access` | CLI exit 1 with O1 | verbatim alert; the user runs the named `api-token` command |
| a long gate wait blocks the one mutation queue | `Working… (a login gate ...)` | Stop Waiting after 60s; nothing is published on stop |
| menu and writes point at different roots | stripped child environment | rows 1 and 20 |
| old CLI | TSV on exit 0, or help on exit 1 | `Update share CLI` |

## Out of Scope

- Creating a new named profile from the app (see `## Setup of a new profile`).
- Any token entry, storage, or check in the app (see `## Token handling`).
- Changing the rule of a live share, `--host`, `--ttl`, or live (port) shares from the app.
- Per-profile mutation queues.
- Linux.

## Touches

- bin/share
- tests/share.sh
- mac/**
- docs/**
- README.md

## Decision Log

- DEC-001: One new read, `share profiles --json`, over N `state` calls or the app listing profile directories: one spawn, one timeout, and the CLI keeps the layout (ADR-0003).
- DEC-002: Every app call passes `--profile <name>`, `default` included, and the child environment drops the seven `SHARE_*` overrides, so the read and every write resolve the same profile and root.
- DEC-003: `notSetUp` and `elsewhere` are neutral for the icon; `stopped`, `tunnelDown`, and `error` need attention. A deliberately stopped profile still slashes the icon, as the single-profile app always did.
- DEC-004: One publish dialog for every add, because the login choice is per add. Return accepts the remembered choice, so a repeat drop costs one keystroke.
- DEC-005: The dialog remembers the last rule per profile, not a global "public" default. A mistaken carry-over then gates a file (visible at once, fixed by Remove and a new add) rather than exposing one.
- DEC-006: The app checks only the rule's shape; the CLI owns the grammar, and its refusal is shown verbatim, so the two can never disagree.
- DEC-007: One mutation queue for all profiles. A gated add can hold it for minutes; Stop Waiting is the escape. Per-profile queues wait for a real complaint.
- DEC-008: Setting up an existing unset profile reuses the setup window with one argv prefix; creating a new profile stays a CLI command.
