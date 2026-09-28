# Spec: per-link login gate (`--access`)
Generated: 2026-09-27
Status: VALIDATED (decisions made; build starts after SPEC-005 merges)
Lane: full (authz, external provider, a new failure path that could publish content unguarded)
References: `bin/share` `cmd_add`, `copy`, `cmd_rm`, `cmd_prune`, `cmd_teardown`, `cf()`, `host_auth`, `rows`, `write_caddyfile`; `docs/specs/SPEC-005-profiles.md` (in flight on `feat/share-profiles`); dwarvesf/foundation-ops `chatwoot/edge/edge-apply` and `docs/incidents/INC-009-chat-host-public-before-access-propagated.md`.

## Problem

Every share link is public to anyone who has it. Some files must reach only a set of people: an ops report for Dwarves OPS staff, not for contractors. Contractors also hold `@d.foundation` addresses, so an email-domain rule cannot separate the two groups. share needs a per-link gate that names people or a group. Other links on the same host stay public. Removing the share must remove the gate, so no Access app outlives its link.

## Context (research, 2026-09-27)

Read-only probes against the Cloudflare API and the live edge. No secret or account id is quoted here.

### Credentials probed

| Token | Access reads | Evidence |
|---|---|---|
| `op://dfoundation-prod/df-cloudflare-ci-token` | none | `access/organizations` and `access/groups` return code 10000 "Authentication error". `access/apps`, `access/identity_providers`, `access/policies`, and `cfd_tunnel` return `success:true` with an EMPTY list, although the account holds four Access apps and two tunnels. The token lacks Access and Tunnel scopes; an empty list from it proves nothing. |
| `op://Toolkit/cf-api-token` (the token foundation-ops `chatwoot/edge` uses) | yes, on 4 accounts | Every read below comes from this token. It created the chatwoot Access apps live (foundation-ops `docs/verification/chatwoot-edge.md`, AC31), so it also holds Access: Apps and Policies Edit. It spans Console Labs, Dwarves LLC, Han Ngo, and WeBuild Community. |

Gotcha for the build: a Cloudflare list call made without the matching scope can answer `success:true, result:[]`. share must never treat an empty list as "absent" for cleanup. It stores every app id it creates and deletes by id.

### Dwarves LLC account

| Item | State | Evidence |
|---|---|---|
| Access org | enabled, team domain `dwarves.cloudflareaccess.com` | `GET access/organizations`; `https://chat.d.foundation/app` answers 302 to `https://dwarves.cloudflareaccess.com/cdn-cgi/access/login/chat.d.foundation` |
| Identity providers | ONE: `onetimepin` (email one-time PIN). No Google Workspace, no GitHub, no SAML/OIDC. | `GET access/identity_providers`: `[{"type":"onetimepin"}]` |
| Access groups | ZERO | `GET access/groups`: `[]` |
| Reusable policies | ZERO | `GET access/policies`: `[]` |
| Access apps | 4, none reference a group: `chat-staff` (host-wide, `email_domain`), `chat-admin` (paths `/super_admin/*`, `/monitoring/sidekiq/*`, `email`), `chat-widget-public` (paths, `bypass everyone`), `vps-mon dashboard + catalog (dwarves)` (paths on `monitor.infras.workers.dev`, `email_domain`) | `GET access/apps` |
| Tunnels | `dfoundation-hermes`, `mini-multica`; no share tunnel yet | `GET cfd_tunnel?is_deleted=false` |
| Zones | include `d.foundation` | `GET zones?account.id=` |

Consequence: today the only way to allow "OPS but not contractors" on this account is an explicit email list, inline or inside an Access Group. A Google Workspace group claim needs a `google-apps` IdP added first; a GitHub team needs a `github` IdP added first. Neither exists.

### Other accounts share may run against (per profile)

