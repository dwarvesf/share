# Share Bar interactions (revision 3)

Status: DRAFT for owner review. Every control in the menu and the Settings window, the `share` command it runs, the state machine it moves, and what the person sees at each step. State machines are the ones in `docs/research/2026-11-13-implicit-state-machines.md` (D1 role, D2 serve, D3 step journal, D4 link state, D5 token, D8 member) and SPEC-009 (tenant tier T0 to T2). Prototype: `docs/design/share-bar-redesign.html`.

The rule for every control: the Share Bar never classifies state itself. It reads `share state` and `share profiles --json` (and `share member ls --json` on the Members tab), shows the state's sentence, and offers only the actions the state allows. A refused action shows the CLI's stable code as a sentence plus the next step.

## 1. App states (before any tenant view)

| App state | Source | Shown | Actions |
|---|---|---|---|
| Loading | no `profiles` result yet | "Loading" in the menu | none |
| CLI missing | spawn fails | "Install the share command" | Copy install command |
| CLI too old | `compat.status = cli_below_min` or old help banner | "Update share to 0.10" | Copy upgrade command |
| No tenant | every profile `role = none` | first-run panel (section 2) | Join a team, Set up a hostname |
| Ready | at least one profile set up | the menu (section 3) | everything below |

## 2. Adding a tenant (Settings > Tenants > Add, and the first-run panel)

Add opens a sheet with two choices. Both are long, multi-step commands, so both run with the step journal (D3) and show "step n of m: name" while they run.

### 2a. Join a team with an invite code (member)

Command: `share join <code>`. Moves the profile R0 to R7 and the member record `invited` to `joining` to `active` (D8).

| Step | Journal name | Shown | Fails with (code: sentence, next) |
|---|---|---|---|
| 1 | redeem | "Checking the code" | `invite_unknown_or_used`, `invite_expired`, `invite_tampered`: "Ask your admin for a new code" |
| 2 | record | "Telling the team you are joining" | `member_changed`: "The admin changed your invite; ask for a new code" |
| 3 | store | "Saving your keys in Keychain" | Keychain denied: "Allow Share Bar in Keychain, then Resume" |
| 4 | serve | "Starting the server on this Mac" (machine mode only) | `port_busy`: "Port 8787 is in use; pick another in Advanced, then Resume" |
| 5 | probe | "Checking a test link through the hostname" | probe fails: "The team's hostname cannot reach this Mac yet; Resume tries again" |
| 6 | done | "You joined s.console.so" | |

Cancel during the run stops the process; the journal keeps the step, the tenant row shows "Joining interrupted at step 4: Resume or Remove". Resume runs bare `share join` (it continues from the journal; the code is already redeemed, so it is not needed again).

### 2b. Set up a hostname (owner or admin)

Command: `share setup <host>`, needs a Cloudflare admin token. Moves R0 to R2 (T0) and serve to `starting`, then `serving` (D2).

| Field | Default | Note |
|---|---|---|
| Hostname | empty | validated as you type (one label under a zone you own) |
| Admin token | "Ask each time" | or a command such as `op read op://Toolkit/cf-admin/credential` (see Gap G3) |
| Turn on cloud storage | off | if on, runs `setup --r2 --bucket share-<host>` after the tunnel (T0 to T1) |

Steps: zone, tunnel, DNS, token stored, service, live check (journal names). Failure shows the step and the CLI sentence; Resume reruns the same command (setup converges).

## 3. The menu

