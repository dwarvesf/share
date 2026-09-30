# Spec: Share Bar sees every profile and adds gated shares

Generated: 2026-09-30
Status: VALIDATED (3 rounds, 0 critical in round 3; round 3 warnings recorded in the Decision Log as build rules)
Lane: full (a new CLI JSON contract the app depends on; an authz choice made in the UI)
Depth: research (repo: how the app refreshes, adds, and reports failures today in mac/Sources, and what cmd_profiles and cmd_state print on the Mini)
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

- Growth dimension: profiles. Each costs one serial `state` child inside `profiles --json` (local checks plus a 1s `curl` ready probe) and one menu section of up to about 14 lines. Sized for fewer than 5 profiles. Past that, the upgrade is a per-child timeout in `profiles --json` and collapsing each section into a submenu.
- Units: `cmd_profiles --json` (bash); `ProfilesSnapshot` decode, `Health`, sectioned `MenuModel`, `AccessRule`, `PublishForm`, `PublishChoice`, the verbatim failure detail (all `ShareBarCore`, unit-tested); the publish dialog, sections, and per-profile actions (`ShareBar`, checked by hand).
- Out of bounds: creating a new named profile, token handling, changing the rule of a live share.

## Picture

```
 poll 60s / wake / menu open
        |
        v
 CLI.profiles()  (coalesced, 20s timeout; after a mutation: a fresh run)
        |
        v
 share profiles --json ---- for each profile, serially:
        |                    env -u SHARE_ROOT ... SHARE_PROFILE=<p> bash share state
        v
 {"schema":1,"profiles":[{"name":"default","state":{...}}, {"name":"dfoundation","state":{...}}]}
        |
        v
 MenuModel: one section per profile, worst health -> icon
        |
        +-- row actions ----------> share --profile <p> rm|refresh|hits <id>
        +-- Start / Stop ---------> share --profile <p> start|stop
        +-- Set Up... (not set up) -> share --profile <p> setup <host>|--quick   (existing window)
        +-- drop / Share File... -> publish dialog (PublishForm: profile, audience, rule)
                                       |
                                       v   one path at a time; stop at the first failure
                          share --profile <p> add [--access <rule>] </absolute/path>
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
    {"name": "default", "state": {"schema": 1, "state": "not_setup", "ready": false, "mode": "named", "host": null, "hosts": "", "serves_here": false, "service": false, "access_pending": 0, "shares": []}},
    {"name": "dfoundation", "state": {"schema": 1, "state": "serving", "ready": true, "mode": "named", "host": "s.d.foundation", "...": "..."}},
    {"name": "Bad", "error": "share: bad profile name 'Bad' (a-z, 0-9, -; 32 chars max)"}
  ]
}
```

| Field | Values |
|---|---|
| `schema` | integer, 1. Removing or renaming a field bumps it; adding one does not |
| `profiles[]` | same order and same members as the text `share profiles`: `default` first, then every directory under `<config base>/share/profiles` in glob order |
| `profiles[].name` | the directory name, or `default` |
| `profiles[].state` | exactly the stdout of that profile's `share state` (SPEC-003, plus SPEC-004's `access` and `access_pending`), present when that child exited 0 and printed valid JSON |
| `profiles[].error` | present instead of `state` otherwise: the child's last non-empty stderr line, else `state exited <n>`, else `state printed invalid JSON` |

Rules:

- Each child runs as the text form runs it today: `SHARE_ROOT`, `SHARE_CONFIG_DIR`, `SHARE_PORT`, `SHARE_HOSTNAME`, `SHARE_HOSTS`, `SHARE_SERVICE_LABEL` unset, `SHARE_PROFILE=<name>`.
- Every entry is built with `jq --arg name ... --argjson state ...` (or `--arg error`), never by string concatenation, so a directory name with `"`, `\`, or a newline cannot break or forge an entry.
- The error line is captured without a temp file (for example, rerun only the failed child with stdout discarded).
- The verb keeps `state`'s invariants: it never prunes, writes, creates a file, needs a TTY, or touches the clipboard.
- A directory named `default` under `profiles/` (reserved: `--profile default` means the unnamed profile) becomes `{"name":"profiles/default","error":"reserved name; share ignores this directory"}`, so two entries never share the name `default`.
- The dispatcher forwards arguments (`profiles) shift; cmd_profiles "$@" ;;`). The text form without `--json` is byte-identical to today. Any other argument dies with `usage: share profiles [--json]`.

**CLI verbs the app runs.** Every call is `share --profile <name> <verb> ...`, `default` included:

| Action | argv |
|---|---|
| refresh the menu | `profiles --json` (the one read that is not per profile) |
| hits | `--profile <p> hits <id>` |
| Copy Link, Open | none (the row's `url`) |
| Refresh, Remove | `--profile <p> refresh <id>`, `--profile <p> rm <id>` |
| Start, Stop | `--profile <p> start`, `--profile <p> stop` |
| publish | `--profile <p> add <path>`, or `--profile <p> add --access <rule> <path>`; `<path>` is always absolute |
| Set Up... | `--profile <p> setup <host>` or `--profile <p> setup --quick` |

**Child environment.** SPEC-003's rules, plus: the app removes `SHARE_PROFILE` and the six location overrides above from every child's environment. `profiles --json` ignores those overrides, so a write that honored them would land in a root the menu never shows. A `tests/share.sh` check greps the `env -u` list in `cmd_profiles` and the Swift strip list and fails when they name different variables. Manual checks isolate the app with a throwaway `HOME` instead of `SHARE_ROOT`.

**Logging.** The existing `os_log` rules hold: argv (which can now carry `--access email:...`) is logged `privacy: .private`; stderr, `MutationAlert.detail`, and `ProfileEntry.error` are never logged `.public`; the stored rule (`publish.rule.<profile>`, which can hold addresses) is local data, never logged or sent anywhere. The public `verb=` log field names the verb after the `--profile <p>` prefix, not `--profile`.

**`ShareBarCore` Swift API** (additions; existing types keep their fields):

```swift
struct Share      { ...; access: String? }                    // "access" from state; nil = public
struct Snapshot   { ...; accessPending: Int? }                // "access_pending"
struct ProfileEntry: Decodable { name: String; state: Snapshot?; error: String? }
struct ProfilesSnapshot: Decodable { schema: Int; profiles: [ProfileEntry] }
extension ProfilesSnapshot { static func from(_ r: CLIResult) -> Result<ProfilesSnapshot, Failure> }
enum Health { case ok, tunnelDown, stopped, error, elsewhere, notSetUp }   // isAttention, isNeutral
enum Working { case plain, gatedAdd }      // the app sets it from the argv it enqueues (gatedAdd: an add carrying --access)
struct Section { profile; host; status; health; rows: [Row]; more; showStart; showStop; showSetUp; accessPending }
struct MenuModel { init(profiles: ProfilesSnapshot?, failure: Failure?, now: Date, working: Working?) ;
                   header; sections: [Section]; icon; canPublish: Bool; showCopyInstallCommand; showCopyUpgradeCommand; isLoading }