| Account | Access | IdPs | Groups |
|---|---|---|---|
| Han Ngo (today's default share profile, `air-share` tunnel) | enabled, `fromwu.cloudflareaccess.com` | `google` (consumer Google, not Workspace: no group claims), `onetimepin` | 0; one reusable policy `owner-only` (`email`) |
| Console Labs, WeBuild Community | NOT enabled: every Access call returns code 9999 `access.api.error.not_enabled` | n/a | n/a |

### Path matching, measured on the live edge

Probes against existing path-scoped apps (`monitor.infras.workers.dev/dashboard`, `mon.han.ws/dashboard*`, `/catalog*`):

| Request | Result |
|---|---|
| `/dashboard`, `/DASHBOARD`, `/Dashboard` | 302 to the team domain (matching is case-insensitive) |
| `/%64ashboard`, `//dashboard`, `/./dashboard` (sent with `--path-as-is`) | 302 (the edge normalizes percent-encoding, doubled slashes, and dot segments before matching) |
| `/dashboardx`, `/catalogfoo` against a `dashboard*` / `catalog*` pattern | 302 (a trailing `*` is a prefix match) |
| `/` on the same hosts | 200 (a path app leaves the rest of the host public) |
| `/x/..%2Fdashboard`, `/%2Fdashboard`, `/x/..%5Cdashboard` | 404 from the origin, NO Access redirect: the edge does not decode `%2F` or `%5C`, so these never match the path app. Caddy decodes and cleans the path, so `/x/..%2F<id>/f` would reach `pub/<id>/f`. share must refuse these at Caddy. |
| `/x/%2e%2e/dashboard`, `/dashboard%2F` | 302 (encoded dots are normalized; a trailing encoded slash still prefix-matches) |

The Access login redirect carries `kid=<AUD tag of the app that matched>`: on `chat.d.foundation/app` the `kid` equals the `aud` of `chat-staff` read from the API. So a probe can prove that THIS app enforces, not merely some broader app on the host.

Cloudflare docs (Application paths): `example.com/alpha/*` does NOT match `example.com/alpha` itself; the more specific path wins when two apps overlap; at most one wildcard between slashes; query strings are ignored. So a share gate lists both `<host>/<id>` and `<host>/<id>/*`.

The Access API field `self_hosted_domains` is deprecated (end of support 2025-11-21) in favor of `destinations: [{type:"public", uri:...}]`. foundation-ops still writes `self_hosted_domains`; share writes `destinations`.

### Enforcement delay

INC-009 (foundation-ops, 2026-09-24): a new self-hosted app on a NEW hostname started redirecting about 6.5 minutes after the API accepted it. Widening the destination list of an app that already enforced propagated at once (foundation-ops `docs/verification/chatwoot-edge.md`). UNVERIFIED: the delay for a NEW path app on a hostname that already routes (the share case). The design does not depend on the answer: content is published only after the gate is observed.

### Share-side exposure paths found in the code

| Path to the bytes | Why it matters |
|---|---|
| `https://<main>/<id>/...` | the default Caddy site serves all of `pub/` through `file_server` |
| `https://<fqdn>/...` for a `--host` share | its own site block |
| `https://<main>/<id>/...` for a `--host` SNAPSHOT share | `pub/<id>` is also reachable through the default site, so a `--host` gate must cover the main-host path too |
| another profile's hostname | closed by SPEC-005: each profile's root, and so its `pub`, is separate |
| `copy()` moves the stage into `pub/<id>` before the index row exists | the bytes are reachable the moment the `mv` lands, row or no row |
| a path with `%2F` / `%5C` that Caddy decodes into `/<id>/...` | bypasses the path app (measured above); closed by a Caddy-level 400 |
| `teardown` keeps `pub/` and `index.tsv` | a gated share's bytes would come back ungated after the next `setup`; teardown must unpublish gated shares |

## Solution

### Approaches considered

| Approach | Tradeoff |
|---|---|
| A. Email-domain rule only (`domain:d.foundation`) | One call. Fails the hard requirement: contractors pass. |
| B. Inline email list per link (`email:a@x,b@y`) | Works today with the one-time PIN IdP. Membership is retyped on every `add` and frozen into each app. |
| C. Reference an existing Access Group by name (`group:dwarves-ops`) | Membership lives in one place, maintained by an admin; every gated link follows it. Works today (the group holds an email list) and later without a share change (the group can switch to a Workspace group claim or a GitHub team once that IdP exists). Needs one more token scope (Groups Read). |
| D. share creates and maintains groups | Turns share into an identity admin tool. Out of scope. |
| E. Gate in Caddy (basic auth, or verify the Access JWT) | No per-person identity (basic auth) or a Caddy plugin share does not ship. Rejected. |
| F. Also validate the Access JWT in cloudflared (`originRequest.access {required, teamName, audTag}` on a per-share ingress rule with a `path` regex) | Fail-closed at the connector even if the edge path match misses. Costs one ingress edit per gated share under the host lock, and the ingress `path` regex faces the same encoded-path question. Deferred: the Caddy reject closes the measured gap with one static matcher. Upgrade path if a new edge bypass is found. |
| G. Gated shares always get their own `--host` hostname and a host-wide app | Removes path matching entirely. Costs a DNS record per share, the `--host` credential, and the ~6.5 minute new-hostname delay on every gated add. Rejected as the default; `--host` plus `--access` stays available. |

### Chosen approach + why

Support three rule forms on one flag: `group:` (C, the answer to the OPS-not-contractors requirement), `email:` (B, a one-off without admin work), and `domain:` (A, the simple case, with a warning that it admits everyone on the domain). share only REFERENCES groups; it never creates, edits, or lists members. Each gated share gets its own self-hosted Access app with one app-scoped allow policy, created at `add` and deleted by stored id at `rm`, expiry, and teardown. Caddy refuses encoded slashes, backslashes, and dots in the path on every main-host request, which closes the one measured edge bypass without per-share work.

### Extensibility & boundaries

- Growth dimension: gated shares. Each costs one Access app. No per-share state outside `index.tsv` and the pending file.
- Units: `access_parse` (flag -> include JSON), `access_create` / `access_delete` (Cloudflare side, one app, through `cf_try`), `access_gate` (edge probe loop), `access_sweep` (pending lines). `access_parse` and the dry-mode call order are testable locally; the rest needs `tests/e2e.sh`.
- Out of bounds: group management, changing the rule of an existing share (rm and add again), IdP setup, service tokens, quick mode.

## Picture

```
 share --profile dfoundation add ./ops-report.pdf --access group:dwarves-ops   (host s.d.foundation;
                                                   the profile root path comes from SPEC-005)
  1 prepare      ──▶ the token (guided block if none), the preflight, the sweep,
                     GET access/groups ──▶ id of "dwarves-ops"; all before any file or Cloudflare write
  2 stage copy ──▶ <root>/.stage.XXXX                 held OUTSIDE pub/: nothing to serve yet
  3 intent      ──▶ access-pending += "<id> -:<nonce> <owner>"   written BEFORE the POST
    create app  ──▶ POST access/apps  {destinations: s.d.foundation/<id>, s.d.foundation/<id>/*,
                                       policies: [allow include {group:{id}}]}
                   line becomes "<id> <app id> <owner>"; read-back of destinations + policy
  4 gate        ──▶ curl https://s.d.foundation/<id>/  and  /<id>
                     until both 302 to https://*.cloudflareaccess.com/cdn-cgi/access/login/s.d.foundation
                     with kid == this app's aud, 3 rounds in a row, up to 15 min
                                                        visitors meanwhile get Access or a 404, never bytes
  5 publish     ──▶ under the index lock: own pending line still there? mv stage ──▶ pub/<id>,
                   row with access=<app id> access_rule=group:dwarves-ops, reload, drop the line
  6 print + copy the link                               the id is secret until this line

 every request to the main host: Caddy answers 400 when the raw PATH contains %2F, %5C, or %2E
 any other Host (named mode): Caddy's catch-all answers 404; the main site is bound to its hostname
```

## Design

### Diagram

Create and delete order, with the safe state after every step:

```
 add --access                          state if share dies right after this step
 ─────────────────────────────────────  ─────────────────────────────────────────────────
 stage copy (outside pub)               nothing public; stage trashed by the EXIT handler
 intent line "<id> -:<nonce> <owner>"   nothing created
 POST app (outcome unknown on a lost    an app may exist: the sweep finds it by its fixed name
   response), line gets the app id      app gates an empty path (404 behind login); swept later
 [--host] host_add (ingress, CNAME)     fqdn reaches Caddy's catch-all: 404 (the main site answers its own
                                        hostname only); the EXIT trap removes the rule and CNAME on a die
 gate passes                            same as above
 [index lock] exact own line present?   a sweep claimed or removed it: abort, trash the stage, die
 mv stage -> pub/<id>, row, reload,     done; a crash inside the locked step leaves bytes with
   drop the line [unlock]               the line: the sweep trashes pub/<id> FIRST, then the app

 rm (and prune, teardown)
 ─────────────────────────────────────
 [index lock] "<id> <app id> <owner>" -> access-pending
 [--host] host_rm (DNS, ingress)
 trash pub/<id>, drop row, reload       link 404s behind login
 GET app: name is "share <id> <host> "  a foreign app (forged row or line) is never deleted: refused, line kept
 DELETE app (404 counts as done)        gone; any other error keeps the line for a later sweep
 line out of access-pending
```

The rule: bytes are published only after the gate is observed, and the gate is removed only after the bytes are gone. A sweep never touches a line whose owner is a live share process, claims a line (rewrites its owner to itself) under the same `index` lock before any network call, and a publisher only publishes while its exact line is still there.

### ADR link(s)

None yet. TASK-7 writes `docs/decisions/ADR-0006-access-gate-per-share.md` once Han picks the rule model (Access app per share, reference-only groups, observe-then-publish, the Caddy encoded-slash reject).

### Boundaries & failure modes

See `## Failure modes`.

## Technical Design

### Interfaces (I/O contract)

**`share add [--ttl T] [--host FQDN] [--no-index] [--access RULE] <target>`**

`RULE` is exactly one of:

| Form | Example | Validation | Policy `include` |
|---|---|---|---|
| `group:<name>` | `group:dwarves-ops` | `name` is 1 to 64 chars of `A-Za-z0-9._-`; exactly one Access Group on the account has that name | `[{"group":{"id":"<uuid>"}}]` |
| `email:<a>[,<b>...]` | `email:han@d.foundation,an@d.foundation` | each lowercased; one `@`; local part of `a-z0-9._%+-`, domain passes the hostname check; 1 to 50 addresses | one `{"email":{"email":"<a>"}}` per address |
| `domain:<domain>` | `domain:d.foundation` | the hostname regex `rows()` uses | `[{"email_domain":{"domain":"<domain>"}}]` |

Checks use `case` patterns and `${#var}` lengths in bash, and length checks in the `rows()` awk: no regex intervals, because `rows()` must run under mawk. Anything else: `die "usage: --access group:<name> | email:<a>[,<b>...] | domain:<domain>"` before any write. `domain:` prints one stderr line: `share: --access domain:<d> admits every address at <d>, contractors included; use group: to narrow it`.

Refusals, all before any write:
- quick mode: `--access needs a named tunnel on a Cloudflare account with Access: 'share teardown', then 'share setup <hostname>'`.
- no API token resolves (see `## Onboarding`): the guided message in `## Onboarding`, item O1. The browser-login cert is not tried (whether its token can manage Access is UNVERIFIED; requiring the API token keeps one path).
- `group:` lookup: `GET access/groups?name=<name>&per_page=100`, then an exact client-side name match over every page (`result_info.total_pages`). Not found: the guided message in `## Onboarding`, item O3. Two matches: `two Access groups are named '<name>'; rename one`.
- Access not enabled (API code 9999 on the create call): `Cloudflare Access is not enabled on the account that owns <zone>; enable Zero Trust in the dashboard first`.

**`cf_try METHOD PATH [JSON]`**: a sibling of `cf()` with the same header-file token handling, which never dies. It sets three globals and prints nothing: `cf_body`, `cf_code` (HTTP status), and `cf_err` (first `errors[].code`). Callers invoke it directly, never inside `$( )`, because globals set in a command substitution are lost (the pitfall `rand_id` documents). A 404 can count as done and code 9999 maps to the enable hint. A transport failure sets `cf_code=000`. Every Access call uses it; `cf()` is unchanged.

**Account**: the account that owns the profile's zone, from `GET /zones?name=<zone>&status=active`, which must return exactly one zone; its `account.id` is the account. More than one (a token that spans accounts can see a pending copy of the domain elsewhere) dies with `the token sees <n> active zones named <zone>; use a token scoped to the account that owns <host>`. Per profile by construction: each profile has its own hostname, zone, and so account.

**Access app** (`access_create`), one `POST /accounts/<acct>/access/apps` through `cf_try`:

```json
{"name": "share <id> <main host> <nonce>",
 "type": "self_hosted",
 "destinations": [{"type":"public","uri":"<main>/<id>"},
                  {"type":"public","uri":"<main>/<id>/*"},
                  {"type":"public","uri":"<fqdn>"}],
 "app_launcher_visible": false,
 "session_duration": "24h",
 "policies": [{"name":"share <id>","decision":"allow","include":[...],"precedence":1}]}
```

The `<fqdn>` destination is present only for a `--host` share. `allowed_idps` is omitted, so every IdP on the account is offered (today: one-time PIN on Dwarves). The response's `aud` is kept in memory for the gate. Read-back: `GET .../access/apps/<id>`; the set of destination `uri` values must equal the set sent (order and extra fields ignored) and the app must carry at least one policy, else `access_delete` and die (INC-005's rule: a stored app is checked, not assumed). If the API rejects inline policy objects, the fallback is the two-call path foundation-ops uses (`POST app`, then `POST apps/<id>/policies`); TASK-1 settles which on a real account.

