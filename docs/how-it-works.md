# How share works

## Architecture

```
                   ┌──────────────────────── Cloudflare ────────────────────────┐
 visitor ─HTTPS──▶ │ s.example.com (proxied CNAME) ─▶ tunnel ingress rule         │
                   │   universal cert *.example.com      s.example.com → :8787   │
                   └───────────────────────────────▲─────────────────────────────┘
                                                   │ outbound QUIC/HTTP2, started by the machine
 your machine ─────────────────────────────────────┼─────────────────────────────────────────
                                                   │
   launchd agent / systemd user unit (foundation.d.share), or `nohup` without the service
     │
   share serve (pid in ~/share/serve.pid)          │
     ├─ cloudflared tunnel run  ────────────────────┘   (TUNNEL_TOKEN from Keychain / file / token_cmd)
     ├─ caddy on 127.0.0.1:<port>
     │     main site (s.example.com, plus 127.0.0.1 and localhost for local probes; quick
     │     mode: any Host, its name is unknown at render time):
     │                   handle_path /<id>/* → reverse_proxy 127.0.0.1:<live port>  (live shares)
     │                   handle /healthz → respond "ok" 200                         (health probe)
     │                   handle → file_server over ~/share/pub                      (snapshots)
     │     per --host share: site block on <fqdn>:<port> → reverse_proxy or file_server
     │                   + a tunnel ingress rule pinning httpHostHeader to <fqdn>
     │                   + a CNAME <fqdn> → <tunnel>.cfargotunnel.com
     │     any other Host (named mode): a catch-all site answers 404, so a name routed
     │                   here before its own block exists never reaches the pub tree
     │     headers: Cache-Control no-store, X-Robots-Tag noindex
     │     main host: a raw path with %2F, %5C, or %2E answers 400 (@encsep, the first
     │     handle): the Access edge does not decode those, Caddy would, so an encoded
     │     separator must never reach a gated pub/<id>
     │     no directory listing; folder index = index.html, then README.html,
     │     else a generated listing (unless --no-index); site root still 404s,
     │     so probes use /healthz
     │     admin API on unix socket ~/share/admin.sock (owner-only); Caddyfile is
     │     re-rendered from index.tsv and caddy reload runs on add / rm / refresh / prune
     │     JSON access log → ~/share/access.log
     └─ prune loop: every hour, unpublish expired shares
```

`share setup --quick` writes `mode=quick` instead of a hostname and tunnel id. In that mode `share serve` runs `cloudflared tunnel --url http://127.0.0.1:<port>` (no token, no DNS, no account) and scrapes the random `https://<x>.trycloudflare.com` URL out of `cloudflared.log` into `quick.url`; links and `status` read the hostname from there. The URL is new on every serve start, so `--host` is refused and old links die. Caddy, `index.tsv`, live shares, and the folder index behave identically.

With the service installed, launchd (macOS) or systemd (Linux) starts `share serve` at login and restarts it after a crash. `share start` and `share stop` load and unload the service. Without it, `share start` runs `share serve` under `nohup`, and `share stop` sends it SIGTERM. Either way, the exit trap stops caddy, cloudflared, and the prune loop together.

The launchd agent's first program argument is the `share` script itself, so the macOS Login Items list shows "share" rather than a generic shell. Its `PATH` holds the directories of caddy, cloudflared, and the other tools, because launchd starts agents with a minimal `PATH`.

## Files on disk

```
~/share/                    SHARE_ROOT
├── pub/                    the only tree the tunnel can reach
│   ├── 62cb50/guide/...    one directory per share id
│   └── 84cbfe/note.txt
├── index.tsv               id, name, source path, added date, expiry epoch (0 = never), opts
│                           opts is a space-separated list: `live`, `host=<fqdn>`, `noindex`,
│                           `access=<Access app uuid>` with `access_rule=<rule>` for a gated share
├── access-pending          every Access app not, or no longer, backed by a finished row:
│                           share id, app uuid (or -:<nonce> while a create is unanswered),
│                           owner pid, owner start time, created epoch
├── Caddyfile               re-rendered from index.tsv at serve start and on add / rm / refresh / prune
├── admin.sock              caddy admin API, unix socket inside the 0700 share root
├── .lock-host/             mkdir mutex serializing Cloudflare ingress edits
├── access.log              caddy JSON log, read by `share hits`
├── serve.pid  serve.log  caddy.log  cloudflared.log
├── quick.url               quick mode only: the trycloudflare fqdn cloudflared printed last start
├── md-links.lua            pandoc filter that rewrites .md links to .html
└── md-style.html           the reading stylesheet, shared by renders and generated indexes

~/.config/share/            SHARE_CONFIG_DIR
├── config                  key=value, written by setup; `api_token_cmd=` from `share api-token --cmd`
├── tunnel-token            Linux only, mode 600 (macOS uses the Keychain)
├── api-token               Linux only, mode 600, from `share api-token` (macOS: Keychain item `share-api:<host>`)
├── cert.pem                browser-login path only, mode 600
├── cert.zone               the zone that cert.pem was issued for
└── profiles/<name>/        a named profile's config dir, same files; its root is ~/share/profiles/<name>
```

An r2 profile keeps far less. Its config holds `backend=r2`, `hostname`, `zone`, `bucket`,
`port=r2` (a sentinel an older share dies on at load), `r2_endpoint`, and a kept
`api_token_cmd`. Its root holds `r2-own` (`<id>`, prefix, source path for every share this
install added; `refresh` trusts only this file), `access-pending` for its own gated adds,
and short-lived `.r2-index.XXXXXX` snapshots. There is no `pub/`, `index.tsv`, Caddyfile, or
tunnel token.

## Profiles