| Control | Command | State read or moved | Behavior |
|---|---|---|---|
| Tenant button | none | profile list | menu of tenants, each with its role or "N need a look"; "Manage tenants" opens Settings > Tenants |
| + | `share add <file>` (file picker) | add journal (D3), link `live` (D4) | progress "Uploading 2 of 5 files" on a placeholder row; the link is copied when the row lands |
| Drop on the icon or menu | same as + | same | drop target names where it is stored |
| Search | none | rows | filters by name and owner; empty result says so |
| Mine / Team | none | rows | Team adds the owner to the meta line; remembered per tenant |
| Row click, Return | none | link_state | copies the link; offline or paused rows copy with a warning (visitors get a 503); expired and revoked rows do not copy (D4) |
| Row right click | see below | link_state, role | context menu |
| Delete on a row | `share rm <id>` | link `live` to gone (own) or `revoked` (admin, someone else's) | 6 s Undo before the command runs; Command Z undoes |
| Show all | none | rows | a window with the full list and the same search |
| Footer "N need a look" | none | D2, D3, D5, D8 | opens the list in section 4 |
| Gear | none | | Settings window |

Row context menu: Copy link; Open in browser; Show in Finder (own machine links); Refresh from source (only on the install that added it); Remove (own) or Revoke (admin on someone else's link, explains the file stays on their machine). Items a state does not allow are hidden, not disabled.

## 4. "Need a look" (admins see team items; everyone sees their own)

Each line is one state with one action. Lines are ordered: interrupted commands, own serving problems, token problems, member problems.

| Line | State | Action | Command |
|---|---|---|---|
| "setup --r2 stopped at step 13 (route)" | D3 op died | Resume / Roll back | the journal's `rerun` / its rollback line |
| "This Mac stopped serving: port 8787 in use" | D2 `failed`, reason | Start | `share start` |
| "Tunnel not connected" | D2 `tunnel_down` for more than 2 min | Open log | (logs) |
| "Token expires in 6 days" | D5 `expiring` | Renew | admin: `share member renew <me>`; owner: `share api-token` |
| "An's MacBook is offline" | member ONLINE false, has links | Open Members | (Settings > Members, An selected) |
| "Dũng is paused" | D8 `paused` | Resume | `share member resume dung` |
| "Hà left" | D8 `left` | Remove | `share member rm ha` |
| "Chi's code expired" | D8 derived EXPIRED | Send a new code | `share member invite chi` |
| "Pausing Dũng stopped at step 2" | D8 `...ing` with a stale lease | Finish | `share member pause dung` |
| "You were removed from s.console.so" | own record `removed` (member) | Clean up | `share leave --local` |

## 5. Settings > Tenants

The table lists every profile. Selecting one shows a detail panel; its buttons come from the role (D1), the tier, and the serve phase (D2).

Detail panel: Hostname; Your role (Owner, Admin, Member); Storage (this Mac only, or this Mac and the cloud); Members (off or on, admins); Served from (machine, or "another Mac: <hosts>"); Status (serve phase sentence with reason); Token (source and expiry, D5); Version (compat, D5); Interrupted command (D3), if any.

| Button | Shown when | Command | Transition |
|---|---|---|---|
| Start serving | phase `stopped` or `failed` on an origin or machine member | `share start` | stopped/failed to starting to serving |
| Stop serving | phase `serving`, `starting`, `tunnel_down` | `share stop` | to stopped (confirm: "Links on this Mac stop answering; cloud links and other members' links keep working") |
| Turn on cloud storage | owner/admin, tier T0 | `share setup <h> --r2 --bucket <b>` | T0 to T1, 16 journal steps |
| Turn on members | admin, tier T1 | `share setup <h> --r2 --bucket <b> --members` | T1 to T2 |
| Resume / Roll back | an op died | the journal's rerun / rollback | D3 |
| Renew token | D5 expiring or expired | `share api-token` (owner), asks the admin (member) | |
| Remove | always | owner: `share teardown`; member: `share leave`; removed member: `share leave --local` | see the table below |
| Open in browser | always | none | |

Remove is the one dangerous button, so its sheet names exactly what happens per role:

| Role | Command | Sheet says | Refused when (code) |
|---|---|---|---|
| Owner, T0 | `teardown --yes` | the tunnel, DNS record and this Mac's links are deleted | never |
| Owner or admin, T1 | `teardown --yes` | as T0; cloud links keep answering from R2 until they expire | never |
| Admin, T2 | refused | "Remove every member first" with a link to Members | members exist (`members_present`) |
| Member, active | `leave` | your links are removed; the admin finishes the cloud side | |
| Member, removed or offline cleanup | `leave --local` | nothing on the team side changes | |

## 6. Settings > Members (admins, tier T2)

Each button is enabled only when `member_can <status> <verb> admin` allows it (D8); a disabled button's help text says why ("Chi has not joined yet").

| Button | Allowed from | Command | Sheet or feedback |
|---|---|---|---|
| Invite | (none) | `share member add <name> --machine/--cloud` | sheet: name, mode, code expiry, key expiry; result shows the code once with Copy and "works once, for 7 days" |
| Send a new code | invited, joining, left, EXPIRED | `share member invite <name>` | same result sheet |
| Pause | active | `share member pause <name>` | confirm: their machine links answer 503; cloud links keep working |
| Resume | paused | `share member resume <name>` | |
| Rotate keys | active, paused | `share member rotate <name>` | result sheet with a new code; the member must join again; their links stay |
| Renew | invited, active, paused | `share member renew <name>` | expiry picker |
| Remove | every status but removed | `share member rm <name>` | confirm with the cloud-link choice (keep until expiry, or delete) |
| Purge | removed | `share member purge <name>` | only in the "Removed" filter |
| Adopt | cloud-only publisher without a record | `share member adopt <name> --token-id` | from the "Unregistered publishers" filter |

While a verb runs, the row shows "Pausing, step 2 of 3"; a stale lease shows "Pausing stopped at step 2: Finish".

## 7. Settings > General and Advanced

General writes Share Bar preferences (UserDefaults) except two that write CLI config with `config_put` (D9): default expiry (`ttl=`) and default storage (`storage_default=`, origins with cloud storage only). Advanced: CLI path, log folder, classic menu (one release), Copy state as JSON (`share state`, for bug reports and agents).

## 8. Gaps found and decisions

| # | Gap | Decision |
|---|---|---|
| G1 | No machine for the menu itself (list, need-a-look, publishing, drag, undo) | Name it in Swift as `PopoverState`: `list(scope, query)`, `issues`, `publishing(step, of)`, `dropTarget`, `undo(action, deadline)`; one reducer, one test per transition |
| G2 | "Add tenant" had no defined meaning | Two paths: join with a code (R0 to R7) and set up a hostname (R0 to R2); both journaled |
| G3 | The GUI cannot run admin verbs: the admin token is environment only | New config key `admin_token_cmd` (a command, never the token), same pattern as `api_token_cmd`; unset means the Share Bar asks for the token each time and never stores it |
| G4 | A member removed while offline has no state in the Share Bar | New D8 display state: own record `removed` or token 401 shows "You were removed" with Clean up (`leave --local`) |
| G5 | Long admin verbs from the GUI need cancel and resume | Cancel stops the process; the journal keeps the step; the tenant shows Resume or Roll back |
| G6 | Teardown on a members tenant had no UI answer | Refused with code `members_present` and a link to Members |
| G7 | Tier changes (cloud storage, members) were CLI only | Buttons in the tenant detail, admin only, journaled |
| G8 | First-run had no design | The No-tenant app state shows the two Add paths |
| G9 | Row actions beyond copy were not defined | Context menu with state-gated items; expired and revoked rows never copy |
| G10 | Members table actions had no enable rule | Each button reads `member_can`; disabled buttons explain why |

These land as amendments: G1, G4, G9, G10 in SPEC-009 Phase 4 (Share Bar tasks); G2, G5, G7, G8 in SPEC-009 Phase 4 plus the journal tasks of SPEC-010; G3 and G6 as new decisions in ADR-0009 and SPEC-010 (config key and refusal code).