**Gate** (`access_gate`): for each gated URL (`https://<main>/<id>/`, `https://<main>/<id>`, and `https://<fqdn>/` for `--host`):

```
curl -s -o /dev/null --max-time 10 -w '%{http_code} %{redirect_url}' "<url>?share_gate=<rand>"
```

A URL passes when the code is 30x, the redirect URL matches `^https://[a-z0-9-]+\.cloudflareaccess\.com/cdn-cgi/access/login/<that url's host>`, and its `kid` query value equals the new app's `aud`. A round probes every URL once. Until the first all-pass round, rounds run every `SHARE_ACCESS_POLL` seconds (default 10). After it, two more rounds run 5 s apart; the gate passes when all three pass, and any failure restarts the count. The whole wait is capped at `SHARE_ACCESS_WAIT` seconds (default 900; INC-009 measured 390). Every 60 s it prints `share: waiting for Cloudflare Access to enforce on <main>/<id> (new apps can take several minutes)`. The gate runs whether or not this machine serves: Access acts at the edge before the tunnel.

**Staging split**: `copy()` becomes `stage_copy <src> <opts>` (sets the stage dir, everything up to and including `gen_index`) and `stage_publish <id>` (the `mv` into `pub/<id>`). An ungated `add` calls both back to back; `refresh` runs the copy outside the index lock and the swap under it (round 8). A gated `add` runs `stage_publish` only after the gate passes. `lock_take` resets `trap release_locks EXIT` on every lock (`bin/share` `lock_take`), so the held stage path goes into a global that `release_locks` also trashes; a separate trap would be overwritten.

**Pending file**: `$root/access-pending`, one line per app that is not, or no longer, backed by a finished row: `<share id>\t<app>\t<owner pid>\t<owner start>\t<created epoch>`. A delete deferred for lack of a token is written with owner pid `0` and start `-`: no owner, so the next sweep claims it (round 8). `<app>` is an app uuid, or `-:<nonce>` when the POST was sent and its outcome is unknown; `<nonce>` is 8 hex chars from `/dev/urandom` and is also the last word of the app name (`share <id> <main host> <nonce>`), so a lookup can never match an older app for the same id. `<owner start>` is `ps -o lstart= -p <pid>` at the time the line was written; `<created epoch>` is when the intent line was first written and never changes. Every read and write of the file happens under the `index` lock. After a successful POST the adder rewrites its `-:<nonce>` line to the uuid under the lock, and only when its exact line (own pid, own start) is still there; otherwise it deletes the app it just created and dies.

**Owner liveness** (`owner_live <pid> <start>`): the pid is alive, its command matches `*share*`, and its current `lstart` equals the recorded one. The start time defeats pid reuse, including reuse by the long-lived `share serve`.

`access_sweep`, per line, in three steps:
1. Under the `index` lock, decide. Owner live -> skip the line (an add or rm owns it). A row with that share id carries `access=<app>` -> drop the line. Otherwise CLAIM it: rewrite the owner fields to this process. If no row has that share id and `pub/<share id>` exists, trash it, `write_caddyfile`, `caddy_reload`. Release the lock.
2. Without the lock, the network part:
   - `<app>` is `-:<nonce>`: first prove Access read in this run with `GET access/organizations` (`cf_code` 200). Unproven -> keep the line and stop here. Proven -> read every page of `access/apps` and match the name ending in `<nonce>`. A match gives the uuid to delete. No match drops the line only when `<created epoch>` is more than 10 minutes old (a POST can still commit after the 30 s client timeout); a younger line is kept for a later sweep.
   - `GET access/apps/<uuid>` first: a 404 is done; a name that does not start with `share <share id> <main host> ` is refused (the line is kept and a warning names the app); then `DELETE access/apps/<uuid>`; 200 or 404 is done; anything else (including `000`) is not done. A line whose id is not 6 hex, whose app is not a uuid or `-:` plus 8 hex, or whose created field is not a number is kept and never acted on; `ls` and `status` count such lines apart (round 8).
3. Under the `index` lock again: when done and the line still names this process as owner, drop it. When not done, leave the line claimed by this process; once this process exits, the next sweep sees a dead owner and retries.

The sweep never deletes an app while its bytes are in `pub/`, never trashes a share that has a row, and never holds the lock across a network call (other writers wait at most 60 s for it, `lock_take` in `bin/share`). It runs at the start of any short-lived command that holds `CLOUDFLARE_API_TOKEN` and is about to touch Access (`add --access`, `rm` of a gated share, `prune`, `teardown`). It does NOT run inside `share serve` (its startup `cmd_prune` skips the sweep): serve lives for days, so a line it claimed and failed to delete would stay owned by a live process until serve restarts. The hourly prune inherits `SHARE_API_TOKEN_OFF` from serve (see `## Onboarding`) and never sweeps either; a delete either of them defers is written with owner pid 0, so the next interactive sweep claims it (round 8). `rand_id` also skips any share id named in `access-pending`, so a new share never lands behind a waiting app.

**Publish step** of a gated add, as one critical section under the `index` lock: confirm the EXACT line `<id>\t<app uuid>\t$$\t<own start>` is still in the file; `stage_publish`; append the row; `write_caddyfile`; `caddy_reload`; drop the line. Any mismatch (a sweep claimed or removed it) means the app may already be gone: trash the stage and die without publishing.

**`rm <id>`** of a gated row: without `CLOUDFLARE_API_TOKEN`, `die "no Cloudflare credential for the Access app of <id>; set CLOUDFLARE_API_TOKEN, then rm again"` before any change (same stance as `--host`). With it: the order in `## Design`. `DELETE /accounts/<acct>/access/apps/<app id>`; a 404 counts as done; any other error dies with the id left in the pending file.

**`prune`** of an expired gated row: with the token, as `rm`. Without it (the login service has no API token), it removes bytes and row, leaves the id in `access-pending`, and logs `share: Access app for <id> awaits deletion; run 'share prune' with CLOUDFLARE_API_TOKEN`. Expiry is never blocked. The orphan app gates an empty path.

**`teardown`**: when any row carries `access=` or `access-pending` is non-empty and `CLOUDFLARE_API_TOKEN` is unset, die before any change: `teardown would orphan <n> Access app(s); rerun with CLOUDFLARE_API_TOKEN`. With it, every gated share is UNPUBLISHED in `rm` order (bytes to the Trash, row dropped, then the app deleted) and the pending file is swept, all before the tunnel goes. Ungated shares stay as today. A gated share never survives teardown, so a later `setup` cannot serve it ungated.

**`ls`**: a gated row prints `access=<rule>` after `expires=`. When `CLOUDFLARE_API_TOKEN` is exported in the environment (never through `api_token_cmd` or the Keychain, so a listing never runs `op read` or prompts), `ls` also checks each gated row's app by id and prints `share: Access app for <id> is gone; the link is PUBLIC; share rm <id>` on a 404. `ls` and `status` print `share: <n> Access app(s) await deletion; run 'share prune' with CLOUDFLARE_API_TOKEN` when `access-pending` is non-empty. **`state`**: each share gains `"access": "<rule>"` or `null`, and the top level gains `"access_pending": <n>` (added fields; `schema` stays 1). **`refresh`**: the app stays; the swap into `pub` runs under the index lock (round 8). **`hits`**: unchanged (a visitor redirected to login never reaches Caddy).

**Caddy encoded-path reject**: `write_caddyfile` adds to the DEFAULT site (the main host), as its first `handle`:

```
@encsep expression {http.request.uri}.matches("^[^?]*(?i:%2f|%5c|%2e)")
handle @encsep {
	respond 400
}
```

It must be a `handle` block: Caddy orders a bare `respond` after `handle`, so the catch-all `handle { file_server }` would answer first (reproduced by the round-2 validator with caddy v2.11.4: `/x/..%2Fabc123/f.txt` returned the file). `{http.request.uri}` is the raw request URI; the `^[^?]*` prefix limits the match to the path, so `?next=%2Fhome` still passes. `urlenc` never emits `%2F`, `%5C`, or `%2E` (it keeps `.` literal), so no link share prints is affected. `%2E` is defense in depth: the edge normalizes `%2e%2e` (measured 302), but Caddy alone would serve `/x/%2e%2e/<id>/f`. Measured with the fix: `..%2F`, `%2f`, and `..%5C` answer 400; a query with `%2F` answers 200; a `handle_path` live share still works. `--host` site blocks do not get it: a `--host` gate is host-wide, so there is no path match to slip past, and a live dev app behind `--host` may use `%2F` in its own paths.