`share --profile <name> <verb>` (or `SHARE_PROFILE=<name>`) runs a second, independent
setup beside the default one: another Cloudflare account, another hostname, or both.
No flag, or the name `default`, is the setup every path above describes, unchanged. A
name is a slug (`^[a-z0-9][a-z0-9-]{0,31}$`), checked before any path is built; the flag
goes before the verb, and a `--profile` after the verb is refused rather than ignored.

| Item | default | profile `<p>` |
|---|---|---|
| config dir | `~/.config/share` | `~/.config/share/profiles/<p>` |
| root | `~/share` | `~/share/profiles/<p>` |
| service label | `foundation.d.share` | `foundation.d.share.<p>` (its plist carries `SHARE_PROFILE`) |
| Keychain item | `share-tunnel:<host>` (account `share`) | `share-tunnel.<p>:<host>` |
| port, metrics port | `8787`, `8788`, or `port=` | picked at the first setup: the lowest odd port from 8789 whose pair no other profile claims and nothing listens on, then kept in `port=` |

Profiles share nothing. The only cross-profile logic is two read-only scans of the
derived locations: the other profiles' config files, for three refusals (the port pick,
`share add <port>` of another profile's port or metrics port, and `share setup` on a
hostname or tunnel name another profile already holds), and every profile's `index.tsv`,
so the port pick skips a port any profile live-shares. A profile moved with `SHARE_ROOT`
or `SHARE_CONFIG_DIR` is invisible to both scans. `share serve` also refuses a port that
already answers (caddy binds with SO_REUSEPORT, so two
servers on one port would split requests silently); that guard covers the default
profile too. `share profiles` lists the default and every directory under
`~/.config/share/profiles` with its state and host, read through each profile's own
`share state`. `share teardown` on a named profile also removes its config dir when
empty; the root with its shares stays, as for the default. Share Bar reads every
profile in one `profiles --json` call and renders a section per profile; the status
icon shows the worst health across sections, while `not_setup` and elsewhere
profiles stay neutral and never darken it on their own.
Why a profile is a path prefix rather than a config key: [ADR-0005](decisions/ADR-0005-profile-is-a-path-prefix.md).

## Lifecycle of a share

```
share add ./guide
  realpath ./guide                  resolve a symlinked argument to its real path
  id = 6 random hex chars           from /dev/urandom
  stage = ~/share/.stage.XXXXXX
  find guide -name '.*' -prune -o -type f -print  →  cp -p each file into stage
                                    only regular files: dotfiles and symlinks never ship
  pandoc every *.md → sibling .html (skipped when pandoc is absent or the .html exists)
                                    an inline reading stylesheet (light and dark); KaTeX from the CDN only for pages with $ math
  mv stage → pub/<id>               an atomic swap, so a refresh never serves half a copy
  append the row to index.tsv
  print + pbcopy the link, warn if the source repo is private on GitHub
  share start if nothing is serving and this host is in `hosts`; caddy reload if it is
```

A live share skips the copy entirely:

```
share add 3000
  parse_target: a bare port / localhost:port / http://localhost:port is a live target
  port must be 1024..65535 and not caddy's or cloudflared's own ports
  opts = "live", src = http://127.0.0.1:3000
  append the row, render handle_path /<id>/* → reverse_proxy, reload
  print https://<host>/<id>/ plus the warning: the link reaches that port while the machine is awake
```

`--host dev.example.com` wraps either kind in its own hostname. Order of writes: tunnel ingress rule (inserted before the catch-all, carrying `httpHostHeader`), then the CNAME, then the index row; `share rm` deletes the CNAME, then the ingress rule, then the row. Every Cloudflare-side edit runs under the `.lock-host` mutex and refuses a tunnel config whose invariants were changed outside share. The name must be a single label under the setup zone because Universal SSL stops at one level.

### A gated share (`--access`)

```
share add ./ops-report.pdf --access group:dwarves-ops        (or email:a@x,b@y; or domain:d.foundation)
  preflight        the API token (api_token_cmd, then the Keychain item share-api:<host> or the
                   600 file, then CLOUDFLARE_API_TOKEN), one read per scope, each line ok or MISSING
  sweep            access-pending: dead owners' apps deleted, orphaned bytes trashed (below)
  group lookup     GET access/groups, exact name match over every page (group: only)
  stage copy       ~/share/.stage.XXXX, outside pub: nothing to serve yet
  intent line      access-pending += "<id> -:<nonce> <pid> <start> <now>", BEFORE the POST
  create app       POST access/apps {name "share <id> <host> <nonce>", destinations <host>/<id>,
                   <host>/<id>/* (+ the --host fqdn), one allow policy}; the line gets the uuid;
                   read-back: the destination set and a policy, else delete and die
  [--host]         ingress rule + CNAME, as any --host share
  gate             curl https://<host>/<id>/, /<id> (and https://<fqdn>/) until every one 302s to
                   https://<team>.cloudflareaccess.com/cdn-cgi/access/login/<host> with kid == the
                   app's aud, three rounds in a row; SHARE_ACCESS_WAIT (900 s) caps it, a timeout
                   deletes the app and publishes nothing
  publish          under the index lock, only while this process's exact pending line is still
                   there: mv stage -> pub/<id>, the row (access=<uuid> access_rule=<rule>), render,
                   reload, drop the line
  print + copy     the id is secret until this line
```

Removal flips the order: `share rm <id>` (with the token) puts the line back, removes the
bytes and the row, reloads, then deletes the app (a 404 counts as done) and drops the
line. Expiry under the login service has no token (`share serve` exports
`SHARE_API_TOKEN_OFF=1`, which blanks every token source): the bytes and the row go, the
app waits in `access-pending`, and `ls`, `status`, and `state` say so until an
interactive `share prune`, `rm`, `ls` (with an exported `CLOUDFLARE_API_TOKEN`), or `add
--access` sweeps it. `teardown` refuses without a token while any gated row or pending
line exists, and with one it unpublishes every gated share before the tunnel goes, so a
later `setup` can never serve gated bytes with no app.