enum AccessRule { static func isWellFormed(_ s: String) -> Bool }
enum Audience { case anyone, login }
struct PublishForm {                                           // the dialog's state, no AppKit
  init(profiles: ProfilesSnapshot, lastProfile: String?, lastRules: [String: String])
  mutating func select(profile: String); mutating func choose(_ a: Audience); var rule: String
  var profile: String?; var audience: Audience; var loginAvailable: Bool; var canPublish: Bool; var buttonTitle: String
}
enum PublishChoice { static func eligible(_ p: ProfilesSnapshot) -> [String];
                     static func args(profile: String, rule: String?, path: String) -> [String]? }   // nil unless path starts with "/"
struct MutationAlert { ...; detail: String? }                  // the full stderr, shown verbatim
extension MutationQueue { func cancel(job: JobToken) }          // Stop Waiting: TERM only that job, if still running
extension CLI { static func profiles(fresh: Bool = false, timeout: TimeInterval? = 20) async -> CLIResult }
```

`CLI.profiles` replaces `CLI.state` and its `StateCoalescer`, which are deleted. `CLI.state()` has three call sites today, and TASK-002 converts all three in the same change so both targets keep building:

| Call site | Becomes |
|---|---|
| `StatusItemController.triggerRefresh` (poll, wake, menu open) | `CLI.profiles()` (plain) |
| `StatusItemController.performMutation` (the re-read after every mutating verb: refresh, rm, start, stop, add) | `CLI.profiles(fresh: true)` |
| `SetupWindowModel.probeCurrentHost` | removed; the window takes the host the section passes in |

A plain call joins a run in flight. A `fresh` call never joins a run that started before it: it waits for that run to end, then starts a new one, which later callers may join.

`ProfileEntry` has a hand-written `init(from:)`: it reads `state.schema` first; `schema` > 1 makes the entry `error` with `Update Share Bar`, and a `state` that does not decode makes it `error` with `state not readable`. One bad profile therefore never fails the whole `ProfilesSnapshot`.

**Decode and failure.** `ProfilesSnapshot.from` keeps SPEC-003's order: the not-found sentinel, then exit 1 with the help banner (`.oldCLI`), then a clean decode on exit 0, else `.other(lastErrorLine)`. One rule is new: exit 0 with stdout that does not start with `{` is `.oldCLI` too, because a CLI from before this spec prints the TSV listing and ignores `--json` (Grounding G1). A per-profile `state` with `schema` > 1 marks that profile `error` with the status `Update Share Bar`; a top-level `schema` > 1 is the global `Update Share Bar` header. A refresh that fails with `.other` or times out keeps the previous `ProfilesSnapshot` on screen and puts the failure in the header; only a successful decode replaces it. (Today the app clears the snapshot on any failure; that changes.) `.cliNotFound` and `.oldCLI` clear the sections, as today, because no verb would work. While the latest refresh has failed, the snapshot is stale: the icon is `disconnected`, and the publish button names the profile, not a host.

**Health per profile**, first match wins:

| Health | When | Status text | Counts for the icon |
|---|---|---|---|
| `error` | the entry has `error`, or its `state.schema` > 1 | `Error: <error>` or `Update Share Bar` | attention |
| `notSetUp` | `state` is `not_setup` (checked before `elsewhere`: the Mini's unset default reports `serves_here` false, Grounding G2) | `Not set up` | neutral |
| `elsewhere` | not `serving` and `serves_here` false | `Not serving on this Mac (hosts=<hosts>)` | neutral |
| `stopped` | `stopped` | `Stopped` | attention |
| `tunnelDown` | `serving`, `ready` false | `Tunnel not connected` | attention |
| `ok` | `serving`, `ready` true | `Serving` | ok |

**Icon** (supersedes SPEC-003's rule): `connected` when the latest refresh succeeded, at least one profile is `ok`, and none needs attention; `disconnected` otherwise, which covers no set-up profile at all (the old "Not set up" icon). Neutral profiles never slash the icon, so the Mini's unset default does not hide a healthy `dfoundation`.

**Menu header** (the first line, and the status item's accessibility label), first match wins: the `Working…` rules below; then SPEC-003's `Loading…`, `share CLI not found`, `Update share CLI`, `Update Share Bar`, and the failure line for the `profiles --json` call itself; then `Needs attention: <name> (<status>)` for one attention profile or `Needs attention: <name>, <name>` for several; `Serving at <host>[, <host>...]` over the `ok` profiles; `Not serving on this Mac` when every set-up profile is `elsewhere`; else `Not set up`.

**Working header.** `Working.plain`: `Working…`. `Working.gatedAdd`: `Working… (a login gate can take minutes)`, because SPEC-004's gate waits up to 15 minutes before it publishes.

**Sections.** One per `profiles[]` entry, in order. A section starts with a disabled title line `<name> · <host or -> · <status text>`. Under it:

- rows as SPEC-003 renders them, newest first, capped at 25 when only one profile is set up and at 10 per section otherwise, then a disabled `N more (<cmd> ls)` line, where `<cmd>` is `share` for the default and `share --profile <p>` otherwise;
- a gated row (non-nil `access`) shows a `lock.fill` template image; its submenu gains a first, disabled line `Login required: <rule>`; its accessibility title is `<title>, <trailing>, login required`; its Remove text is `Remove <name>? The copy goes to the Trash and its login gate is deleted.`;
- `Start Sharing` or `Stop Sharing` per SPEC-003's `showStart`/`showStop`, applied to that profile;
- `Set Up…` per SPEC-003's `showSetUp` (the profile is not `serving`), except for an `error` section: the existing setup window, its argv prefixed with `--profile <p>` and its hostname field prefilled from the section's host (empty when `not_setup`), because rerunning setup is the recovery for a half-finished one;
- a disabled line `<n> Access app(s) await deletion (<cmd> prune)` when `access_pending` > 0;
- an `error` section shows its title line only and offers no action, so the app never runs `--profile <bad name>`.

Rows and hits are keyed by (profile, id), because two profiles can mint the same 6-hex id.

**Global items**, below the sections: `Stop Waiting…` (SPEC-003 rules, one mutation queue for all profiles), `Share File…` ⌘N (disabled when `canPublish` is false), `Copy Install Command` / `Copy Upgrade Command` (as today), `Open at Login`, `About Share Bar`, `Quit Share Bar`.

**Publish dialog.** Every drop and every Share File… selection opens one `NSAlert` with an accessory view, one dialog per batch. `PublishForm` holds all its state and rules:

- message: `Publish <name>?` for one file; `Publish the folder <name> for 30 days?` when the batch holds a folder (this replaces the separate folder confirm); `Publish <n> items?` for several;
- `Profile` popup: the eligible profiles, each as `<name> · <host>`. Eligible: `stopped` or `serving` with no `error` (`add` auto-starts a stopped profile; an `elsewhere` profile keeps SPEC-003's post-add notice). Preselected: `publish.lastProfile` when eligible, else the first eligible one;
- `Who can open` popup: `Anyone with the link` or `Only people who log in`. `login` enables a `Rule` field with the placeholder `group:<name>, email:a@x.io,b@y.io, or domain:<domain>`. For a quick-mode profile `loginAvailable` is false and a note reads `Login needs a named setup, not quick mode`;
- the audience and rule start from `publish.rule.<profile>` (empty means `anyone`);
- **the form never moves the audience from `login` to `anyone` on its own.** Selecting another profile keeps `login` and the typed rule when the current audience is `login`, even when the new profile's stored choice is `anyone`. When `login` is current or stored but the profile is quick mode, `canPublish` is false until the user picks `Anyone with the link` by hand;
- `canPublish` is also false while the audience is `login` and the rule is not well formed (`AccessRule.isWellFormed`: after trimming, `group:`, `email:`, or `domain:` followed by at least one character, and no whitespace). The CLI owns the full grammar; its refusal reaches the user verbatim;
- the default button names what will happen: `Publish publicly on <host>` or `Publish behind login on <host>`, with the profile name in place of `<host>` when the host is unknown. Return presses it;
- on Publish the app stores `publish.lastProfile` and `publish.rule.<profile>` (the rule, or empty for `anyone`) in `UserDefaults`, then runs one `add` per path through the mutation queue, in order;
- **the batch stops** at the first `add` that exits non-zero, is stopped with Stop Waiting, or is followed by a failed re-read. The alert for that event adds a line `Not published: <names>` for the paths that never ran;
- Stop Waiting cancels only the job that was running when its confirm opened (`MutationQueue.cancel(job:)` with the job's token); a confirm answered after that job ended does nothing;
- when `canPublish` is false for every profile (none eligible), a drop shows `No share profile is ready. Set one up first.` and publishes nothing.

**After each mutation.** The app runs `CLI.profiles(fresh: true)`, so the read starts after the verb exits. After an add, the new share is the first id in the target profile's `shares` that was not there before the add; `serves_here` for the notice is the target profile's. When that read fails, the share may be live but its link is unknown: the alert says `Published to <p>, but the menu could not refresh; see <cmd> ls`.

**Failure alerts** (amends SPEC-003's rule for mutating verbs). The alert title is the last stderr line that starts with `share: ` (the die line; the O1 block's first line), falling back to today's `lastErrorLine`. When stderr holds two or more non-empty lines, `MutationAlert.detail` carries the whole stderr, verbatim except for trailing newlines, shown as selectable monospaced text in the alert. This carries the O1 no-token block (with its `share --profile <p> api-token` commands and form URL), the O3 group-not-found block, and the gate-timeout lines exactly as the CLI printed them. The app adds no wording of its own inside a CLI failure.

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
 ┌──────────────────────────────────────────────────────────────┐
 │ Publish ops-report.pdf?                                      │
 │ Profile:        [ dfoundation · s.d.foundation          v ]  │
 │ Who can open:   [ Only people who log in                v ]  │
 │ Rule:           [ group:dwarves-ops                       ]  │
 │                  [Cancel] [Publish behind login on s.d.foundation] │
 └──────────────────────────────────────────────────────────────┘
```

### Infrastructure changes

None. The cask, build, and release scripts are unchanged.

## Setup of a new profile

Out of scope. The app sets up only a profile that already exists and is `not_setup` (on the Mini, the default), by reusing SPEC-003's setup window with `--profile <p>`. Creating a new named profile is one CLI command, `share --profile <name> setup <hostname>` (SPEC-005 `### Selecting a profile`; `docs/setup.md` "Profiles"), and the menu picks the new profile up on its next refresh. A name field would duplicate the CLI's slug validation for a once-per-account step.

## Token handling

The app never handles the Cloudflare API token. It never reads `api_token_cmd`, never touches the `share-api` Keychain item, and never sets `CLOUDFLARE_API_TOKEN`. The 60s poll never resolves a token either: `share state` does not call the resolver. When `add --access`, or `rm` of a gated share, finds no token, the CLI exits 1 with the O1 block (SPEC-004 `### Guided messages`); the failure alert shows it verbatim, and the user runs the named `share --profile <p> api-token` command in a terminal. `api_token_cmd` may prompt (for example a 1Password unlock); that prompt belongs to the command, and the app waits for it like any mutating verb.

## Grounding

Read-only samples, taken on the Mini (`Mac-mini`) on 2026-09-30 with the installed CLI (`/opt/homebrew/bin/share`, v0.7.0):

- G1, today's `profiles` ignores `--json`: `share profiles --json` printed the TSV `default	not_setup	-` / `dfoundation	serving	s.d.foundation`, exit 0. The `.oldCLI` rule for "exit 0, stdout not starting with `{`" rests on this.
- G2, the default's state: `share state | jq -c '{state,serves_here,access_pending}'` gave `{"state":"not_setup","serves_here":false,"access_pending":0}`. An unset default reports `serves_here` false, so `notSetUp` must be checked before `elsewhere`.
- G3, a gated share already exists: `share --profile dfoundation state` gave `state: serving, ready: true, host: s.d.foundation, hosts: Mac-mini, access_pending: 0`, one share with keys `access, expires, id, kind, name, own_host, url`, and a non-null `access`. The Swift `Share.access` field decodes an existing key.
- G4, the token is present: `share --profile dfoundation api-token --check` exited 0, so UAT step U2 skips its no-token branch on the Mini today; test row 19 covers the O1 text.
- Not sampled: `profiles --json` output (it does not exist yet); its shape is pinned by rows 1 and 2.

Negative controls, traced dry:

| Mutation | Code path | Test that goes red |
|---|---|---|
| `Health` classifies `notSetUp` as attention | `MenuModel` icon rule over the G2-shaped default | row 9: icon `disconnected` instead of `connected` |
| `PublishChoice.args` drops `--profile` | argv builder | rows 7 and 18 |
| no `MutationAlert.detail` | failure alert over the O1 stderr fixture | row 19 |
| `childEnvironment` keeps `SHARE_ROOT` | env builder; the cross-language grep | rows 20 and 3b |
| `cmd_profiles --json` passes `SHARE_ROOT` to children | the child env in bash | row 1: the exported root leaks into an entry |
| `PublishForm.select` loads the stored `anyone` | profile switch while `login` | row 17 |
| `addPaths` continues after a failure | the batch loop | row 22b |

## Task Breakdown

- [ ] TASK-001: `share profiles --json` in `bin/share` (the flag, the `jq`-built entries, the error line, the dispatcher forwarding args, the usage line) plus a `tests/share.sh` section. Accept: rows 1, 2, 3, 3b.
- [ ] TASK-002: `ShareBarCore` decode and runner: `Share.access`, `Snapshot.accessPending`, `ProfileEntry`, `ProfilesSnapshot.from`, `ProfileEntry.init(from:)`, `CLI.profiles(fresh:)` (deleting `CLI.state` and `StateCoalescer` and converting all three call sites in the table above, `performMutation` and `SetupWindowModel.probeCurrentHost` included, so both targets build), the child-environment strip. Depends on TASK-001's fixture. Accept: rows 4 to 7, 4b, 6b, 20; `swift build` passes.
- [ ] TASK-003: `ShareBarCore` health: `Health`, header, icon, `Working`, keep-last-snapshot on failure, the stale-snapshot icon. Depends on TASK-002. Accept: rows 8 to 11, 14, 14b, 14c.
- [ ] TASK-004: `ShareBarCore` sections: per-section caps and `more` lines, gated-row text, (profile, id) keys, `access_pending` line. Depends on TASK-002. Accept: rows 12, 13.
- [ ] TASK-005: `ShareBarCore` publish and failure: `AccessRule`, `PublishForm`, `PublishChoice`, `MutationAlert.detail` and its title rule, `MutationQueue.cancel(job:)`. Depends on TASK-002. Accept: rows 15 to 19, 7b.
- [ ] TASK-006: `ShareBar` menu: sections, per-profile row actions and Start/Stop with `--profile`, the lock marker, Set Up… with the profile prefix. Depends on TASK-003 and TASK-004. Accept: rows 21 and 24 by hand.
- [ ] TASK-007: `ShareBar` publish: the dialog over `PublishForm` for drop and Share File…, the batch stop, the fresh post-add read, the verbatim alert. Depends on TASK-005 and TASK-006. Accept: rows 22, 22b, 23 by hand.
- [ ] TASK-008: docs. README "Menu bar app" (profiles, the publish dialog); `docs/how-it-works.md` (the `profiles --json` contract); SPEC-005's superseded Failure-modes row and Out-of-scope item point here; `docs/verification/menu-bar-profiles.md` with rows 21 to 24. Accept: a `tests/share.sh` grep finds each `profiles --json` field name in `docs/how-it-works.md`.
- [ ] TASK-009: UAT on the Mini (row 25). Accept: every step passes and is recorded in the verification record.

## Test plan

Coverage matrix. Unit rows run in `bash tests/share.sh` or `swift test --package-path mac` (new files under `mac/Tests/ShareBarCoreTests/`, fixture `Fixtures/profiles.json` saved from a real `profiles --json` run in TASK-001). Manual rows run the built app against a throwaway `HOME`.

| Row | Level | Scenario | Assert |
|---|---|---|---|
| 1 | bash | `profiles --json` under a fresh `HOME`: default unset, profiles `a` and `b` set up `--quick --no-service`, `b` serving; `SHARE_ROOT` exported by the test | `jq -e` passes; names are `default`, `a`, `b` in order; each `state` equals that profile's own `share --profile <p> state` run under the same `env -u` set; the exported `SHARE_ROOT` changes no entry |
| 2 | bash | directories `profiles/Bad`, `profiles/a"b` (both fail the slug), and `profiles/default` | the first two are `{"name":...,"error":"share: bad profile name ..."}` with the name JSON-escaped; the third is `{"name":"profiles/default","error":"reserved name; ..."}`; exactly one entry is named `default`; the others still carry `state`; exit 0; the whole output parses |
| 3 | bash | `profiles --json` writes nothing; `profiles --bogus`; plain `profiles` | `find $HOME -newer <marker>` is empty; `--bogus` exits 1 with `usage: share profiles [--json]`; plain output byte-identical to before |
| 3b | bash | the `env -u` list in `cmd_profiles` against the Swift strip list in `CLI.swift` | both name the same six location variables |
| 4 | swift | decode the fixture, plus an unknown extra field at each level | `ProfileEntry` per profile; `access` and `accessPending` decoded; extra fields ignored |
| 4b | swift | an entry whose `state` has `schema: 2` and one whose `state` lacks `shares` | the snapshot decodes; the first entry is `error` with `Update Share Bar`, the second `error` with `state not readable`; the other entries are intact |
| 5 | swift | exit 0 with TSV stdout; exit 1 with the help banner; the not-found sentinel; exit 2 with a stderr line | `.oldCLI`, `.oldCLI`, `.cliNotFound`, `.other("share: ...")` |
| 6 | swift | two concurrent `CLI.profiles()` calls against a stub that logs each spawn | one spawn |
| 6b | swift | a `fresh` call made while a slow stub run is in flight | two spawns; the second starts after the first ends; the fresh caller gets the second result |
| 7 | swift | a stub CLI that echoes its argv, driven by each action's argv builder | every per-profile argv starts `--profile <p>`, `default` included; `profiles --json` has no `--profile` |
| 7b | swift | `MutationQueue.cancel(job:)` with the running job's token, then with a finished job's token while a second job runs | the first TERMs the running job; the second is a no-op and the second job completes |
| 8 | swift | health table: one fixture per row of `Health` | the status text and attention/neutral class match the table |
| 9 | swift | Mini fixture: default `not_setup` with `serves_here` false, `dfoundation` serving and ready | icon `connected`; header `Serving at s.d.foundation`; the default section has `showSetUp`; its health is `notSetUp`, not `elsewhere` |
| 10 | swift | `dfoundation` stopped; then serving with `ready` false; then an `error` entry | icon `disconnected`; the stopped section has `showSetUp` with its host; the `error` section has none; header `Needs attention: dfoundation (Stopped)`, then `(Tunnel not connected)`, then `(Error: <error>)` |
| 11 | swift | two attention profiles; all set-up profiles `elsewhere`; no profile set up | `Needs attention: a, b`; `Not serving on this Mac`, icon `disconnected`; `Not set up`, icon `disconnected` |
| 12 | swift | one set-up profile with 30 rows; two set-up profiles with 30 rows each; two profiles holding the same id | 25 rows and `5 more (share ls)`; 10 rows each and `20 more (share --profile <p> ls)`; the duplicate ids get distinct keys |
| 13 | swift | a gated row and a public row; `access_pending` 1 | gated: accessibility title ends `, login required`, submenu first line `Login required: group:ops`, Remove text names the login gate; public: none of these; the pending line names `share --profile <p> prune` |
| 14 | swift | `working` `.plain`; `.gatedAdd`; idle with a top-level `schema: 2` | `Working…`; `Working… (a login gate can take minutes)`; `Update Share Bar` |
| 14b | swift | a good snapshot with `dfoundation` ok, then a timed-out refresh | the sections still render the good snapshot; the header shows the failure line; the icon is `disconnected`; a `PublishForm` built now titles its button with the profile name |
| 14c | swift | a good snapshot, then `.oldCLI`; then `.cliNotFound` | no sections; header `Update share CLI`, then `share CLI not found` |
| 15 | swift | `AccessRule.isWellFormed` over `group:ops`, `email:a@x.io,b@y.io`, `domain:d.foundation`, ` group:ops ` (trimmed), `group:`, `group: ops`, `ops`, `url:x`, empty | true, true, true, true, false, false, false, false, false |
| 16 | swift | `PublishChoice.eligible` over serving, stopped, `elsewhere` stopped, `not_setup`, `error`; `PublishForm` initial profile with the stored profile eligible, torn down, and unset | the first three only, in order; the stored one; the first eligible; the first eligible |
| 17 | swift | `PublishForm`: `login` with rule `group:ops` on `a`, then select `b` whose stored choice is empty; then select quick profile `q`; also a fresh form on `q` with `login` stored | after `b`: still `login`, rule `group:ops`; on `q`: `canPublish` false until `choose(.anyone)`; the fresh `q` form: `canPublish` false until `choose(.anyone)`; `buttonTitle` reads `Publish behind login on <host>` or `Publish publicly on <host>` to match |
| 18 | swift | `PublishChoice.args` with and without a rule; a relative path `8080` | `["--profile","p","add","/x"]`; `["--profile","p","add","--access","group:ops","/x"]`; nil |
| 19 | swift | failure alerts: SPEC-004's O1 block verbatim as stderr, exit 1; a one-line die; the gate timeout after two waiting lines | O1: the title is its first line, `detail` equals the stderr byte for byte (trailing newline aside); one-line: `detail` nil; timeout: the title is the die line, `detail` holds all three lines |
| 20 | swift | `childEnvironment` with `SHARE_PROFILE`, the six overrides, `SHARE_BIN`, and `HOME` set | the seven are gone; `SHARE_BIN`, `HOME`, and SPEC-003's `PATH`, `LANG`, `SHARE_CLIPBOARD` rules hold |
| 21 | manual | throwaway `HOME`, quick profiles `a` (serving) and `b` (stopped) | two sections; icon slashed; header names `b`; `Start Sharing` in `b` starts `b` only (`share --profile a state` unchanged) |
| 22 | manual | drop a file, pick `b`; then drop again while a 60s poll is due | the share lands in `b` (`share --profile b ls`); its link is on the pasteboard; the second dialog preselects `b` |
| 22b | manual | drop three files with `SHARE_BIN` pointing at a wrapper that fails the second `add` | the first is published, the alert shows the second's error and `Not published: <third>`; no third `add` in `log stream` |
| 23 | manual | quick profile in the dialog; a malformed rule on a named profile | `Only people who log in` disabled with its note; `Publish` disabled until the rule is well formed |
| 24 | manual | Remove and hits on a row in `b` while `a` has a row with the same name | each acts on `b` only; hits shows `b`'s count |
| 25 | UAT | Han, on the Mini (see below) | every step passes |

### UAT on the Mini (row 25, Han runs it)

Precondition: the default profile is not set up; `dfoundation` serves `s.d.foundation`; the new build is installed.

| Step | Action | Expect |
|---|---|---|
| U1 | open the menu | two sections: `default · - · Not set up` with `Set Up…`, and `dfoundation · s.d.foundation · Serving` with its shares (the existing gated one shows the lock); icon is the plain antenna |
| U2 | run `share --profile dfoundation api-token --check` in a terminal | exit 0: skip to U3. Otherwise drop a file, pick `Only people who log in`, rule `email:<your address>`: the alert shows the O1 block verbatim and nothing is published; run the `api-token` command it names, then continue |
| U3 | drop a small file; profile `dfoundation`; `Only people who log in`; rule `group:dwarves-ops` (or `email:<your address>` if that group does not exist yet) | the button reads `Publish behind login on s.d.foundation`; the header shows `Working… (a login gate can take minutes)`; afterwards the link is on the pasteboard; the row has the lock and `Login required: <rule>`; the link in a private window redirects to `dwarves.cloudflareaccess.com` |
| U4 | drop another file | the dialog preselects `dfoundation` and the same rule; choose `Anyone with the link`; the button reads `Publish publicly on s.d.foundation`; the row has no lock and the link opens without login |
| U5 | `share --profile dfoundation stop` in a terminal, wait up to 60s | icon slashes; header `Needs attention: dfoundation (Stopped)`; `Start Sharing` under `dfoundation` brings it back and the icon clears |
| U6 | Remove the two rows added in U3 and U4 | the gated confirm names the login gate; both rows disappear; `share --profile dfoundation ls` no longer lists them |

## Verification

```sh
bash tests/share.sh
shellcheck bin/share install.sh tests/share.sh tests/e2e.sh demo/render.sh mac/*.sh
swift test --package-path mac
bash mac/build.sh 0.0.0
```

Negative controls: the table in `## Grounding`; each mutation must turn its named row red.

## After state

- The Mini's Share Bar shows `dfoundation` serving with a plain antenna icon; today it shows `Not set up` with a slashed icon.
- A drop onto the icon can publish to any set-up profile, public or behind a login, and the next drop remembers the choice.
- A `dfoundation` outage slashes the icon and names the profile in the header.
- `share profiles --json` exists; SPEC-005's "Share Bar watches the default only" no longer holds.

## Edge Cases

1. The default is unset and a named profile serves (the Mini): neutral default, `connected` icon.
2. One profile's `state` fails: its section shows `Error: <the CLI's line>`; the other sections render and act.
3. A hand-made profile directory with a bad name: an `error` entry, JSON-escaped; the app offers it no action.
4. Only quick-mode profiles: `login` is unavailable; public publishing works.
5. No eligible profile: `Share File…` is disabled and a drop explains why.
6. The stored profile was torn down: the dialog falls back to the first eligible one.
7. The profile is torn down between the dialog and the add: the CLI's refusal, verbatim; the batch stops.
8. Two profiles hold the same share id: rows and hits are keyed by (profile, id).
9. No token for a gated add or a gated Remove: the O1 block, verbatim; nothing changes.
10. A rule group that does not exist: the O3 block, verbatim; nothing is published.
11. A gated add waits minutes: `Working… (a login gate ...)`; Stop Waiting TERMs the group and ends the batch; SPEC-004 publishes only after the gate, so nothing is served, and the next `add` or `prune` removes the waiting app.
12. A CLI from before this spec: `profiles --json` prints TSV; header `Update share CLI` with the upgrade command.
13. A folder in a batch: the dialog's message names it; one confirmation covers the batch.
14. `SHARE_ROOT` or `SHARE_PROFILE` in the app's environment: stripped; the menu and the writes agree.
15. `access_pending` > 0: the section names the count and the prune command.
16. A gated snapshot Refresh: allowed; the gate stays (SPEC-004 `refresh`).
17. A relative path reaches the argv builder (it should not, since panels and drops give absolute URLs): `args` returns nil and nothing runs, so `8080` never becomes a live port share.

## Failure modes

| Failure class | Detection signal | Mitigation / recovery |
|---|---|---|
| one profile's `state` fails | an `error` entry | that section shows the CLI's line; the icon slashes; the rest render |
| one profile's `state` hangs | the 20s `profiles` timeout (the children run serially with no per-child timeout, so one hang stalls the whole refresh) | the header shows the failure; every section keeps its last snapshot; per-child timeout is the upgrade path (Extensibility) |
| a named profile goes down | health `stopped` or `tunnelDown` | icon slashes within 60s; the header names the profile; Start in its section |
| no token for `--access` | CLI exit 1 with O1 | verbatim alert; the user runs the named `api-token` command |
| `api_token_cmd` waits on a prompt nobody answers | the add runs past 60s | Stop Waiting; the batch ends |
| a long gate wait holds the one mutation queue | `Working… (a login gate ...)` | Stop Waiting after 60s; nothing is published on stop |
| a batch add fails midway | non-zero exit or Stop Waiting | the batch stops; the alert names the unpublished paths |
| the read after a successful add fails | the fresh `profiles` call fails | alert `Published to <p>, but the menu could not refresh; see <cmd> ls` |
| a refresh fails or times out | `.other` or timeout | the last snapshot stays readable; the icon slashes; the header shows the failure |
| a Stop Waiting confirm outlives its job | the job token no longer matches | no-op; the next job runs on |
| a poll in flight when an add ends | the post-add read is `fresh` | it never reuses a pre-add result, so the link and the checkmark come from the new read |
| the menu and the writes point at different roots | stripped child environment; rows 3b and 20 | cannot happen while both lists match |
| old CLI | TSV on exit 0, or help on exit 1 | `Update share CLI` |

## Out of Scope

- Creating a new named profile from the app (see `## Setup of a new profile`).
- Any token entry, storage, or check in the app (see `## Token handling`).
- Changing the rule of a live share, `--host`, `--ttl`, or live (port) shares from the app.
- Per-profile mutation queues; a per-child timeout in `profiles --json`.
- Linux.

## Touches

- bin/share
- tests/share.sh
- mac/**
- docs/**
- README.md

## Decision Log

- DEC-001: One new read, `share profiles --json`, over N `state` calls or the app listing profile directories: one spawn, one timeout, and the CLI keeps the layout (ADR-0003).
- DEC-002: Every app call passes `--profile <name>`, `default` included, and the child environment drops `SHARE_PROFILE` and the six location overrides, so the read and every write resolve the same profile and root. A suite grep keeps the bash and Swift lists equal.
- DEC-003: `notSetUp` and `elsewhere` are neutral for the icon; `stopped`, `tunnelDown`, and `error` need attention. A deliberately stopped profile still slashes the icon, as the single-profile app always did.
- DEC-004: One publish dialog for every add, because the login choice is per add. Return accepts the remembered choice, and the button names the audience and host, so a repeat drop costs one keystroke without hiding where the file goes.
- DEC-005: The dialog remembers the last rule per profile, and it never loosens `login` to `anyone` on its own (not on a profile switch, not for a quick profile). A mistaken carry-over then gates a file, which the user sees at once, rather than exposing one.
- DEC-006: The app checks only the rule's shape; the CLI owns the grammar, and its refusal is shown verbatim, so the two can never disagree.
- DEC-007: One mutation queue for all profiles. A gated add can hold it for minutes; Stop Waiting is the escape, and it also ends the batch. Per-profile queues wait for a real complaint.
- DEC-008: Setting up an existing unset profile reuses the setup window with one argv prefix; creating a new profile stays a CLI command.

### Validation round 1 (2026-09-30), changes made

| Change | Why |
|---|---|
| `Depth:` header line | required for new specs (Scope) |
| TASK-005 split into menu (TASK-006) and publish (TASK-007); the model task split into health (TASK-003) and sections (TASK-004) | each task was over the atomicity budget (Scope) |
| `PublishForm` never moves `login` to `anyone` on its own; row 17 | a profile switch could silently publish a file publicly (Security, critical) |
| the batch stops at the first failure or Stop Waiting; row 22b | a stopped gated add let the next file start its own 15-minute wait, and O1 repeated per file (Failure modes, critical) |
| `CLI.profiles(fresh:)` after a mutation; the new-share diff and `serves_here` read the target profile only; row 6b | a post-add read could join a pre-add poll and miss the new link (Failure modes, critical) |
| entries built with `jq --arg`; the error carries the child's stderr line; row 2 names | a quote in a directory name could break every section; `state exited 1` hid the cause (Security, Failure modes, Design) |
| absolute-path rule in `args`; row 18 | a bare `8080` path would publish a local port (Security) |
| the button names audience and host; logging privacy stated | a blind Return could publish to the wrong audience or domain; argv now carries addresses (Security) |
| a failed or timed-out refresh keeps the last snapshot; the hang row reworded; row 14b | today's code clears the snapshot on any failure; the hang claim was false for serial children (Failure modes, Design) |
| the strip-list grep (row 3b); `Working` defined; `CLI.state` and `StateCoalescer` deleted; dispatcher forwarding named; growth ceiling stated; `## Grounding` added | drift between two lists, an undefined type, a dead API, a hidden dispatcher edit, a thin scale claim, unsampled shapes (Design, Assumptions, Scope) |
| Sustainability: not long-lived | an in-repo app change covered by the repo's own tests; no new daemon, store, vendor, credential, or paid call |

### Validation round 2 (2026-09-30), changes made

| Change | Why |
|---|---|
| the three `CLI.state()` call sites named, each with its replacement; every re-read after a mutation is `fresh`; TASK-002 owns all three, `probeCurrentHost` included | the spec named one other caller where there are two, and no task owned the probe rewrite, so deleting `CLI.state` would break the build (Assumptions, Scope, critical) |
| the icon is `disconnected` while the latest refresh has failed; row 14b asserts it | keeping the last snapshot left the plain antenna up through a hang, hiding an outage (Failure modes, critical) |
| `ProfileEntry.init(from:)` confines a bad or newer `state` to its entry; row 4b | synthesized decoding would fail the whole listing (Design) |
| keep-last applies to `.other` and timeout only; `.cliNotFound` and `.oldCLI` clear the sections; row 14c | stale sections would offer verbs that cannot run (Design) |
| `Set Up…` keeps SPEC-003's "not serving" rule, minus `error` sections | narrowing it to `notSetUp` lost the rerun-setup recovery (Design) |
| a failed post-add re-read stops the batch; Stop Waiting cancels only its own job (row 7b); a `profiles/default` directory is an error entry | n alerts on a hung profile; a late confirm killed the next add; two sections named `default` (Failure modes) |
| stale snapshot: the button names the profile; logging covers `ProfileEntry.error`, the stored rule, and the verb field; TASK-005 depends on TASK-002 | a stale host in the button; PII and log clarity; dependency pattern (Security, Scope) |
| kept: new-share attribution by id diff, not by parsing `add` stdout | SPEC-003 DEC-010 (never parse verb output) and its edge case 24 accept the same-moment terminal race |

### Validation round 3 (2026-09-30): APPROVED, 0 critical; warnings recorded, not revised

Round 3 was the cap. Each warning below is binding on the build, in the task named.

| Warning (reviewer) | Build rule | Task |
|---|---|---|
| `JobToken` has no shape and no way to get one (Failure modes, Assumptions, Design) | `JobToken` is a UUID minted per run; `MutationQueue.currentJob() async -> JobToken?`; `stopWaiting` reads it before `runModal` and passes it to `cancel(job:)` | TASK-005 (queue), TASK-007 (handler) |
| `performMutation`'s re-read might copy today's clearing branch (Failure modes) | a failed `fresh` re-read keeps the last snapshot and marks it stale, exactly as a failed poll does | TASK-002 |
| the public `verb=` log field reads `--profile` once every argv carries the prefix (Assumptions) | `CLI.swift`'s three `verbForLog` sites skip a leading `--profile <p>`; a unit test pins it | TASK-002 |
| an `error` entry text should say what to do (Failure modes) | the reserved-name entry reads `reserved name; rename or remove <config base>/share/profiles/default` | TASK-001 |
| `Error: Update Share Bar` reads oddly; a `state` with no `schema` is unstated (Design) | an entry whose `error` is `Update Share Bar` shows that text alone; a `state` without `schema` is `state not readable` | TASK-002, TASK-003 |
| row 14b's `PublishForm` clause is outside TASK-003's dependencies (Scope) | that clause moves to row 17 (TASK-005); row 14b keeps the sections, header, and icon | TASK-003, TASK-005 |
| setup completion refreshes with a plain call that can reuse a pre-setup run (Failure modes) | setup completion calls `CLI.profiles(fresh: true)` | TASK-006 |
| TASK-002 is at the atomicity limit (Scope) | accepted: splitting it would leave a target that does not build between tasks; if it overruns, split decode (`Snapshot.swift`) from the runner and call sites (`CLI.swift` and callers) with a temporary `CLI.state` shim | TASK-002 |