**Test seams**: `SHARE_ACCESS_DRY=1` skips every Access call and the edge probe. It is honoured only with `SHARE_TUNNEL=0`; with the tunnel on, `add --access` under `SHARE_ACCESS_DRY=1` dies before any write, so the seam can never publish a gated-looking row with no app. `access_create` appends `POST app` and returns a fixed fake uuid; `access_delete` appends `DELETE app <id>`; the group lookup reads `$root/access-groups-fixture.json` and appends `GET groups`; each probe round reads the next line of `$root/access-probe-fixture` (`pass` or `fail`, last line repeats) and appends `PROBE <result>`; `stage_publish` appends `PUBLISH <id>`, a sweep's trash appends `TRASH <id>`, and `caddy_reload` appends `RELOAD`. A `SHARE_ACCESS_DRY_POST=lost` knob makes `access_create` return `cf_code=000` after logging `POST app (lost) <body>`, and makes the next name lookup return one app whose name is the `name` field of that logged body (so a create that omits the nonce fails row 23). `SHARE_ACCESS_DRY_DELETE=lost` makes `access_delete` return `000` after logging `DELETE app <id> (lost)`. `SHARE_ACCESS_DRY_ORGS=deny` makes the Access-read proof fail. All to `$root/access-calls.log`. `SHARE_ACCESS_WAIT` and a `SHARE_ACCESS_POLL` (default 10) shorten the loop in tests.

### Data model changes

- `index.tsv` opts gain `access=<uuid>` and `access_rule=<rule>`. `rows()` drops a row whose `access=` is not a lowercase uuid or whose `access_rule=` fails the rule grammar, so a forged row never reaches a Cloudflare call; it counts in `state.skipped` as today. Such a row can only come from a hand edit; its app, if any, stays until removed in the dashboard (documented in `docs/how-it-works.md`).
- New file `$root/access-pending` (per profile, inside the 0700 root).

### API changes

Cloudflare, per gated share: one Access app with one app-scoped policy. Reads: one `access/groups` list for `group:`. No change to DNS or ingress beyond what `--host` already does.

Token scopes on the profile's account:

| Scope | Needed for |
|---|---|
| Access: Apps and Policies Edit | every `--access` create, read-back, delete |
| Access: Organizations, Identity Providers, and Groups Read | REQUIRED for every `--access` use: the `group:` lookup, and the sweep's proof of Access read (`GET access/organizations`) before trusting an app list for a `-:<nonce>` line. Without it such lines are never resolved |
| Zone: Read | the zone -> account lookup (already needed by `--host`) |
| Cloudflare Tunnel: Edit, DNS: Edit | only when combined with `--host` (unchanged) |

### UI changes

CLI flag, usage line, `ls` column, `state` field, the skill text (`share skill`) gains one row: gated links and the three rule forms.

### Infrastructure changes

None local. On Cloudflare: Access must be enabled on the profile's account. Each person who logs in uses a Zero Trust seat (UNVERIFIED: the Dwarves plan tier and seat cap).

## Onboarding

Hard requirement from Han: first use of `--access` is guided, and every failure names its fix. The target is one click plus one paste for a tenant admin. This section adds one verb, `share api-token`, and one token resolver. Nothing else is new.

Groups are optional for a new tenant. Onboarding text, hints, and the README show `email:` and `domain:` first; `group:` is presented as the next step, once a tenant wants one reusable list.

### Token resolution (`api_token_resolve`)

Every Access code path in this spec (add, rm, prune, teardown, sweep) gets its API token from one resolver, first hit wins, in this order. Wherever this spec says `CLOUDFLARE_API_TOKEN`, read "the resolved API token".

| Order | Source | Same pattern as |
|---|---|---|
| 1 | `api_token_cmd=<command>` in the profile's config; share runs it and uses its stdout | `token_cmd` in `token_read` (`bin/share`) |
| 2 | Keychain item, account `share`, service `share-api:<hostname>` (SPEC-005 names it `share-api.<p>:<hostname>` for a named profile); Linux: `$config_dir/api-token`, mode 600 | `token_store` / `token_read` for the tunnel token |
| 3 | `CLOUDFLARE_API_TOKEN` in the environment, only when the profile stores no token | today's `--host` and `teardown` |

The profile's stored token wins over the environment, so a broad token exported in a shell never silently replaces the dedicated per-profile token. The preflight's first line names the source in use.

`share serve` exports `SHARE_API_TOKEN_OFF=1`, and the resolver returns nothing from ANY source when it is set, the environment included. So a serve started by launchd, systemd, `share start`, or the auto-start in `add` (`nohup`), and its hourly prune, never make an Access call, as Han decided (Decisions, item 3). The resolver sets a non-exported shell variable only; it never exports the token, so auto-start cannot carry it into the daemon. `--host` paths keep reading `CLOUDFLARE_API_TOKEN` as today; this switch covers Access only. Only an interactive `share prune`, `rm`, `ls`, or `add` deletes waiting apps. `--host` keeps its current credential rules; the stored token is only for Access. `write_config` keeps an existing `api_token_cmd=` line on a setup rerun, as it keeps `token_cmd` today. `teardown` forgets the stored token (the `share-api:` Keychain item or the 600 file) with the tunnel token; `api_token_cmd` leaves with the config. This supersedes SPEC-005's line "share never stores an API token": share stores a token command (preferred) or a Keychain item, both per profile, both through the existing storage pattern.

### `share api-token [--cmd '<command>' | --check]` (the one new verb)

- Every form first runs `need_host` (a profile with no setup dies with the existing "no setup yet" message) and builds the Keychain service name with SPEC-005's key function, so the key is never `share-api:` with an empty host.
- `share api-token --cmd 'op read "op://<vault>/<item>/credential"'`: writes `api_token_cmd=<command>` to the profile's config, replacing an existing line. It stores no secret. The command may print ANY existing token that already holds the scopes in `### API changes`; it need not be one share created. An org that already has an Access-capable token skips token creation entirely; the preflight confirms the scopes.
- `share api-token` (no argument) on a TTY: prints the O1 template URL, opens it in the default browser (`open` on macOS, `xdg-open` on Linux, run in the background with output to `/dev/null`). The opener is skipped when `SSH_CONNECTION` is set, or on Linux when neither `DISPLAY` nor `WAYLAND_DISPLAY` is set, so a text browser never fights the hidden prompt for the terminal. When it is skipped, missing, or fails, the printed URL is the fallback, then prompts `Paste the new token (input hidden): ` and reads it with echo off (`read -rs`). The URL is built only from constants and the validated profile slug, so nothing user-supplied reaches the opener. An empty paste dies with `no token entered; rerun: share api-token`. The token is stored with `token_store`'s stdin-only method under the service name above, so it never appears in argv. One click (Create in the dashboard) plus one paste.
- `share api-token` with stdin not a TTY: reads the token from stdin, opens no browser (scripts and tests).
- `share api-token --check`: stores nothing; runs the preflight below.
- Every form stores first, then runs the preflight, and exits non-zero if the preflight fails. The stored value stays, so the user fixes the token's scopes in the dashboard and reruns `--check` without pasting again.

### Preflight (`access_preflight`)

The preflight is read-only against Cloudflare and safe to rerun: it never creates, edits, or deletes a Cloudflare object and never writes local state. It runs in `share api-token` and as the first step of `add --access`. Each check prints one line, `ok` or `MISSING`, with the scope's exact dashboard name:

```
share: checking the API token for profile dfoundation (zone d.foundation)
  ok       token found (api_token_cmd)
  ok       Zone: Read                                        GET /zones?name=d.foundation -> 1 zone
  ok       Access: Organizations, Identity Providers, and Groups Read   GET /accounts/<acct>/access/organizations -> 200
  MISSING  Access: Apps and Policies Edit                    POST /accounts/<acct>/access/apps {} -> 10000
  fix: add the missing permission to this token at https://dash.cloudflare.com/?to=/:account/api-tokens (account API tokens), then run: share api-token --check
```

| Check | Call | ok when | MISSING line names |
|---|---|---|---|
| token present | the resolver | some source returns a non-empty value | O1 message |
| Zone: Read | `GET /zones?name=<zone>&status=active` | exactly one zone; this also yields the account id | `Zone: Read` on zero; `ambiguous: <n> active zones named <zone>` on more than one |
| Access: Organizations, Identity Providers, and Groups Read | `GET /accounts/<acct>/access/organizations` | HTTP 200 | the scope; code 9999 prints the enable-Zero-Trust fix instead |
| Access: Apps and Policies Edit | `POST /accounts/<acct>/access/apps` with body `{}` | HTTP 400 with a validation error code (the body is invalid, so nothing is created); TASK-1 pins the exact code and the check accepts only that code | the scope on 10000; any other outcome (`000`, 429, 5xx, an unexpected 2xx) prints `could not check  Access: Apps and Policies Edit (<code>); rerun: share api-token --check` and counts as not ok |