The sweep, on every pending line: a live owner (pid alive, a share process, the same
start time) is skipped; a line whose share has a finished row is dropped; the rest are
claimed under the index lock (owner rewritten to the sweeper, orphaned `pub/<id>`
trashed first), then, with no lock held, each app is deleted. A `-:<nonce>` line is
resolved by the app name's last word, and only after `GET access/organizations`
answered 200 in this run: a list read without the scope is empty and proves nothing. A
proven no-match is forgotten only when the line is older than 10 minutes.

`share ls` with `CLOUDFLARE_API_TOKEN` exported (never through `api_token_cmd` or the
Keychain, so a listing never runs `op read`) reads each gated row's app by id and prints
`the link is PUBLIC` on a 404. A hand-edited row whose `access=` is not a lowercase uuid
or whose `access_rule=` fails the rule grammar is skipped like any forged row; its app,
if any, stays until removed in the dashboard.

`share refresh <id>` runs the same copy from the recorded source path and swaps it in under the same id (a live share is a no-op). `share rm <id>` moves `pub/<id>` to the Trash (or `~/share/trash` without a `trash` command) and drops the row. An own-host share (`--host`) refuses to be removed without a Cloudflare credential (`CLOUDFLARE_API_TOKEN` or a `share setup --login` cert), so its DNS record and ingress rule are never orphaned. `prune` still removes an expired one and warns that they stay behind.

## R2 backend

A profile set up with `--backend r2` has no tunnel, no caddy, and no login service. Its
snapshots live in a private R2 bucket, and a Worker on the profile's hostname serves them.
Every publisher's CLI talks to the bucket directly.

```
 publisher A (Mini)        publisher B (laptop)                   visitor
 share --profile df add    share --profile df add                 https://f.example.com/<id>/<name>
        │                         │                                          │
        │ S3 API: curl --aws-sigv4, key id = token id,                       ▼
        │ secret = sha256(token) from stdin (never argv, never a file)   Cloudflare edge: TLS; an
        └────────────┬────────────┘                                   Access app on /<id>, /<id>/*
                     ▼                                                for each gated share
 R2 bucket <bucket> (private: no r2.dev URL, no custom domain)                │
   share.json                 marker: {"v":1,"host":"<hostname>"}             ▼
   m/<id>                     one record per share   ◀──────────  Worker share-<host-with-dashes>
   o/<id>.<nonce>/<path>      the snapshot bytes     ◀──────────  (custom domain only; workers.dev
                                                                    and previews off)
                                                                     │
 local, per install: r2-own (own adds), access-pending               └─▶ Analytics Engine dataset
                                                                         share_<host_with_underscores>
```

The transport is the R2 S3 API, not the account REST API: a token scoped to one bucket
works only there, and only S3 honors conditional writes (`If-None-Match`, `If-Match`).
Object calls never touch the account API rate limit. Each call retries 429 and 5xx up to
three times, honoring `Retry-After` up to 30 s. An upload runs as one `curl --parallel`
with up to 8 transfers, and a failed transfer is retried alone.

### Objects and records

| Key | Content | Written by |
|---|---|---|
| `share.json` | `{"v":1,"host":"<hostname>"}` | the admin setup |
| `m/<id>` | the record: `v`, `id`, `name`, `src`, `added`, `expires` (epoch seconds, `0` = never), `opts` (`noindex`, `access=<app uuid>`, `access_rule=<rule>`), `prefix` (`o/<id>.<nonce>/`), `by` (the publisher's machine name, for display), and `aud` (the Access app's AUD tag) on a gated share | `add` with `If-None-Match: *`; `refresh` with `If-Match: <etag>`; deleted by `rm` and `prune` |
| `o/<id>.<nonce>/<path>` | the stage tree byte for byte, the same one `stage_copy` builds for a tunnel share (dotfiles and symlinks excluded, `.md` rendered, a generated `index.html` for a folder without one unless `--no-index`) | `add`, `refresh` |

The record is the publish. The Worker reaches bytes only through `m/<id>`, whose `prefix`
names exactly one upload, so an upload that no record names is never served. `add`
uploads every file to a fresh `o/<id>.<nonce>/`, checks that the prefix listing equals the
stage file for file, then writes `m/<id>` with `If-None-Match: *`. A 412 there means
another publisher took the id; the add dies and deletes its own upload. The EXIT trap
deletes a held upload only after a fresh `GET m/<id>` shows no record names it, so a record
write that committed but answered with an error keeps its bytes. `rand_id` on r2 skips an
id that has a record or any key under `o/<id>.`.

An add refuses before the first upload when the stage holds more than `SHARE_R2_MAX_FILES`
(500) files, a file over `SHARE_R2_MAX_BYTES` (300 MiB), or a file name with a control
character.

`ls`, `prune`, `state`, and `rm` read a snapshot: the `m/` listing (every page), then every
record in one parallel curl run. A record whose `id` differs from its key, whose `prefix` is
not `o/<id>.` plus 8 hex plus `/`, whose `v` is newer than this share knows, or whose fields
hold a control character is dropped, like a forged `index.tsv` row. Any listing or record
read that fails (other than a 404) stops the verb: share never prints an empty list or
picks an id on an error. The snapshot goes to a temporary `.r2-index.XXXXXX` under the root
that `index` points at for the process, so `rows()` stays the only reader.

### The Worker

The Worker holds no API token. Its source is embedded in `bin/share`, versioned by
`WORKER_VERSION` and `WORKER_SHA`, and deployed by the admin setup with the bindings
`BUCKET`, `HITS`, `HOST`, `TEAM` (the Access team domain, empty without one), `VERSION`,
`SHA`, and a `SALT` secret set at the first deploy. Every request runs these checks in
order; the first that matches answers.

| # | Request | Answer |
|---|---|---|
| 1 | Host is not exactly the profile's hostname (a trailing dot or another name fails) | 404 |
| 2 | method other than GET or HEAD | 405 |
| 3 | the raw path holds `%2F`, `%5C`, `%2E` (any case), an escape of a byte below 0x20, or `//` | 400 |
| 4 | `/healthz` | `200 ok`, with `X-Share-Worker: <VERSION> <SHA>` and `X-Share-Gate: 1` (an Access team is set) or `0` |
| 5 | first segment is not exactly 6 lowercase hex characters (no decoding: `/ABC123/` and `/%61bc123/` fail) | 404 |
| 6 | no `m/<id>`; a record that is not JSON, whose `v` is newer than the Worker's, whose `id` is not the key's, or whose `prefix` is not `o/<id>.` plus 8 hex plus `/`; or `expires > 0` and past, checked on every request | 404 |
| 7 | a gated record (an `aud`, or `access=` in `opts`) without a valid Access JWT: `Cf-Access-Jwt-Assertion`, RS256, signed by a key from `https://<TEAM>/cdn-cgi/access/certs`, `iss` `https://<TEAM>`, `aud` holding the record's `aud`, `exp` in the future. `TEAM` empty or the certs unreachable also fail | 404 |
| 8 | `/<id>` | 308 to `/<id>/` |
| 9 | a path ending in `/` | the decoded folder's `index.html`, then its `README.html`, else 404 (a malformed escape answers 400) |
| 10 | any other path | the object at the decoded path (a malformed escape answers 400); missing, but `<path>/index.html` or `<path>/README.html` exists: 308 to `<path>/`; else 404 |
| 11 | every answer, errors included | `Cache-Control: no-store`, `X-Robots-Tag: noindex, nofollow` |

`Content-Type` comes from a fixed extension map, `application/octet-stream` otherwise.
`Range` and conditional request headers pass through to R2. The certs are cached in the
isolate for an hour and refetched at most once a minute on an unknown `kid`; a failed
fetch is never cached. Expiry is enforced here, per request, so a link dies at its second
whether or not anyone has pruned.

The JWT check is what keeps a gated share closed whatever the edge does: a path the Access
app did not match, a hand-deleted app, or a stale gate reaches the Worker with no valid
token for the record's `aud`, and gets 404. Every served path starts with `/<id>/` or is
`/<id>`, both inside the app's destinations.

### Gated shares on r2

`add --access` keeps the tunnel's order, with the record write as the publish:

```
share --profile df add ./report.pdf --access group:ops
  /healthz         X-Share-Gate must be 1, else refused before any write
  preflight        the Access scopes, the sweep, the group lookup (as on a tunnel)
  upload           every file to o/<id>.<nonce>/, the listing checked against the stage
  create app       intent line in access-pending, then the Access app
                   "share <id> <host> <nonce>" (the upload's nonce); its aud must be 64 hex
  gate             the three-round kid == aud check, capped by SHARE_ACCESS_WAIT (900 s);
                   a timeout deletes the app, and the EXIT trap deletes the upload
  publish          under the index lock, only while the pending line is still there:
                   PUT m/<id> with If-None-Match: * and the app's aud; drop the line
```

No record exists during the gate wait, so the Worker answers 404 behind the login. A 412
on the publish deletes the app and the upload. Removing a gated share needs Access: Apps
and Policies Edit: `rm` runs the Apps Edit probe before any change, adds a pending line,
deletes `m/<id>`, and continues only when a fresh `GET m/<id>` answers 404. Then it deletes
every object under `o/<id>.` (every nonce) and, last, the app. The r2 sweep of
`access-pending` decides with a fresh `GET m/<id>`, never the snapshot: a record naming the
line's app means the add finished, and the line is dropped. A 404, or a record naming another
app, means the app is deleted; on a 404 the upload under that app's own nonce goes after it.
Any other answer keeps the line. `ls` does not check gated apps on r2, as it does on a
tunnel: a deleted app leaves the link closed, because the Worker checks the JWT itself.

### Several publishers

| Action | Who |
|---|---|
| `add`, `ls`, `hits` | any publisher; `ls` shows every share with `by=<machine>` |
| `rm` | any publisher, for any share; a gated one needs the Access scope |
| `refresh` | only the install that added the share: its id must be in the local `r2-own` file (`<id>`, prefix, source path) with the prefix the record still names. The source path comes from `r2-own`, never from a record another publisher could forge. The upload goes to a new nonce, the record swaps with `If-Match: <etag>` (a 412 or 404 means a concurrent `rm` or `refresh` won; the new upload is deleted), then the old prefix goes |
| expired shares, orphan uploads | any publisher's `ls` or `prune` (below) |

### Expiry and cleanup

The Worker already answers 404 for an expired record. The record and its bytes go at the
next `ls` or `prune` by any publisher. An expired gated share goes only through a process
whose token passes the Apps Edit probe (for `ls`, only an exported `CLOUDFLARE_API_TOKEN`);
otherwise it stays whole and each run prints `expired gated share <id> waits for a publisher
with the Access token`. `status` counts them and never deletes.