The empty-body probe is how the check proves Edit without writing. Its exact response codes are UNVERIFIED; TASK-1 records them. If an invalid body is ever accepted or the codes do not separate, TASK-1 replaces this probe with a create-then-delete of an app on `<main>/share-preflight-<nonce>`, tracked in `access-pending` like any app. That fallback would make the preflight write, and it would be noted in the spec amendment.

The exit status is 0 only when every line is `ok`. A rerun gives the same lines for the same token.

### Guided messages (testable text)

**O1, no token.** `add --access`, `rm` or `prune` of a gated share, or `teardown` with gated shares, when the resolver finds nothing:

```
share: --access needs a Cloudflare API token for s.d.foundation (profile dfoundation); none is set.
  New token (opens the prefilled form, then paste):  share --profile dfoundation api-token
  Already have a token with Access scopes:          share --profile dfoundation api-token --cmd 'op read "op://<vault>/<item>/credential"'
  Form link, pick the account that owns d.foundation:
     https://dash.cloudflare.com/?to=/:account/api-tokens&permissionGroupKeys=%5B%7B%22key%22%3A%22access%22%2C%22type%22%3A%22edit%22%7D%2C%7B%22key%22%3A%22access_acct%22%2C%22type%22%3A%22read%22%7D%2C%7B%22key%22%3A%22zone%22%2C%22type%22%3A%22read%22%7D%5D&name=share%20access%20%28dfoundation%29
```

`--profile <p>` appears only for a named profile.

`rm` and `prune` also keep their existing refusal semantics: `rm` changes nothing, `prune` defers the app.

**Verified template-URL format** (Cloudflare docs "API token template URLs", `developers.cloudflare.com/fundamentals/api/how-to/account-owned-token-template/`, fetched 2026-09-27):

| Kind | Format |
|---|---|
| Account token (chosen) | `https://dash.cloudflare.com/?to=/:account/api-tokens&permissionGroupKeys=<url-encoded JSON>&name=<url-encoded name>` |
| User token | `https://dash.cloudflare.com/profile/api-tokens?permissionGroupKeys=<url-encoded JSON>&accountId=*&zoneId=all&name=<name>` |

- `permissionGroupKeys` is a URL-encoded JSON array of `{"key": <short key>, "type": "read"|"edit"|...}`.
- The documented keys are `access` (Access applications), `access_acct` (Access organizations, IdPs, groups), and `zone` (Zone), so share asks for `[{"key":"access","type":"edit"},{"key":"access_acct","type":"read"},{"key":"zone","type":"read"}]`.
- The account-token form is chosen because the token is owned by one account, which is the Dwarves-only requirement by construction. `:account` is a literal placeholder: the dashboard asks which account.
- The user-token form documents only `accountId=*` and `zoneId=all` (every account), so share does not use it.
- An account token needs an account Administrator or Super Administrator to create it. The docs note that the template only pre-fills the form; the user still clicks Create.
- UNVERIFIED until TASK-1 opens the URL in a browser: that the dashboard pre-ticks all three permissions. On mismatch, TASK-1 records the working form, for example permission group IDs in place of short keys, which the docs PR describes for account-token links.

`share` builds the URL from the profile name and prints it; nothing is fetched.

**O3, group not found.** The lookup is authoritative only after the preflight's Groups Read line is `ok`:

```
share: no Access group named 'dwarves-ops' on the account that owns d.foundation.
  Create it once (share never creates groups):
  Cloudflare dashboard > Zero Trust > Access controls > Policies > Rule groups tab > Add a group
    Name: dwarves-ops
    Include > Selector: Emails > Value: each address (one per entry)
    Save
  then rerun the same share add.
```

The path is quoted from Cloudflare docs, "Rule groups" (`developers.cloudflare.com/cloudflare-one/access-controls/policies/groups/`, updated 2026-04-17). The dashboard now calls Access groups "Rule groups"; the API is still `access/groups`.

**Every other error line names its fix:**

| Condition | Line ends with |
|---|---|
| Access not enabled (9999) | `enable Zero Trust for this account in the Cloudflare dashboard, then: share api-token --check` |
| a scope missing at use time (10000 on a call) | `the token lacks '<scope name>'; add it at https://dash.cloudflare.com/?to=/:account/api-tokens (account API tokens), then: share api-token --check` |
| `api_token_cmd` exits non-zero or prints nothing | `api_token_cmd failed (exit <n>); run it by hand to see why, or replace it: share api-token --cmd '<command>'` |
| quick mode | the existing quick-mode refusal, which names `share setup <hostname>` |
| gate timeout | `nothing was published; rerun the same share add (Access can take several minutes on a new app)` |

### Onboarding acceptance criteria

- O-AC1: with no token source, `share add ./x --access group:dwarves-ops` exits 1 before any write and prints the O1 block. The block contains the template URL from the verified format, with the three keys in the encoded JSON and the profile name in `name`.
- O-AC2: `share api-token --cmd '<cmd>'` writes exactly one `api_token_cmd=` line to the profile's config and no secret anywhere, and accepts any token the preflight passes. `share api-token` fed on stdin stores through the Keychain or 600-file path, and the value never appears in argv (row 26's shim). Both end with the preflight.
- O-AC2b: `share api-token` with no argument on a TTY prints the template URL, calls the platform opener exactly once with that URL as its only argument, prompts with echo off, stores the pasted token, and runs the preflight. With no opener on `PATH`, it still prints the URL and proceeds to the prompt (row 33).
- O-AC3: `share api-token --check` prints one line per scope in the table above, `MISSING` names the scope exactly as the dashboard does, and the exit status is 0 only when all are `ok`.
- O-AC4: running `share api-token --check` twice in a row gives identical output, and neither run adds or changes a Cloudflare object or a local file (checked by the dry-mode call log and a before/after listing of `$root` and `$config_dir`).
- O-AC5: an unknown group prints the O3 block verbatim with the name substituted, and share makes no `POST` to `access/groups`.
- O-AC6: every error path in the table above prints a line that ends with a runnable command or a URL.
- O-AC7: after `share setup <host>` (the stated precondition), the README "Private links" steps 1 (the `--cmd` form), 2, and 3 work verbatim on a clean HOME, with the rule group for step 3 made beforehand (row 30). A `/kit:gauntlet` probe that reads only the README completes the same steps, given a pre-made token in 1Password and a pre-made rule group (row 31). The dashboard click and group creation are outside a CLI probe; the no-argument `share api-token` path is covered by row 33.

### README "Private links" quickstart (text to add, verbatim)

````
## Private links

Share a link that only named people can open (Cloudflare Access, email one-time PIN). This needs a named setup (`share setup <hostname>`, not `--quick`) on a Cloudflare account with Zero Trust enabled. If that host is not your default profile, put `--profile <name>` before the verb in every command below.

1. Give share a Cloudflare API token, once per profile.

   Already have a token with Access permissions (Apps and Policies Edit; Organizations, Identity Providers, and Groups Read; Zone Read)? Point share at it:

   ```sh
   share api-token --cmd 'op read "op://Private/cloudflare token/credential"'
   ```

   Otherwise run `share api-token`: it opens the Cloudflare token form with those permissions filled in. Click Create, paste the token, done. share checks the permissions either way.

2. Publish for named people:

   ```sh
   share add ./report.pdf --access email:a@example.com,b@example.com
   ```

   or for everyone at one email domain: `--access domain:example.com`. The link prints once Cloudflare enforces the login, which can take a few minutes the first time.