A bare `prune` then sweeps orphan uploads: every `o/<id>.<nonce>/` that no record names and
whose newest object is over 24 hours old is deleted (a crashed add, or a revoked token that
could not clean up after itself). The sweep reads every `m/` record raw, not the filtered
snapshot. One record that is not JSON, lacks a `prefix`, or has a `v` newer than this share
skips the whole sweep with a warning naming its key, so no live share's bytes are deleted
because this CLI could not read its record. `status` prints `orphan sweep blocked by <key>`.

### Hits

The Worker writes one Analytics Engine data point for every answer under 400 on a share
path (not `/healthz`): index the share id, blobs the id and the first 16 hex of
`sha256(SALT + cf-connecting-ip)`. The raw IP is never written; the salted hash
pseudonymizes visitors, it does not anonymize them. `share hits <id>` checks the id against
`^[0-9a-f]{6}$`, then sends one SQL query:
`SELECT SUM(_sample_interval) AS hits, COUNT(DISTINCT blob2) AS visitors, MAX(timestamp) AS last`
over the profile's dataset for that id. It needs a token with Account Analytics: Read,
which reads every dataset on the account.

## Tenants: one hostname, local or cloud

A tenant is one hostname with one shared list. Its origin is the one machine in the tunnel profile's `hosts`; every link is served from that machine's disk through its tunnel unless the admin turns R2 on. The mechanism and its trade-offs: [ADR-0008](decisions/ADR-0008-one-host-per-tenant.md).

```
 visitor  https://s.example.com/<id>/<name>        https://f.example.com/<path>  (alias)
                       |                                        | 301 to the tenant host
                       v                                        v
 Cloudflare edge: TLS; an Access app on <host>/<id> and <host>/<id>/* per gated link
                       |
        R2 off         |         R2 on
   CNAME to the tunnel |   Worker share-<host-with-dashes> on route <host>/*
                       |     GET m/<id> from the bucket
                       |       cloud record (v:1)           -> R2 bytes
                       |       machine pointer (v:2), none  -> fetch(request): the route is
                       |         or an R2 error                skipped, the request goes on
                       v                                       to the origin
   tunnel --> cloudflared on the origin --> caddy --> pub/<id> or a live port
```

| Tenant state | Origin | Other machines |
|---|---|---|
| R2 off (default) | publishes everything locally, today's code paths and files | none; `setup --quick` stays available |
| R2 on | publishes local or cloud per link; keeps the tunnel and gains `bucket=`, `r2_endpoint=`, `storage_default=` (and `aliases=` after a fold) in its config | members: an r2 profile joined with a bucket-scoped publisher token; they publish cloud links only |

### Per-link storage

| `add` form | R2 off | R2 on, `storage_default=local` | R2 on, `storage_default=cloud` |
|---|---|---|---|
| `add <file\|dir>` | local | local | cloud |
| `add --cloud <file\|dir>` | refused, naming the admin command | cloud | cloud |
| `add --local <file\|dir>` | local | local | local |
| `add <port>`, `--host` | local | local | local |

`--cloud` with a port, `--host`, or `--local` is refused. A member's `--local` and `add <port>` die with `<host> serves local links from its origin`. `rm`, `refresh`, and `hits` dispatch on the row's storage; a member's `rm` or `refresh` of a machine row dies before any call, because only the origin serves it.

### Enabling and leaving R2

`CLOUDFLARE_API_TOKEN=<admin> share setup <host> --r2 --bucket <name> [--storage-default local|cloud] [--alias <old-host>]` runs on the origin only. Every read and refusal comes before the first write, and a rerun after a die converges. The order matters: the Worker is deployed with subdomain and previews off, pointer records are written for every local row, the config keys are written, the marker moves, the route is attached, and live checks (`/healthz` three times with this CLI's version pair, a probe file through the tunnel leg) pass last.

With `--alias <old-host>` the tenant Worker takes the alias's custom domain and answers 301 to the same path on the tenant host. Each gated cloud link's Access app gains the tenant destinations first (the PUT keeps the AUD), passes the gate probe, and drops the alias destinations last. A folded app keeps its name `share <id> <alias> <nonce>`, so `rm` and expiry still delete it.

`share setup <host> --no-r2` is the rollback for a tenant without an alias: the route goes, then the four config keys. The tunnel serves the hostname alone again; pointers, cloud records, the bucket, and the Worker stay. It refuses while an alias is set, because an alias whose 301 lands on a plain tunnel turns every folded cloud link into a 404. Every die after the marker moved prints the alias rollback list instead.

### Pointer records

With R2 on, a local add on the origin writes `m/<id>` as `{"v":2,"id","storage":"machine","name","by","added","expires","opts","type"}` after the stage is built and before the file is published (before the Access app for a gated add). The write carries `If-None-Match: *`, so one namespace spans both storages and a cloud add can never take an id the origin holds. `opts` keeps only `noindex`, `live`, and `gated`, never the rule. A failed pointer write dies before anything is served: a local add fails closed while R2 is on.

`rm` and `prune` of a local row delete its pointer when a token resolves. The origin's interactive `ls` and `prune` reconcile: a pointer with no local row and a `LastModified` over 10 minutes old is deleted (an add that died), and a local row with no pointer gets one. A local row whose id already holds a cloud record prints `<id> is shadowed by a cloud link; rm one of them` and nothing is deleted.

Cloud records stay `v:1` (with an optional `type`), so a v0.8.0 CLI and Worker keep reading every cloud link. A machine pointer is `v:2` and `WORKER_RECORD_V` is 2; an older Worker answers 404 for it.

### One shared list and its fields

`ls`, `state`, and `profiles --json` read one row set per profile: the local index on an origin with R2 off, the local index plus every cloud record on an origin with R2 on, and every bucket record on a member. A record read from the bucket is display data only: it never enters `rows()`, the index, the Caddyfile, a stage path, `refresh`, or shell arithmetic, and every field is checked before it is shown. A bucket read that fails leaves the local rows and adds `cloud_error`.

`state` and `profiles --json` read the bucket only with a token from the Keychain item or the mode-600 file (never an `api_token_cmd`, which may prompt during a poll) and fetch the newest 25 records; `cloud_more` counts the rest. `share ls` prints one tag before each link (`cloud`, `machine`, or `live`), then the type and `by=<machine>`.

| `type` | First match wins |
|---|---|
| `site` | a live link; a folder with `index.html` at its root; a single `.html` or `.htm` file |
| `folder` | any other folder |
| `markdown`, `pdf` | `.md` `.markdown`; `.pdf` |
| `image`, `video`, `audio` | `.png .jpg .jpeg .gif .webp .svg .heic .ico .avif`; `.mp4 .mov .webm .m4v .mkv`; `.mp3 .wav .m4a .aac .flac .ogg` |
| `archive`, `text` | `.zip .tar .gz .tgz .bz2 .xz .7z .rar .dmg`; common text and source extensions |
| `other` | anything else |

The extension match ignores case. Local rows are typed at read time; new cloud records and pointers store `type`; a `v:1` record without it is typed by its name.

### The Worker on a tenant

Bindings are SPEC-007's set plus `PASS="1"` (pass misses to the origin) and `ALIASES` (comma list). Checks run in this order:

| Request | Answer |
|---|---|
| Host in `ALIASES` | GET or HEAD: 301 to the tenant host, same path and query; other methods 405 |
| Host not exactly `HOST` | 404 |
| raw path holds `%2F`, `%5C`, `%2E`, a low escape, or `//` | 400, in front of the tunnel leg too |
| `/healthz` | the Worker's own answer; with `PASS`, also a 3 s probe of the origin's `/healthz`: `200` and `X-Share-Tunnel: 1`, else `503` and `X-Share-Tunnel: 0` |
| `v:1` record, no `storage` | SPEC-007's checks, then R2 bytes |
| `v:2` machine pointer, no record, or `BUCKET.get` throwing or over 2 s | `PASS` set: pass through; else 404 |
| any other record shape | 404, never passed through |

A pass-through goes back with its status and body unchanged and `no-store` and `noindex` set. Only a failed fetch, 530, 520 to 527, or a 503 without `cf-cache-status` (the origin's own answers carry it, edge errors do not) becomes the 503 offline page with `Retry-After: 60`. A 502 is the origin's own answer, such as a dead live port, and passes through. A 101 WebSocket answer goes back untouched.

Callers read the cloud leg from the `/healthz` headers, never the status alone: a `503` with a valid `X-Share-Worker` pair and `X-Share-Tunnel: 0` means the Worker is up and the origin is down, so a member's join, a gated member add, and an r2 `state` keep working while the origin is off.

### Moving an origin: `migrate` and `import`

`share migrate --to <ssh-target> [--remote-profile <name>] [--remote-bin <path>] [--max-bytes <n>] [--yes]` runs on the current origin while it is online, with `CLOUDFLARE_API_TOKEN` in the environment. It moves a tenant with R2 off and refuses one with `bucket=`.

```
 old origin                                         new origin, over ssh
 1 preflight: named tunnel profile, this host       import --probe; the profile is not_setup or set
   in hosts, no --host row, the token resolves      up for the same hostname; Keychain round trip
 2 per snapshot row: tar | ssh -------------------> import <id> ...  validates, stages, publishes
 3 the switch, token on ssh stdin ----------------> setup <host> --tunnel-name <old>-m --force
                                                      --token-stdin  (a new tunnel, CNAME repointed)
 4 verify through https://<host>/: a probe file only the new origin holds answers 200 three times,
   then every moved link answers 200 and every gated one 302 with kid == its app's AUD
 5 retire: rows to index.migrated, pub/<id> to migrated/<id> (nothing deleted), then the
   teardown path with no Access delete and no DNS delete unless it still points here
```

`import` is the receiving verb and validates every field and every tar member (no `..`, absolute path, symlink, or hardlink) before it publishes. Live rows are listed as not moved and a `--host` row blocks the move. The new origin always gets its own tunnel: a name the old machine already holds would reuse its tunnel id, and the retire step would then delete the new origin's only tunnel (`migrate_retire` also refuses that delete if the ids ever match). A failure in the switch prints the rollback, `setup <host> --tunnel-name <old name> --force` on the old machine; a tunnel name missing from the config is read back from the API by id. `SHARE_MIGRATE_SSH` replaces the ssh command with a local one so the suite runs both sides on one machine.

Files `migrate` adds on the old origin: `index.migrated` and `migrated/<id>`. A moved row's `src` becomes `<by>:<src>`, and `refresh` of such a row dies with `re-add it from a source on this machine`.

## `share state`

The menu bar app never reads share's files. It runs `share profiles --json`, a read-only
verb that prints every profile's `state` snapshot (or a per-profile error line) and exits
0; each `state` object is the same read-only snapshot the `share state` verb prints:
not set up, stopped, or serving. Every per-profile call the app makes carries
`--profile <name>` before the verb, `default` included, and its children drop the
location overrides (`SHARE_ROOT`, `SHARE_CONFIG_DIR`, `SHARE_PORT`, `SHARE_HOSTNAME`,
`SHARE_HOSTS`, `SHARE_SERVICE_LABEL`) plus `SHARE_PROFILE`, so no verb resolves a setup
the menu did not show.
The app changes anything only by running share's normal verbs (`add`, `rm`, `refresh`,
`start`, `stop`, `setup`); why that split exists: [ADR-0003](decisions/ADR-0003-menu-bar-reads-through-cli.md).

```json
{
  "schema": 1,
  "state": "serving",
  "ready": true,
  "mode": "named",
  "host": "s.han.ws",
  "hosts": "hans-air-m4",
  "serves_here": true,
  "service": true,
  "access_pending": 0,
  "shares": [
    {"id": "3d324a", "name": "theme-check.md",
     "url": "https://s.han.ws/3d324a/theme-check.html",
     "kind": "snapshot", "own_host": null, "expires": 1759000000, "access": null}
  ]
}
```

| Field | Values |
|---|---|
| `schema` | integer, `1` |
| `state` | `serving` (pid alive), `stopped` (set up, not running), `not_setup` (no hostname and not quick mode) |
| `ready` | whether a live check succeeded for the current mode and state; `false` whenever not serving |
| `mode` | `named` or `quick` |
| `host` | named mode: the configured hostname. quick mode: the live `trycloudflare.com` URL while serving, else `null` |
| `hosts` | the `hosts=` config value, `""` when unset |
| `serves_here` | whether this machine is in `hosts` |
| `service` | whether the login service is installed |
| `shares[]` | ordered newest first, same rows `share ls` prints |
| `shares[].kind` | `live` for a live proxy, else `snapshot` |
| `shares[].own_host` | the share's own `--host` value, else `null` |
| `shares[].expires` | epoch seconds; `0` means never |
| `shares[].url` | exactly what `share ls` prints for that row |
| `shares[].access` | the `--access` rule of a gated share (`group:...`, `email:...`, `domain:...`), else `null` |
| `shares[].storage` | `machine` (served by the tenant's origin through its tunnel) or `cloud` (served from the bucket) |
| `shares[].type` | the file type: `pdf`, `image`, `video`, `audio`, `folder`, `site`, `markdown`, `archive`, `text`, or `other` |
| `shares[].by` | the machine that published the share |
| `r2` | `true` when the profile reads a bucket (an origin with R2 on, or an r2 profile), else `false` |
| `storage_default` | an origin with R2 on only: `local` or `cloud`, the storage of an `add` with neither `--local` nor `--cloud` |
| `cloud_error` | why the bucket's rows are missing (the menu reads them only with a stored token); the local rows still list |
| `cloud_more` | how many more bucket rows exist past the newest 25 that `state` reads; about, since it counts orphan pointers too |
| `access_pending` | count of Access apps waiting for deletion (`access-pending` lines) |
| `skipped` | count of malformed index rows; present only when greater than zero |
| `backend` | `"r2"` on an r2 profile only, absent on a tunnel profile. There `state` is `serving` once set up, `ready` comes from one `/healthz` probe (2 s), `mode` is `named`, `hosts` is `""`, `serves_here` and `service` are `false`, every share is a `snapshot`, and `skipped` is never set. Share Bar shows neither Start nor Stop for it |

Invariants: `state` never prunes, never writes or creates a file, never needs a TTY,
and never touches the clipboard. Removing or renaming a field bumps `schema`; adding a
field does not, so an older app can still read a newer CLI. An index row with exactly 5
tab fields (the shape share wrote before this version) reads with empty opts; a row is
skipped, and counted in `skipped` instead of breaking the read, when it has fewer than 5
or more than 6 fields, when its id is not exactly 6 lowercase hex characters, or when its
`host=` opt is the main hostname or not a valid hostname.

## Why each choice

| Choice | Reason |
|---|---|
| Copy, not serve the source in place | A share must outlive its source. The first version served folders in place; its links broke when a git worktree was removed. |
| Random id in every link | "Anyone with the link" should not mean "anyone who guesses `preview.html`". |
| No directory listing | Nobody can browse from the root to other shares. A shared folder without an index gets a generated listing of its own files; the site root `/` never gets one, and `--no-index` keeps the old 404. |
| Path prefix for live shares, not a random subdomain | `<id>.s.example.com` needs a second-level wildcard cert, which Universal SSL does not issue. `handle_path /<id>/*` costs no DNS; `--host <label>.<zone>` covers apps that need the root. |
| `httpHostHeader` pinned per ingress rule | Caddy routes by Host; a visitor-supplied Host of another share must not reach it, so cloudflared sets the origin Host to the share's own hostname. |
| One Access app per gated share, observed before the bytes move | Measured on the live edge: a new app takes seconds to minutes to enforce, and `kid` in the login redirect is the matching app's AUD. Publishing only after three rounds of `kid == aud` means the bytes are never reachable ungated, and deleting by stored id at `rm` means no app outlives its link. Detail: [ADR-0006](decisions/ADR-0006-access-gate-per-share.md). |
| `400` on `%2F`, `%5C`, `%2E` at Caddy, main host only | Measured: the edge matches a path app after normalizing case, `//`, and `%2e%2e`, but does not decode `%2F` or `%5C`; Caddy decodes and cleans them, so `/x/..%2F<id>/f` would reach `pub/<id>/f` past the gate. A `handle` block, because a bare `respond` sorts after `handle`. `--host` sites are gated host-wide and keep their paths. |
| The login service never holds the API token | `share serve` exports `SHARE_API_TOKEN_OFF=1`; a daemon that runs for days would pin a claimed pending line, and a token in its environment would reach every child. Expired apps wait for an interactive `share prune`. |
| Ports below 1024 and share's own ports refused | `share add 80` or `add $metrics_port` would publish a system service, not a dev server. There is no override flag. |
| Admin API on a unix socket | `caddy reload` applies add/rm without a restart, and a socket inside the 0700 share root listens on no TCP port. |
| `Cache-Control: no-store` | Tested live without it: Cloudflare cached an image (`cf-cache-status: HIT`) and kept serving it with 200 after the server had stopped. With the header, every request shows `BYPASS`, and `rm` returns 404 at once. |
| `X-Robots-Tag: noindex, nofollow` | A link pasted somewhere public should not end up in search results. |
| Copy only regular files | A symlink inside a shared folder could point at `~/.ssh`. The copy uses `find -type f` rather than rsync: macOS ships openrsync, which accepts `--safe-links` but copies outside-pointing links anyway. |
| One serving host (`hosts`) | Cloudflare load-balances between every connector on a tunnel. Two machines with different `~/share` folders would give random 404s. |
| Remotely managed tunnel | The route lives in Cloudflare, so a machine needs only the tunnel's run token to serve. |
| Quick mode reuses the same caddy and index | TryCloudflare cannot route hostnames, so quick links keep the `/<id>/` path shape and every command works unchanged. The price is a new random hostname per start; stable names stay behind `share setup <hostname>`. |
| Browser login by default | Nobody has to create an API token by hand. The login certificate's token may manage tunnels (tested: create, configure, read the token, delete) but gets an authorization error on DNS records, so DNS goes through `cloudflared tunnel route dns` and the hostname check goes through public DNS. The trade-off: teardown cannot delete the DNS record on this path. |
| Login service | Links should be live whenever the machine is awake, with no command to remember after a restart. |
| `start` waits for a public fetch | cloudflared reports ready before caddy may listen, and the Cloudflare edge keeps routing to the old connection for a few seconds after a restart. Measured: links answered 502 right after `start` returned on cloudflared's readiness alone. `start` now places a probe file and returns once it answers 200 through the public hostname (2 to 3 seconds). |
| Wait for launchd to unload | `launchctl bootout` returns before the job has stopped, so an immediate `bootstrap` fails with "Bootstrap failed: 5". Reproduced with a dummy agent that takes 2 seconds to exit. |
| DNS check before creating the tunnel | A taken hostname stops setup with nothing created, so a failed run leaves no orphan tunnel. |
| API token through `-H @file`; run token stored through stdin and passed as `TUNNEL_TOKEN` | Neither token appears in a process's arguments, so `ps` output never shows one. |
| caddy, not `python -m http.server` | caddy sets headers, disables listings, writes a JSON access log, and ships as one static binary for CI. |
| r2: one record per share, naming its upload prefix | R2 has no rename, so a staged upload cannot move into place. The record is the only path from a link to bytes, so one conditional `PUT m/<id>` publishes, one conditional swap refreshes, and every add and rm writes its own key instead of contending on a shared index. |
| r2: the S3 API through `curl --aws-sigv4` | Measured: a bucket-scoped token gets 403 on every REST object call, and the REST PUT ignores `If-None-Match` and `If-Match`. S3 honors both and stays outside the account API rate limit. curl's built-in flag adds no dependency. |
| r2: expiry checked by the Worker per request | A link dies at its second. A cleanup cron in the Worker would need an Access token there; publishers' `ls` and `prune` delete the bytes instead. |
| r2: Worker source embedded in `bin/share` | `install.sh` ships one file, and the formula stays unchanged. `WORKER_VERSION` and `WORKER_SHA` make every deploy comparable, and a deploy refuses to downgrade a newer Worker without `--force`. |
| Bash | The tool is glue around caddy, cloudflared, and the Cloudflare API. A single binary in Go becomes the better choice if share needs Windows or a distribution without a git checkout. |

## Testing

| Layer | How | Where |
|---|---|---|
| Lint | `shellcheck` | CI and local |
| Behavior | `tests/share.sh` runs a local server (`SHARE_TUNNEL=0`, port 18787) and covers add, auto-start, headers, dotfile and symlink exclusion, markdown, a deleted source, refresh, hits, expiry, rm, stop, live shares (a second caddy as the origin), the generated folder index, `--host` under `SHARE_HOST_DRY=1`, which records the Cloudflare calls instead of making them, profiles (two quick profiles serving at once under a private `HOME`, with stubbed `security`, `launchctl`, and `systemctl`), and the Access gate under `SHARE_ACCESS_DRY=1` (every Cloudflare call answered from fixtures and logged: the three rule forms, refusals, the group lookup over pages, gate-before-publish order with a watcher on `pub/`, timeout, `rm`, expiry without a token, the sweep with a lost POST or DELETE, a live owner, pid reuse, teardown, `api-token` with a stubbed Keychain and a pseudo-TTY, the preflight per scope, the encoded-path 400s, and a `curl` shim proving the token never reaches argv). It ends with a negative control: a host outside `hosts` must not serve. | CI (Ubuntu and macOS, with pandoc) and local |
| Cloudflare and service | `tests/e2e.sh` against a throwaway hostname (API-token or `--login` setup): setup must pass its live check; a rerun must reuse the tunnel; a published folder must answer, show the snapshot, hide `.env`, and send `no-store`; links must answer right after `start` and after a service reinstall; `rm` must return 404; teardown must leave no DNS record, a deleted tunnel, and no service. Found and fixed with it: a 530 right after a service reinstall, because one 200 does not mean the edge has dropped the old connection. | Local, with a real zone and token; run before a release that touches setup or serving |

## Releasing

`bin/release` on a clean, synced `main` cuts a release in one step: it computes the next semver from the conventional-commit subjects since the last tag (`feat` -> minor, everything else -> patch, `!`/`BREAKING` -> major), regenerates `CHANGELOG.md` via `bin/changelog` and lands it on `main` before tagging, pushes the tag, and bumps the tap formula (`Formula/share.rb` url + sha256) through a merged PR in `dwarvesf/homebrew-tools`. The tag push runs `release.yml`, which publishes the GitHub release with generated notes. Releases are cut when a feature lands, not per commit. `bin/changelog` is idempotent: run it any time to rebuild `CHANGELOG.md` from tag history.