3. Next step, a reusable list: create a rule group once in the Cloudflare dashboard (Zero Trust > Access controls > Policies > Rule groups > Add a group; include each person's email), then:

   ```sh
   share add ./report.pdf --access group:<group name>
   ```
````

## Task Breakdown

Dependency: SPEC-005 (profiles) lands first. Rows 20 and AC5 need it; every other task works on the default profile.

### Phase 1: Foundation
- [ ] TASK-1: spike on a throwaway profile and zone: open the O1 template URL and record whether the dashboard pre-ticks the three permissions; check whether `GET /user/tokens/verify` (used by `auth_api` in setup and teardown) accepts an account-owned token or only `/accounts/<id>/tokens/verify` does; record the empty-body POST probe's codes; create one app with inline `destinations` and `policies`, read it back, measure the time until `/<id>/` 302s with `kid == aud` on an already-routed host, probe the encoded shapes of row 17, delete the app. AC: the POST shape (inline or two-call) and the measured delay are written in `docs/implementation-notes/access.md`.
- [ ] TASK-2: `access_parse`, the opts and `rows()` validation, `cf_try`. AC: rows 1, 2, 13 pass.
- [ ] TASK-3: the Caddy encoded-path reject in `write_caddyfile`. AC: row 22 passes; the existing suite passes.

### Phase 2: Core
- [ ] TASK-4: `stage_copy` / `stage_publish` split with the stage path in the `release_locks` handler. Depends on nothing else. AC: the existing suite passes untouched; row 4 leaves no stage.
- [ ] TASK-5: `access_create` (intent line, POST, read-back), `access_delete`, the pending file format, `rand_id` skipping pending ids. Depends on TASK-2. AC: rows 5, 8, 23, 24.
- [ ] TASK-6: `access_gate`. Depends on TASK-5. AC: rows 6 and 16 in dry mode.
- [ ] TASK-7: gated `add` wiring for snapshot, live, and `--host`, with the locked publish step. Depends on TASK-4 to TASK-6. AC: rows 3, 6, 7, 25.
- [ ] TASK-8: `rm`, `prune`, `access_sweep`. Depends on TASK-5. AC: rows 9, 10, 11, 11b, 23b, 23c, 23d, 25b, 26; `share serve`'s startup prune logs no sweep call.
- [ ] TASK-9: `teardown` unpublishes gated shares. Depends on TASK-8. AC: rows 12, 12b.

- [ ] TASK-13: `api_token_resolve` (with `SHARE_API_TOKEN_OFF` exported by `serve`), `share api-token`, `access_preflight`, the O1 and O3 messages, and the fix-naming error lines. Depends on TASK-2 and TASK-5. AC: O-AC1 to O-AC6 and O-AC2b; rows 27, 28, 29, 32, 33.

### Phase 3: Polish
- [ ] TASK-10: `ls` (app-gone check, pending count), `status`, `state` fields, skill row. AC: row 14 and the `ls` messages in `### Interfaces`.
- [ ] TASK-11: `tests/e2e.sh` gated legs (rows 17 to 20). Depends on TASK-7 to TASK-9. AC: the legs pass against a throwaway zone; a run log goes to `docs/verification/access.md`.
- [ ] TASK-12: docs and ADR. `docs/decisions/ADR-0006-access-gate-per-share.md`; README feature row; `docs/how-it-works.md` gains the gated lifecycle, `access-pending` in the file tree, the encoded-path reject in the Caddy block, and a security row; `docs/setup.md` gains the token scopes, the template URL, and how to create a rule group by hand; README gains the "Private links" quickstart verbatim from `## Onboarding`; the skill text gains `--access` and `share api-token`. AC: each named doc claim matches the code line it describes; row 30 passes.
- [ ] TASK-14: UX proof. Depends on TASK-11 to TASK-13. Rows 30 and 31. AC: both logs in `docs/verification/access.md`.

## After state

- [ ] `share --profile dfoundation add ./ops.pdf --access group:dwarves-ops` prints a link only after the gate passes; opening it asks for a one-time PIN; an address outside the group gets no code. (Today: `usage:` error.)
- [ ] Another share on the same host still answers 200 with no login.
- [ ] `https://<main>/x/..%2F<id>/<name>` answers 400. (Today: the bytes, for any share.)
- [ ] `share rm <id>` leaves no Access app: `GET access/apps/<app id>` is 404.
- [ ] An expired gated share under the service leaves its app in `access-pending`; `share status` shows the count; the next `share prune` with the token deletes it.
- [ ] `share teardown` leaves no gated row, no gated bytes, and no app.
- [ ] `bash tests/share.sh` PASS on macOS `/bin/bash` 3.2 and Ubuntu; `shellcheck` clean.

## Acceptance Criteria (global)

1. At no point in `add` does `https://<main>/<id>/...` or `https://<fqdn>/` answer the shared bytes without an Access redirect, including through encoded-separator paths (e2e probes during and after the gate wait; dry-mode order locally).
2. Every app share creates is deleted by `rm`, token-holding `prune`, or `teardown`, or is named in `access-pending` (by id, or by `-` plus its fixed name); none is ever untracked.
3. No new place a token appears in argv, logs, or output; every Cloudflare call goes through `cf()` or `cf_try`, which share the header-file token path.
4. Ungated shares, old rows, quick mode, and `--host` without `--access` behave as before, except that on the main host a raw path containing `%2F`, `%5C`, or `%2E` now answers 400. `--host` sites are unchanged.
5. Works per profile: a gated share on one profile creates its app on that profile's account and is unreachable through another profile's hostname.

## Failure modes

| Failure | Detection | Behavior |
|---|---|---|
| Gate never passes within `SHARE_ACCESS_WAIT` | the wait cap | delete the app (and `host_rm` for `--host`), trash the stage, `die "Cloudflare Access did not enforce on <main>/<id> within <n>s; nothing was published"`. A failed delete keeps the pending line and says so |
| Ctrl-C or crash during the gate | the EXIT handler; a pending line whose pid is dead | stage trashed; next credentialed command sweeps the app |
| POST response lost (timeout, network) | `cf_code=000` | pending line stays `-:<nonce>`; a later sweep that has proven Access read finds the app by its nonce name; an unproven sweep keeps the line; the add dies without publishing |
| Read-back mismatch (destination set or no policy) | read-back compare | delete the app, die, nothing published |
| A sweep races a running add or rm | owner pid plus start time in the pending line; the `index` lock | the sweep skips a live owner; a sweep that claims a line rewrites its owner first, so the publisher's exact-line check fails and it aborts without publishing |
| Group renamed or deleted after `add` | none needed | the app keeps the group id; a deleted group matches nobody: fail-closed |
| App deleted by hand in the dashboard | `ls` with the token: GET by id answers 404 | `ls` prints the PUBLIC warning; `rm` treats the 404 as done |
| Encoded separator or dot (`%2F`, `%5C`, `%2E`) aimed past the path app | Caddy matcher | 400 at Caddy for every share |
| `rm` without the token | credential check | die, nothing changed |
| `prune` without the token | credential check | bytes and row go, the app waits in `access-pending` with owner pid 0; `status`, `ls`, `state` show the count |
| a pending line names a foreign app, or is malformed | the read-before-delete name check; the line grammar | never deleted: a foreign app is refused with its name in a warning and the line kept; a malformed line is kept, counted apart, and named as the user's to remove; teardown stops before the tunnel goes while a well-formed line survives its sweep |
| Token lacks Groups Read | not-found on the lookup | `group:` dies with the scope named; `email:` and `domain:` still work |
| Account without Access | `cf_err=9999` | die before publishing, with the enable hint |
| Gate passes at the prober's edge location before others | none from one vantage point | residual risk: the id is unknown until share prints it, three rounds with `kid == aud` are required, and the Caddy reject covers the measured bypass. UNVERIFIED whether enforcement rolls out per location |

## Test plan

Local rows run in `tests/share.sh` with `SHARE_TUNNEL=0` and `SHARE_ACCESS_DRY=1`; call order compares line numbers in `access-calls.log`, never independent greps.

| # | Category | Case | Assert |
|---|---|---|---|
| 1 | parse | `group:dwarves-ops`, `email:A@X.io,b@y.io`, `domain:d.foundation` | row carries `access_rule=` with the lowercased value; include JSON matches the grammar table |
| 2 | parse-refuse | `--access bad`, `group:`, `email:nope`, `domain:-x`, 51 emails | exit 1, usage line on stderr, no row, no `POST app` |
| 3 | refuse | quick mode + `--access`; `SHARE_ACCESS_DRY=1` with `SHARE_TUNNEL=1` | exit 1, named message, no call logged, no row |
| 4 | refuse | `env -u CLOUDFLARE_API_TOKEN`, dry off | exit 1, scope named, no stage left under `$root` |
| 5 | group | fixture without the name; fixture with it twice; fixture spread over two pages | the first two die with their messages and no `POST app`; the paged one resolves |
| 6 | order | gated snapshot add, probe fixture `fail`,`fail`,`pass`x3 | line order `POST app` < every `PROBE` < `PUBLISH`; `pub/<id>` absent while any `PROBE fail` is logged (a background loop polls `pub/` and the log) |
| 7 | order | gated live add | row and `handle_path` block written only after the last `PROBE pass` |
| 8 | timeout | probe fixture `fail`, `SHARE_ACCESS_WAIT=2` | exit 1; `DELETE app` logged; no row; no `pub/<id>`; no `.stage.*`; `access-pending` empty |
| 9 | rm | rm of a gated row | `RELOAD` precedes `DELETE app` in the log; local `GET /<id>/` 404; `access-pending` empty after |
| 10 | prune | expired gated row, token unset | row and bytes gone; line in `access-pending`; exit 0; `status` prints the pending count |
| 11 | sweep | then `prune` with the token | `DELETE app <that id>` logged; `access-pending` empty |
| 11b | sweep | pending line with a dead pid whose `pub/<id>` exists and no row | log order `TRASH <id>` < `DELETE app`; `pub/<id>` gone |
| 12 | teardown | gated row present, token unset | exit 1 before any change: service, config, row all intact |
| 12b | teardown | gated and ungated rows, token set | no `access=` row and no gated `pub/<id>` left; `DELETE app` logged; the ungated row and its bytes stay |
| 13 | rows | hand-written row with `access=../x` or a bad `access_rule=` | `ls` skips it; `state` counts it in `skipped` |
| 14 | state | gated and ungated rows, one pending line | `access` is the rule string and `null`; `access_pending` is 1; `schema` is 1 |
| 15 | compat | existing suite, ungated | unchanged PASS |
| 16 | negative control | break the order: publish before the gate (temporary patch) | row 6 FAILs |
| 17 | e2e | `tests/e2e.sh` gated leg on a throwaway zone with Access, `--access email:<tester>` | during the gate wait a parallel poll of `/<id>/` never sees 200; after `add`, `/<id>/`, `/<id>`, `/<ID upper>/`, the first id char percent-encoded, `//<id>/`, and `/x/%2e%2e/<id>/` all 302 with `kid == aud`; `/x/..%2F<id>/<name>` and `/%2F<id>/<name>` answer 400; a second ungated share answers 200 |
| 18 | e2e | `--host dev.<zone> --access ...` | `https://dev.<zone>/` and `https://<main>/<id>/` both 302 |
| 19 | e2e | `rm` | `GET access/apps/<app id>` 404; `/<id>/` never 200 |
| 20 | e2e | two profiles on two zones (needs SPEC-005) | gated share on profile A: `https://<B host>/<id>/` is 404 |
| 21 | UAT | Han opens a `group:dwarves-ops` link | one-time PIN to a group address succeeds; a contractor address gets no code |
| 22 | caddy | local `curl --path-as-is` of `/x/..%2F<id>/<name>`, `/%2f<id>/<name>`, `/x/..%5C<id>/<name>`, `/x/%2e%2e/<id>/<name>` for a snapshot share, and `/x/..%2F<live id>/` for a main-host live share; the plain links; `/<id>/50%25.v1.txt` for a file named `50%.v1.txt`; `/<id>/<name>?next=%2Fhome`; `caddy adapt` of the rendered Caddyfile | 400 for the five encoded paths; 200 for the plain links, the `%25` file, and the query case; in the adapted JSON the `@encsep` route precedes the `file_server` route |
| 23 | lost POST | `SHARE_ACCESS_DRY_POST=lost`, created epoch forged 11 minutes old | add dies, nothing published; pending line has `-:<nonce>`; the logged POST body's `name` ends in that nonce; a later `prune` with the token logs `GET orgs`, a name lookup that matches the name taken from the logged POST body, then `DELETE app`, and empties the file |
| 23d | young no-match | a `-:<nonce>` line 1 minute old, proven read, no app with that nonce | line kept; no `DELETE` |
| 23b | unproven list | as row 23, then `prune` with `SHARE_ACCESS_DRY_ORGS=deny` | no name lookup, no `DELETE`; the `-:<nonce>` line stays |
| 23c | lost DELETE | a gated add paused in the gate whose owner fields are forged to a dead pid; `prune` with `SHARE_ACCESS_DRY_DELETE=lost` claims the line | the add's publish step finds a mismatched line, trashes its stage, dies; no `PUBLISH` in the log; no row |
| 24 | rand_id | a pending line for id `abc123` and `rand_id_raw` stubbed to return `abc123` then another | the new share does not get `abc123` |
| 25 | race | a gated add paused in the gate (probe fixture `fail` for 3 s) while `prune` with the token runs | no `DELETE app` logged by the prune; the add then publishes |
| 25b | pid reuse | a pending line naming the pid of the running `share serve` but a different start time | the sweep treats the owner as dead and processes the line |
| 27 | onboarding O1 | no token source (env unset, no `api_token_cmd`, stub `security` with no item), `add ./x --access group:dwarves-ops` | exit 1; stderr has the O1 block; the URL starts `https://dash.cloudflare.com/?to=/:account/api-tokens&permissionGroupKeys=`; URL-decoding the value gives exactly the three key/type pairs; `name` decodes to `share access (<profile>)`; no stage, row, or call logged |
| 28 | api-token | `share api-token --cmd 'printf tok'`; then `printf tok \| share api-token` with a stub `security` recording `-s` only | config has one `api_token_cmd=printf tok` line (rerun replaces it, never duplicates); the stub saw service `share-api:<host>`; the `tok` value never appears in the recorded argv; both runs print the preflight |
| 29 | preflight | dry fixtures per scope: all ok; Groups Read denied; Apps Edit denied (probe returns 10000); Access not enabled (9999) | lines and exit codes per the preflight table; each MISSING line carries the exact scope name; a second identical run prints identical output; the call log shows no write other than the invalid-body probe; `$root` and `$config_dir` listings are unchanged |
| 30 | clean-HOME walkthrough | `HOME=$(mktemp -d)`; `share setup <throwaway host> --no-service` with a test API token (the precondition); a rule group made beforehand; then remove `CLOUDFLARE_API_TOKEN` from the environment (`unset`), then `share add ./x --access email:<tester>` to see the O1 block, then README "Private links" steps 1 (`--cmd` form), 2, and 3 verbatim, with `op` replaced by a stub that prints the test token | the first add prints the O1 block and exits 1; step 1's preflight is all `ok`; steps 2 and 3 each print a link after the gate; each link 302s to Access. Run by hand before release; log in `docs/verification/access.md` |
| 31 | gauntlet | `/kit:gauntlet` probe round: a fresh agent gets only README.md, a clean HOME already set up for a throwaway host, a pre-made rule group and its name, a test token in 1Password (its `op://` ref given), and the outcome "publish ./report.pdf so only a@x and b@y can open it, then publish it for the rule group" | the probe runs steps 1 to 3 and reaches a gated link without reading bin/share or any doc but README; each round's stuck point becomes a README or message fix; rounds recorded per the gauntlet contract |
| 32 | error lines | trigger each row of the fix-naming table in dry mode | every stderr error line ends with a command or a URL (checked by a regex over the captured stderr) |
| 33 | api-token no-arg | under `script` (a pseudo-TTY; `script -q /dev/null` on macOS, `script -qc` on Linux), a stub `open` (macOS) or `xdg-open` (Linux) on `PATH` recording its argv, the test token fed to the prompt; then again with no opener on `PATH` | the opener ran once with the template URL as its only argument; the prompt appeared and the token did not echo; macOS: the stub `security` saw the store; Linux: `$config_dir/api-token` exists with mode 600; the preflight ran. The test waits (bounded, 5 s) for the backgrounded stub's argv file before asserting. With no opener, or with `SSH_CONNECTION` set: the URL is printed, the opener is not called, and the prompt still appears |
| 26 | argv | a `curl` shim first on `PATH` recording its argv, a gated add plus rm with a sentinel token | the sentinel string never appears in the recorded argv, nor in share's own stdout or stderr |
| 34 | round 8: Host binding | a request to the main site with `Host: other.example.test`; with the hostname; the Caddyfile text | 404; 200; the main block names the hostname plus `127.0.0.1` and `localhost` |
| 35 | round 8: foreign app | a pending line whose app reads back as `chat-staff`; a line with id `..`; a line with `not-a-uuid` | no `DELETE`; the warning names the app; all three lines kept; the share root intact |
| 36 | round 8: deferred owner | a gated row expired by serve's own startup prune | the pending line carries owner `0` and start `-`; the next `share prune` with the token deletes the app |
| 37 | round 8: refusals | `--access $'email:a@x.io\nb@y.io'`; `api-token --cmd` with a line break; a pasted token with a quote | exit 1 each, nothing written |
| 38 | round 8: teardown | a gated row whose app refuses deletion (foreign name) | teardown dies naming the count before `svc_uninstall`; tunnel, token, and config intact |

## Verification

```
shellcheck bin/share tests/share.sh tests/e2e.sh && /bin/bash tests/share.sh
```

Then by hand before release: `SHARE_E2E_HOST=... CLOUDFLARE_API_TOKEN=... SHARE_E2E_ACCESS_EMAIL=... tests/e2e.sh`, and the UAT row.

## Out of Scope

Creating, editing, or listing Access Groups or their members; adding IdPs; service-token access for machines; changing the rule of a live share; gating the whole main hostname; quick mode; storing a raw API token outside the existing Keychain/600-file pattern. (SPEC-005's "share never stores an API token" needs a one-line amendment when this spec lands, because `share api-token` stores a token command or a Keychain item per profile.)

## Decisions for Han

Decided by Han, 2026-09-27:

1. **Rule model:** ship all three forms, `group:`, `email:`, and `domain:`. The OPS-not-contractors case uses `group:dwarves-ops`, an Access rule group Han creates as an email list.
2. **Token:** for Dwarves, `share --profile dfoundation api-token --cmd 'op read op://Toolkit/cf-api-token/credential'`. Probe evidence: that token lists the 4 Access apps and the 0 groups on the Dwarves account, and it cannot mint tokens. The trade-off: it spans 4 accounts (Console Labs, Dwarves LLC, Han Ngo, WeBuild Community), which is broader than share needs. It is acceptable because share reads it only at command time through `op`, and never from the login service (`SHARE_API_TOKEN_OFF`). The dedicated token from the O1 template URL (one account, exactly the scopes in `### API changes`) stays the documented default for new tenants.
3. **Expiry cleanup:** a pending list plus `share prune`. The login service carries no token (`SHARE_API_TOKEN_OFF` in `serve`).

Upkeep once shipped: each login uses a Zero Trust seat until an admin removes it (the Dwarves plan tier and seat cap are UNVERIFIED), and the per-account app cap is UNVERIFIED; TASK-1 records both.

## Decision Log

| Change | Why (validation round 1) |
|---|---|
| Round 8 (build-time review, 2026-09-28): in named mode the main Caddy site answers only its own hostname (plus `127.0.0.1` and `localhost` for local probes) and a catch-all site answers 404; the EXIT trap removes a `--host` name whose ingress rule and CNAME exist but whose row never landed | the picture's "fqdn answers the Caddy default site: no row, no bytes" was wrong: the any-Host default site served the whole `pub` tree, so during a gated `--host` add's wait (up to 900 s) `https://<fqdn>/<other gated id>/f` served another gated share's bytes; quick mode keeps the any-Host site (its hostname is unknown at render time) |
| Round 8: every DELETE first reads the app by id and requires its name to start with `share <id> <host> `; a 404 is done, a mismatch is refused and the line kept; the sweep keeps but never acts on a pending line whose id is not 6 hex, whose app is not a uuid or `-:` plus 8 hex, or whose created field is not a number | a forged row or line plus an account-wide Apps Edit token could delete a foreign app (chat-staff), or trash a path built from `..` |
| Round 8: a delete deferred for lack of a token (prune under the service, `status`) writes its pending line with owner pid 0, dead by definition; `owner_live` never signals pid 0 | `share serve`'s startup prune wrote lines owned by the serve pid, which lives for days, so no sweep ever claimed them and teardown orphaned the app; the hourly prune inherits `SHARE_API_TOKEN_OFF` and never sweeps (the Onboarding section wins over the older "sweeps normally" sentence in `access_sweep`) |
| Round 8: `refresh` swaps the stage into `pub` under the index lock; a rule containing whitespace, a `--cmd` value with a line break, and a pasted token outside `[A-Za-z0-9_-]` are refused; `status` prunes in quiet mode (no token from any source; `ls` keeps the exported-env sweep of `## Onboarding`); teardown trashes `pub/<id>` of a gated row `rows()` rejects, and dies before the tunnel goes when a well-formed pending line survives its sweep; malformed pending lines are counted apart and named as the user's to remove; `add --access --host` resolves the token before `host_check` | a refresh racing rm could republish for a moment; a line break in `email:` silently dropped addresses or injected a config line; a quote in a token reached `security -i`; `status` is a read; a `cmd_rm` that dies inside teardown's pipeline must not let the tunnel and the token go with an app still pending; a `--host` credential message or a DNS lookup must not precede the guided no-token block. The daemon keeps whatever `CLOUDFLARE_API_TOKEN` its shell exported (this section's "`--host` paths keep reading it as today" stands); `SHARE_API_TOKEN_OFF` blanks it for Access only |
| Round 8: the preflight runs `host_zone` only after a token was found, and `access_prepare` (preflight, sweep, group lookup) runs before the stage copy | the guided no-token block must never need the network; failing fast before file I/O is the better order than the picture's "stage copy first" |
| Caddy answers 400 to a raw URI with `%2F` or `%5C`, on every share | measured: `/x/..%2F<path>` and `/%2F<path>` skip a path app at the edge; Caddy decodes and cleans them into the gated path |
| Pending lines carry the owner pid; the sweep skips live pids and decides under the `index` lock; the publish step re-checks its own line under the same lock | a concurrent sweep could delete the app of an add still in its gate wait, which would then publish ungated |
| `teardown` unpublishes gated shares | teardown keeps `pub/` and rows, so a later `setup` would serve gated bytes with no app |
| Intent line `<id> - <pid>` before the POST; the sweep resolves `-` by the fixed app name | a lost POST response would leave an untracked app |
| Gate requires `kid == aud` of the new app | measured: the login redirect's `kid` is the matching app's AUD, so the probe proves this app enforces, not a broader one |
| `cf_try` (non-dying, exposes HTTP status and error code) | `cf()` dies on any error, so "404 counts as done" and the code-9999 hint were not implementable |
| `SHARE_ACCESS_DRY` honoured only with `SHARE_TUNNEL=0` | the seam would otherwise publish a gated-looking row with no app |
| `rand_id` skips pending ids; the sweep trashes only when no row has that id | a new ungated share could land behind a waiting app, or be trashed by the sweep |
| Group lookup filters by name and reads every page; grammar checks avoid regex intervals | paging correctness; `rows()` runs under mawk |
| Pending count in `ls`, `status`, `state`; `ls` warns when a gated row's app is gone | expired apps waiting on a token, or a hand-deleted app, must be visible to a human |
| Approaches F (cloudflared JWT check) and G (own hostname per gated share) recorded | real alternatives; F is the upgrade path if another edge bypass appears |
| Round 2: Caddy reject is a `handle @encsep` block with a path-only match, main host only | a bare `respond` sorts after `handle`, so the reject never ran (reproduced); a whole-URI match broke `%2F` in query strings; `--host` gates are host-wide |
| Round 2: the sweep proves Access read (`GET access/organizations`) before trusting an app list; lookup by a per-add nonce in the app name; all pages | the sweep may run under a different token whose empty list proves nothing; an older same-id app must not match |
| Round 2: owner = pid plus `lstart`, liveness matches `*share*`; the sweep claims a line before any network call; the publisher requires its exact line | `running()` only matches `share serve`; a lost DELETE left the adder's line intact, so the adder would publish with no app |
| Round 2: `cf_try` returns through globals, never `$( )`; the sweep releases the lock around network calls | globals set in a command substitution are lost; a 30 s call under the lock starves writers that wait 60 s |
| Round 3: the app name carries the nonce; the scope table marks Groups Read required; the adder's `-:` to uuid rewrite uses the exact-line check; a proven no-match drops a `-:` line only after 10 minutes; `share serve` never sweeps; `%2E` joins the Caddy reject | the JSON contract disagreed with the lookup and would orphan the app; the sweep proof needs that scope; a late-committing POST; serve's long life would pin a claimed line; defense in depth behind the edge normalization |
| Onboarding round 3: active-zone lookup must be unique (ambiguous otherwise); `ls` uses only an exported env token; the opener is skipped over ssh or with no display; row 33 asserts the Linux 600 file and waits for the stub; row 31 gets the group name; store-then-preflight wording | a 4-account token can see duplicate zones; no `op read` per listing; no text browser on the prompt's terminal; testability |
| Onboarding round 2: `share api-token` with no argument opens the prefilled form and reads a hidden paste; `--cmd` accepts any Access-capable token; groups optional, `email:`/`domain:` shown first; Dwarves uses the existing Toolkit token by `--cmd` | one click plus one paste for a tenant admin; an org with a token skips creation; a new tenant needs no dashboard group to start |
| Round 6: stored token wins over env; the Apps Edit probe accepts only the pinned 400 code; row 30 drops the setup token from the environment | a broad shell token must not replace the Dwarves-only token; a different 403 must not read as ok; O1 must print in the walkthrough |
| Round 5: quickstart precondition (named setup, `--profile`); rows 30/31 start from a set-up HOME with a pre-made group and token; fix URLs point at the account token page; Apps Edit probe passes only on a 4xx validation error; `SHARE_API_TOKEN_OFF` blocks every source including env and the token is never exported; `api-token` requires `need_host`; setup keeps `api_token_cmd`; teardown forgets the stored token; TASK-1 checks user vs account token verify | the quickstart died in `need_host`; the user-token page cannot show an account token; a 5xx must not read as ok; nohup auto-start inherits env; empty-host Keychain key; config and Keychain drift |
| Onboarding: `share api-token` (`--cmd` preferred, stdin, `--check`), one resolver (env, `api_token_cmd`, Keychain/600 file), read-only preflight naming each scope, O1 template URL, O3 rule-group path, fix-naming error lines, README quickstart, rows 27 to 32 | Han's hard requirement: first use is guided, and the storage reuses the `token_cmd` and Keychain pattern |
| TASK-4 split into TASK-4 to TASK-9; e2e (TASK-11) and ADR (TASK-12) tasks added; SPEC-005 dependency stated | atomicity and missing owners |

## Open questions

- Enforcement delay for a new PATH app on an already-routed hostname (TASK-1 measures it).
- Whether inline `policies` objects on app create are accepted (TASK-1).
- Whether Access rollout is per edge location (affects the 3-round gate; residual risk noted).
