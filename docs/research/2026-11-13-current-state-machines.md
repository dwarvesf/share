# share: current-state machine map (read-only research)

Source: `/Users/tieubao/workspace/dwarvesf/share/bin/share` (4,833 lines; HEAD 4564c5c, CLI v0.9.0 line). Docs read: README, docs/how-it-works.md, ADR-0005..0008, SPEC-004/005/007/008.
Cite form: `L123` = bin/share line 123. `S8:` = docs/specs/SPEC-008-one-host-per-tenant.md, `S7:` = SPEC-007, `A8:` = ADR-0008. Where code and docs disagree, code wins (noted).
Worker JS is embedded in bin/share at L2566-2783 (heredoc); `export default` at L2765.

---------------------------------------------------------------------------------------------------

## 0. Derived flags and the persisted-artifact inventory

### 0.1 Flags every command computes at load (these ARE the role detectors)

| flag | derivation | cite |
|---|---|---|
| `profile` | `--profile <n>` before verb, or `SHARE_PROFILE`; `default`/empty = unnamed | L42-48 |
| `config_dir` | `~/.config/share[/profiles/<p>]` (or `SHARE_CONFIG_DIR`) | L56 |
| `root` | `~/share[/profiles/<p>]` (or `SHARE_ROOT`); `pub=$root/pub`, `index=$root/index.tsv`, `r2own=$root/r2-own`, `pending=$root/access-pending` | L60-65 |
| `host_name` | `SHARE_HOSTNAME` or config `hostname=` | L66 |
| `backend` | `SHARE_BACKEND` or config `backend=`; `r2` = serves from Cloudflare | L67 |
| `port` | config `port=`, default 8787; for `backend=r2` the sentinel `r2` makes an older share die at load; `metrics_port=0` | L68-74 |
| `hosts` | config `hosts=` (space list of machine short names allowed to serve); `host_ok` = this machine's `uname -n` short name is in it | L75, L82-83 |
| `mode` | config `mode=`; `quick` = trycloudflare, else named tunnel | L77 |
| `r2on` | `backend != r2` AND config `bucket=` non-empty (tenant origin with R2 on) | L78-79 |
| `running` | `serve.pid` exists AND pid alive AND `ps` command matches `*share*serve*` | L84-88 |
| `svc_installed` | `~/Library/LaunchAgents/foundation.d.share[.p].plist` or systemd user unit exists | L1248-1251 |
| `tunnel` | `SHARE_TUNNEL` (0 = local-only test seam) | L76 |

### 0.2 Config keys (`$config_dir/config`, line `key=value`, rewritten via tmp+mv)

| key | written by | meaning | cite |
|---|---|---|---|
| `hostname` | setup (tunnel), setup --backend r2 | tenant/main FQDN | L1682, L3822 |
| `tunnel_id`, `tunnel_name`, `auth` (`api`/`login`) | setup (tunnel) | Cloudflare named tunnel; NOT written in r2 or quick | L1683-1685 |
| `hosts` | setup, quick | machines allowed to serve | L1686, L1650 |
| `port` | setup; named profile picks free odd pair from 8789 | local Caddy port (metrics = port+1); `r2` for r2 backend | L1687, L1590-1594, L3825 |
| `zone` | setup; also lazily appended by `host_zone` | DNS zone of hostname | L1688, L1709 |
| `mode=quick` | setup --quick | quick-tunnel flag | L1649 |
| `backend=r2`, `bucket`, `r2_endpoint` | setup --backend r2 | r2 profile (admin or member, identical file) | L3821-3826 |
| `bucket`, `r2_endpoint`, `storage_default` (`local`/`cloud`), `aliases` | setup --r2 (`tenant_config`) | the "R2 on" marker on a tunnel origin; `aliases=` may be empty; dropped as a group by `--no-r2` | L3870, L3867-3873 |
| `aliases` (on r2 member) | join in setup --backend r2 | only aliases whose 301 was observed; makes member rm/expiry of folded shares delete the right app | L3827, L4317-4321 |
| `token_cmd` | hand-edited | command printing tunnel token (replaces Keychain) | L294, L1689 |
| `api_token_cmd` | `api-token --cmd` | command printing the Access/publisher token | L2454, L1912 |
| `r2_token_cmd`, `r2_key_id`, `ttl` | hand-edited (never written by CLI except preserved) | publisher-token cmd, fixed S3 key id, default ttl | L3504, L3502, L466 |

Preserved on rewrite: tunnel `write_config` keeps `token_cmd`, `api_token_cmd`, and the four tenant keys (L1677-1693); `write_config_r2` keeps `api_token_cmd`, `r2_token_cmd` (L3817-3832). Admin vs member is NOT recorded anywhere in config.

### 0.3 Local files under `$root` (per profile, per machine)

| path | role | cite |
|---|---|---|
| `pub/<id>/...` | served tree (tunnel profiles only; nothing else reachable from the tunnel) | L61, L1127-1132 |
| `index.tsv` | 6 tab cols: id, name, src, added(YYYY-MM-DD), exp(epoch, 0=never), opts | L62, L568 |
| `r2-own` | `<id>\t<prefix>\t<src>` for cloud shares THIS install added; refresh trusts only this | L63, L3480-3498 |
| `access-pending` | `<id>\t<app-uuid or -:<nonce>>\t<owner pid>\t<owner start>\t<created>`; every Access app not backed by a finished row | L65, L2177-2216 |
| `Caddyfile`, `admin.sock`, `access.log`, `caddy.log`, `cloudflared.log`, `serve.log`, `serve.pid`, `quick.url` | server runtime | L1087-1165, L1201-1231 |
| `.lock-index`, `.lock-host`, `.lock-add-<id>` | symlink locks naming a pid | L207-230 |
| `.stage.XXXXXX`, `.index.*`, `.pending.*`, `.r2rec.*`, `.r2-index.*`, `.marker.*`, `.import*`, `.migrate-tar.*` | transient | various |
| `index.migrated`, `migrated/<id>/` | rows and trees moved aside by migrate (nothing deleted) | L906-907 |
| `trash/` | fallback when no `trash` command | L194-198 |
| `r2-calls.log`, `access-calls.log`, `host-calls.log`, `r2-dry/` | test seams only | L1859-1862 |

Config dir also holds: `tunnel-token` (0600 fallback), `api-token` (0600 fallback), `cert.pem` + `cert.zone` (browser login auth) (L289, L1857, L1517, L1527-1535).

### 0.4 Keychain items (macOS; account `share`)

| service | holds | written / removed | cite |
|---|---|---|---|
| `share-tunnel[.<profile>]:<host>` | named-tunnel run token | `token_store` at setup; `token_forget` at teardown/migrate_retire | L292, L301-316 |
| `share-api[.<profile>]:<host>` | Access token (tunnel profile) or publisher token (r2 profile / R2-on origin) | `api_token_store` via `api-token`; `api_token_forget` at teardown | L1858, L1935-1949 |
| `share-migrate-check.<pid>` | throwaway probe | create+delete in same call | L864-871 |

### 0.5 Cloudflare objects and who creates them

| object | name | created by | removed by | cite |
|---|---|---|---|---|
| Tunnel (remote-managed config) | `share-<host-dashes>` (migrate target: `<old>-m`) | setup (tunnel) | teardown, migrate_retire | L4457, L4503, L1046, L4631 |
| Tunnel ingress | rule 0 = main host -> `http://127.0.0.1:<port>`; `--host` rules inserted before final `http_status:404` | setup PUT (OVERWRITES list); `host_add` | `host_rm` | L4507, L1790, L1839 |
| DNS CNAME | `<host>` and each `--host` fqdn -> `<tunnel_id>.cfargotunnel.com` proxied | setup / `host_add` | teardown / `host_rm` (only if it points at this tunnel) | L4513, L1798, L1824 |
| R2 bucket (private) | `--bucket` | `setup --r2` or `--backend r2` admin | `teardown --purge` only if empty after delete | L4091, L4362, L4719 |
| Marker `share.json` | `{"v":1,"host":H[,"aliases":[A]]}` | setup (If-None-Match), alias step (If-Match) | purge | L4094-4107, L4156-4164, L4706 |
| Worker script | `share-<host-dashes>`, dataset `share_<host_underscored>` | admin setup | purge | L3978, L3770 |
| Worker bindings | BUCKET(r2), HITS(analytics), HOST, TEAM, VERSION, SHA, [PASS="1", ALIASES=csv], SALT(secret, first deploy only, kept) | `r2_deploy_meta` | script delete | L3766-3767, L3772 |
| Worker route (tenant) | `<host>/*` -> Worker, `request_limit_fail_open:true` | `setup --r2` step 13 | `--no-r2` | L4167-4178, L4218 |
| Worker custom domain (r2-only profile) | `<host>` -> Worker (Cloudflare creates DNS) | admin `--backend r2` | purge | L4389, L4710 |
| Alias custom domain | `<alias>` -> tenant Worker (override) | `--alias` step 14 | alias rollback list (manual) | L4182, L3940-3955 |
| Access app (per gated share) | `share <id> <host> <nonce8>`; destinations `<host>/<id>` + `<host>/<id>/*` (+ `--host` fqdn); policy allow, session 24h | `access_create` | `access_delete` (name-checked) | L2221-2227, L2255 |
| Bucket `m/<id>` | cloud record v:1 or pointer v:2 | add / origin | rm / reconcile / prune | sections 2.5, 2.6 |
| Bucket `o/<id>.<nonce8>/<path>` | one upload's bytes | add / refresh | rm, trap, orphan sweep | L3030, L3403 |

---------------------------------------------------------------------------------------------------

## 1. Profile / install role state machine

### 1.1 Roles (as derived from 0.1; a profile is exactly one)

| role | detector | config shape | machine-local state | cloud state |
|---|---|---|---|---|
| R0 none | no `hostname=` and `mode != quick` (`state` -> `not_setup`) | absent or without hostname | maybe stray `pub/`, `index.tsv` (an import target) | none |
| R1 quick | `mode=quick` | `mode,hosts,port` | service, `quick.url` (new each start) | none (trycloudflare, no account) |
| R2 tunnel origin, R2 off | `hostname`+`tunnel_id`, no `bucket` | tunnel keys | pub, index, Caddy, cloudflared, service, Keychain tunnel token | tunnel, ingress, CNAME |
| R3 tunnel origin, R2 on | R2 + `bucket=`, `r2_endpoint=`, `storage_default=`, `aliases=` | + 4 tenant keys | as R2 + pointers rows | + bucket, marker, Worker(PASS), route, [alias domain], pointers `m/<id>` v:2, cloud records |
| R4 r2 admin (transient role of the setup run) | worker settings GET 200/404 with admin token | `backend=r2,...` | none | bucket, marker, Worker, custom domain |
| R5 r2 member/publisher | worker settings GET 401/403 ("join"); persisted shape == R4 | `backend=r2,...` | `r2-own`, `access-pending` | none (join writes nothing on Cloudflare) |
| R6 migrated-away origin | NOT a distinct flag: R2-shaped config + empty index + `index.migrated` + no tunnel token | config left in place (hostname, tunnel_id of a now-deleted tunnel) | `migrated/`, `index.migrated`; service gone; Keychain tokens forgotten; cert trashed | tunnel+CNAME deleted (unless same tunnel id as target) |

Note: member-of-a-tenant = an R5 profile whose `hostname` equals the tenant host; the tenant Worker is the R3 origin's Worker (PASS bound). R5 against a non-tenant host is the older "f.d.foundation" shape (SPEC-007). Code does not distinguish them in config; `r2_healthz` header `X-Share-Tunnel` present = tenant (L3706, L4322).

### 1.2 Diagram

```
                    setup --quick
        +-------------------------------> [R1 quick] --teardown--> [R0]
        |                                   |  setup <host>: DIE "already quick"  (L4446)
        |                                   |  setup --quick again: converges      (L1656)
 [R0 none] --setup <host>----------------> [R2 origin, R2 off] --teardown--> [R0]
   |  |            (tunnel+DNS+svc)           |   ^   |  setup <h> --r2 --bucket B      ^
   |  |                                       |   |   |  [--storage-default] [--alias A]|
   |  |                              migrate  |   |   v                                 |
   |  |                    --to T (R2 off     |   +-- [R3 origin, R2 on] --setup <h> --no-r2
   |  |                     only, no --host)  |        (alias set: REFUSED, prints         (route deleted,
   |  |                                       v         rollback list)                      4 keys dropped)
   |  |                                  [R6 migrated-away]   R3 --teardown--> [R0] (tenant objects NOT cleaned, L4557)
   |  |
   |  +--setup <h> --backend r2 --bucket B (token env CLOUDFLARE_API_TOKEN)
   |        worker settings 404/200 -> admin: creates bucket+marker+Worker+custom domain -> [R4->R5-shaped config]
   |        worker settings 401/403 -> join: writes only local config               -> [R5 member]
   |        host already a tenant (PASS / marker aliases / route) -> admin REFUSED even with --force
   +--import (target side of migrate, R0 or R2 only; R3/R5 refused)  (L783)
 [R5/R4] --teardown [--yes]--> [R0]  (bucket, Worker, shares stay)
 [R4]    --teardown --yes --purge (admin env token)--> [R0] + everything on Cloudflare deleted
```

### 1.3 Transition table

| from | event | guard (refusals, in order) | to | artifacts written | cite |
|---|---|---|---|---|---|
| R0 | `setup <host>` w/ `CLOUDFLARE_API_TOKEN` | host regex; not quick; not backend r2; no other profile owns host or tunnel name; caddy cloudflared jq curl present; zone found; DNS free (or `--force`) | R2 | tunnel created or reused by name; ingress PUT (OVERWRITES); CNAME; Keychain `share-tunnel:<host>`; config; launchd plist; Caddy+cloudflared started; `live_check` 3x200 | L4400-4554 |
| R0 | `setup <host>` no token (login) | as above; browser login | R2 | + `cert.pem`, `cert.zone`; DNS via `cloudflared tunnel route dns`; a failed DNS route deletes the tunnel it just created | L4472-4479, L4521-4532 |
| R0 | `setup --quick` | tools present; no `tunnel_id`; no host arg/force/login | R1 | config `mode,hosts,port`; plist; serve; `quick.url` from cloudflared log | L1656-1675, L4442-4445 |
| R1 | `setup --quick` again | none | R1 | config rewritten; converges | L1662 |
| R1 | `setup <host>` | die "already set up with a quick tunnel" | R1 | none | L4446 |
| R1 | `teardown [--yes]` | TTY confirm or `--yes` | R0 | plist removed, server stopped, `quick.url` removed, config trashed; `pub/`+index stay | L4559-4571 |
| R2 | `setup <host>` same host | host regex; other-profile dup checks | R2 | reuses tunnel by name; ingress PUT REPLACES whole list (drops every `--host` rule; CNAMEs and rows remain); CNAME ok; token re-stored; config rewritten (tenant keys kept); service reinstalled | L4457-4553, L4507, L1691 |
| R2 | `setup <other-host>` | refuses if old host has gated rows or pending apps | R2 | as above (new tunnel name) | L4449-4456 |
| R2/R3 | `setup --quick` | `tunnel_id` set -> die | same | none | L1657 |
| R2 | `setup <h> --r2 --bucket B ...` | see 1.4 | R3 | see 1.4 | L3977-4199 |
| R3 | `setup <h> --r2 --bucket B` same bucket | converges | R3 | only missing pointers / route / deploy | L3986-3987, L4126, L4110 |
| R3 | `setup <h> --r2 --bucket B2` | die "R2 is on with bucket X; --no-r2 first" | R3 | none | L3987 |
| R3 | `setup <h> --no-r2` | admin token env; alias set in config OR marker -> REFUSED with rollback list | R2 | route DELETE; 4 config keys dropped (`tenant_config` with no args). Bucket, records, pointers, Worker, marker stay (cloud links 404 afterward; stale pointers pass to Caddy -> 404) | L4201-4224 |
| R2 | `setup <h> --no-r2` | admin env token, `tenant_admin` | R2 | no-op (no route, no keys) | L4205, L4216-4223 |
| R3 | `setup <h>` (tunnel rerun) | as R2 row | R3 | `write_config` greps the 4 tenant keys back in | L1691 |
| R0 | `setup <h> --backend r2 --bucket B` | not quick, no `--tunnel-name/--login`, bucket regex, host regex, no tunnel_id/quick in this profile, no other profile owns host, admin env token verifies, zone found | R4 or R5 | role split below | L4226-4396 |
| R0 | ... role = join (settings 401/403) | bucket exists (404 -> die); marker names this host; if bucket-scoped token, public-route checks skipped; `r2_wait_healthz join` 3x200 (accepts a 503 with valid pair + `X-Share-Tunnel: 0`); aliases kept only if 301 observed | R5 | local config only (`write_config_r2`); version-mismatch hint printed, not fatal | L4314-4330, L3736 |
| R0 | ... role = admin | worker (if exists) is share's for this host+bucket, version <= CLI (or `--force`), NOT PASS; marker names host and NO aliases; no route on `<host>/*`; no foreign custom domain; DNS clear or `--force` | R4->R5-shaped | bucket (if new), `share.json` If-None-Match, Worker deploy, workers.dev off+verified, custom domain, `r2_wait_healthz admin`, config | L4263-4276, L4305-4306, L4332-4396 |
| R4/R5 | `setup <h> --backend r2 ...` again | same checks | same | converges | L4226+ |
| R4/R5 | `setup <h>` (tunnel) | die "set up with the r2 backend; teardown first" | same | none | L4441 |
| R4/R5 | `teardown [--yes]` | confirm | R0 | token forgotten (Keychain+file), `r2-own` trashed, config trashed; pending Access lines stay in `access-pending` (file stays in `$root`); bucket/Worker/shares stay | L4641-4662 |
| R4 | `teardown --yes --purge` | admin env token; Worker is share's for this host+bucket and NOT PASS; marker names host; domain not another Worker's; Access Apps Edit proven if any gated/pending | R0 | rm every record (gated first), Access sweep + by-name pass, delete all `m/`,`o/`, marker, custom domain, Worker, bucket if empty; dataset stays | L4664-4725 |
| R2/R3 | `teardown [--yes]` | confirm; gated shares need api token (rm'd first); pending apps swept | R0 | gated rows rm'd, plist, stop, DNS CNAME(s) deleted (if env token), `--host` DNS+ingress removed, tunnel connections+tunnel deleted, both tokens forgotten, cert trashed, config trashed. On R3 NOTHING tenant-side is touched (route, Worker, pointers, bucket remain) | L4557-4639 |
| R2 | `migrate --to T [--yes]` | see 1.5 | R6 (sender), R2 (target) | see 1.5 | L938-1083 |
| R0 / R2 | `import ...` (target) | refused if `backend=r2` or `r2on`; id/exp/by/added regex; opts only `noindex access= access_rule=`; id not in index, `pub/`, or pending | same | `pub/<id>`, row `... by=<by>` with src `<by>:<src>`; Caddy reload if running | L779-828 |
| R1/R2/R3 | `service install` | `host_ok` | same | plist/unit written, loaded; `wait_running 10`; `warn_not_live` | L1363-1368, L1279-1332 |
| R1/R2/R3 | `service uninstall` | none | same | plist booted out and trashed (this stops the job); links down until `start` | L1369-1370, L1334-1345 |
| R4/R5 | `service`, `start`, `stop`, `serve` | die "an r2 profile serves from Cloudflare" | same | none | L2787-2789 |
| R1/R2/R3 | `start` | `host_ok`; not already `running` | same | service: `launchctl bootstrap` (kickstart fallback); else `nohup bash share serve`; `wait_running 10` (R2/R3: `/ready` on metrics port); `warn_not_live` | L1377-1394 |
| R1/R2/R3 | `stop` | running | same | service: bootout; else `kill`; `quick.url` removed. Service stays installed (restarts at next login) | L1422-1433 |
| R1/R2/R3 | `serve` | `host_ok`; not running; ports 8787/metrics free; named mode needs tunnel token from `token_cmd`/Keychain/file | same | pidfile, Caddyfile, caddy + hourly `prune` loop + cloudflared; `SHARE_API_TOKEN_OFF=1` exported | L1177-1243 |

### 1.4 `setup <h> --r2` on the origin: 16 steps and what a die leaves (R2 -> R3)

All refusals happen before the first write (L3977-4071). The index lock is held from L4075 through L4153 so concurrent local adds wait.

| step | action | artifact | die leaves | cite |
|---|---|---|---|---|
| 0 | refusals: alias != host, in zone, one alias; bucket regex; same bucket; host serving here (`running`); not quick; tunnel profile for this host; `CLOUDFLARE_API_TOKEN` admin; zone; own S3 pair from `/user/tokens/verify`; Worker settings readable (admin) and share's for host+bucket+not newer than CLI; bucket private (no r2.dev, no custom domain); marker names host or alias; alias domain belongs to a share Worker on this bucket; no foreign route on host | none | nothing | L3980-4071 |
| 1 | clash check (bucket exists): every local id vs bucket keys; clash unless the key is already a v:2 pointer | none | nothing | L4076-4085 |
| 2 | `alias_scan strict` (alias only): every gated cloud record's Access app must be named `share <id> <alias> ...`; Apps Edit probe | none | nothing | L4087, L3875-3893 |
| 3 | create bucket if new | bucket | empty bucket, no marker | L4090-4093 |
| 4 | `PUT share.json` If-None-Match `*` (412 -> must name this host) | marker | bucket + marker; config still R2-off | L4094-4107 |
| 5 | Worker deploy (skipped when VERSION, SHA, TEAM, PASS=1, ALIASES all equal) | Worker with PASS, ALIASES | Worker with no route: unreachable | L4109-4115 |
| 6 | workers.dev off and read back | | Worker, workers.dev state unverified | L4116-4120 |
| 7 | pointer `m/<id>` for every local row without one (412 -> die) | pointers | some pointers; no route; config R2-off | L4123-4137 |
| 8 | alias: each folded Access app gains `<host>/<id>` destinations, `access_gate` 3 rounds; failure undoes the adds | app destinations | undone on failure | L4139-4149 |
| 9 | `tenant_config`: the four keys written; lock released | config says R3 | from here a die leaves R3 config without route; message names rollback | L4151-4153, L3957-3960 |
| 10 | alias: marker rewritten with `aliases` under If-Match | marker | `tenant_die` (rollback list) | L4155-4164 |
| 11 | route `<host>/*` POST, or PUT to fail-open | route | `tenant_die`; "links still serve from the tunnel" | L4166-4178 |
| 12 | alias: custom domain PUT with `override_existing_origin` (3 tries on 5xx) | alias domain | `tenant_die` | L4180-4185 |
| 13 | `r2_wait_healthz tenant`: 3 consecutive 200 with this CLI's `VERSION SHA` and `X-Share-Tunnel: 1` within `SHARE_R2_WAIT` (300 s); then `live_check 60`; alias: 3x301 | | `tenant_die` | L4187-4191, L3741-3759 |
| 14 | alias: folded apps drop `<alias>/<id>` destinations; `alias_own_handoff` copies the alias profile's `r2-own` lines | | "rerun the same setup" | L4193-4197 |

Rerun converges: deploy skipped when equal (L4110), pointers skipped when present (L4126), route "already attached" (L4176), alias domain skipped when already this Worker (L4181).

### 1.5 `migrate --to T` (R2 -> R6 + target R2), sender side

| phase | action | guard | cite |
|---|---|---|---|
| refusals | named only; not R2-on/r2; `host_ok`; no `--host` rows; `CLOUDFLARE_API_TOKEN` env; per-share size <= `--max-bytes` (2 GiB) | each die before any write | L958-979 |
| preflight | remote `import --probe` == `share-import 1`; `migrate-probe` (state not_setup/stopped/serving, host, pub empty, port free, Keychain round trip, launchctl); not_setup with foreign shares refused; stopped/serving must be same host | | L981-1000 |
| confirm | TTY or `--yes` | | L1002-1006 |
| copy | per snapshot row (skip if `id name added` already on target): tar of `pub/<id>` over ssh stdin + digest `<n files>:<sha256>` ; `by`/`src` rewritten to `<by>:<src>` for rows already imported | | L1009-1032 |
| switch | remote `setup <host> --tunnel-name <old>-m --force --token-stdin` (new tunnel; DNS CNAME re-pointed) | die prints rollback `setup --tunnel-name <old> --force` | L1040-1052 |
| verify | probe file 3x200 via public host; gated links must 302 with the app's aud | die: "nothing moved aside" | L1054-1079 |
| retire | `migrate_retire`: rows -> `index.migrated`, trees -> `migrated/`, index rewritten, Caddy reload, service uninstalled, server stopped; delete old tunnel+CNAME only if target tunnel id differs; tokens forgotten; cert trashed; config LEFT IN PLACE | | L897-936 |

Live rows are reported, never moved (L1033-1038). A rerun after a mid-copy die resumes (already-present ids skipped, L1011).

---------------------------------------------------------------------------------------------------

## 2. Share link lifecycle

### 2.0 Row/record formats (the persisted encoding of link state)

| kind | where | shape | cite |
|---|---|---|---|
| local row | `index.tsv` | `id\tname\tsrc\tadded\texp\topts`; opts tokens: `live`, `noindex`, `host=<fqdn>`, `access=<uuid>`, `access_rule=<rule>`, `by=<machine>` (imported). Validated by `rows_in`: 6-hex id, host != main and hostname-shaped, `access` and `access_rule` both or neither, uuid shape | L90-135 |
| cloud record v:1 | `m/<id>` | `{v:1,id,name,src,added,expires,opts,prefix:"o/<id>.<nonce8>/",by,type[,aud]}`; no `storage` key | L3048-3051 |
| machine pointer v:2 | `m/<id>` | `{v:2,id,storage:"machine",name,by,added,expires,opts,type[,own_host]}`; opts only `noindex live gated`; never the rule | L2938-2943 |
| display row | in-memory | cloud rows get `prefix= by= type=` appended by `r2_record_row`; pointer rows by `r2_take`; never enter `rows()` for an origin | L3177-3194, L3268-3276 |

`id` = 6 lowercase hex (3 random bytes, `/dev/urandom`) (L152). `type` in {pdf,image,video,audio,folder,site,markdown,archive,text,other} (L2844-2864).

### 2.1 Machine snapshot (tunnel profile; R2 off or `--local`/default storage on R3)

```
 (none) --add--> STAGED(.stage.X) --stage_publish--> BYTES(pub/<id>, reachable, no row)
                                                   --append row (index lock)--> LISTED
 LISTED --refresh--> LISTED (swap)   LISTED --rm / expiry-prune--> ROWLESS-trashed --> (none)
 LISTED --migrate--> moved aside (index.migrated + migrated/)
```
Reachability: the main Caddy site serves the whole `pub/` tree by file_server (L1127-1132), so `pub/<id>` is live as soon as `stage_publish` runs, whether or not a row exists.

`cmd_add` ordered steps (snapshot, non-gated, R2 off), with the artifact written and the die point:

| # | step | artifact written | if it dies here | cite |
|---|---|---|---|---|
| 1 | parse; storage choice; `--host`/`--access` guards | none | nothing | L466-505 |
| 2 | target class (snapshot/live), port guards | none | nothing | L498-515 |
| 3 | `need_host`; ttl -> secs; realpath, tab/newline/`{}"\` name refusals | none | nothing | L516-524 |
| 4 | (R3 only) `r2_token_check` | none | nothing | L534 |
| 5 | `rand_id` (row, `pub/<id>`, pending line, and on R3 `m/<id>` + `o/<id>.` all absent) | none | nothing | L153-186 |
| 6 | `mk_root`; `stage_copy` -> `.stage.X` (regular files only; no dotfiles/symlinks; md rendered; index generated unless `--no-index`) | stage dir | trap deletes stage | L413-431, L233-236 |
| 7 | (R3) `r2_pointer_put`: lock `add-<id>`, `PUT m/<id>` If-None-Match; 412 -> new id (max 5) | pointer v:2 | pointer with no row: reconciled away after 10 min | L547, L2948-2963 |
| 8 | non-gated: `stage_publish` (mv old aside, mv stage -> `pub/<id>`) ; `warn_private` | `pub/<id>` | bytes live but unlisted; never pruned (no row) | L549, L432-438 |
| 9 | (`--host`) `host_add`: ingress PUT then CNAME POST; failure reverts ingress and dies; success sets `held_fqdn` | ingress rule, CNAME | die before `held_fqdn`: unlisted `pub/<id>` only; after: trap runs `host_rm` | L554, L1775-1807, L237 |
| 10 | `lock_take index`; append row; `write_caddyfile`; `caddy_reload` (failure only warns) | row, Caddyfile | `lock_take` timeout (60 s) dies: unlisted bytes | L562-570 |
| 11 | release locks, print URL, clipboard, auto `cmd_start` if not running and `host_ok` | | | L573-584 |

| from | event | guard | to | artifacts | cite |
|---|---|---|---|---|---|
| LISTED | `refresh <id>` | R3 + no local row -> cloud path; live row -> no-op; imported row with foreign `by` and `by:` src prefix refused; source must exist | LISTED | new stage, then under index lock: row still exists, swap into `pub/<id>`, Caddyfile re-render | L636-656 |
| LISTED | `rm <id>` | host fqdn needs a CF credential unless prune; gated needs api token (not prune) | (none) | order: (gated) pending line -> `host_rm` -> index lock: trash `pub/<id>`, row removed, Caddy reload -> (R3) pointer delete -> (gated) `access_delete` | L658-699 |
| LISTED | expiry | `exp>0 && exp<now` found by `prune` (serve start via `prune quiet`; hourly loop; `status`; `ls`; verb) | (none) | `cmd_rm <id> prune` per row | L701-728, L1183, L1206 |
| rm partial | killed after trash, before row removal | | row with no bytes | "never content with no row" | L680-683 |

### 2.2 Live port share

Row opts `live`, `src=http://127.0.0.1:<port>`, `name=localhost:<port>`. No bytes. Caddy gets `handle_path /<id>/* { reverse_proxy 127.0.0.1:<port> }` in the main site (L1118-1120). Guards: port >= 1024, <= 65535, not this profile's port or metrics port, not another profile's (L509-514). `refresh` no-op (L642). Dead dev server -> Caddy 502 (Worker passes 502 unchanged, section 3.3). `--cloud` refused for live (L483).

### 2.3 `--host` share (snapshot or live)

Adds own FQDN (one label under the zone; not main host): `host=<fqdn>` in opts; ingress rule + proxied CNAME to the single tunnel; own Caddy site block `http://<fqdn>:<port>` (L1138-1160). Create order ingress, DNS, row; delete order DNS, ingress, row (L1696-1698). Needs `CLOUDFLARE_API_TOKEN` or `cert.pem` (L1713-1716). `--host` fqdns are NOT under the Worker route (route pattern is `<host>/*`), so they never go through the Worker (L4167). Refused: quick mode (L492), `--cloud` (L483), migrate (L963), members (L501).

### 2.4 Imported snapshot (migrate target)

Row appended by `cmd_import` with `opts + " by=<by>"`, `src="<by>:<original src>"`, original added/exp (L797-824). `refresh` refuses it unless `by` equals this machine's `r2_by` or src lacks the `<by>:` prefix (L644-645). Gated rows keep their `access=<uuid>`; no app created (L779).

### 2.5 Cloud record v:1 (r2 profile add; or `--cloud` on R3)

```
 (none) --add--> STAGED --PUT o/<id>.<nonce>/*--> UPLOADED(unreferenced; trap-owned)
   ungated: --PUT m/<id> If-None-Match:* (200)--> PUBLISHED + r2-own line
   gated:   UPLOADED --access_create--> APP_PENDING(-:nonce) -> APP_BOUND(uuid) --gate 3 rounds--> ENFORCED
            --lock index; PUT m/<id> (aud, access=, access_rule=)--> PUBLISHED --link check 302/403
 PUBLISHED --refresh (own install, If-Match)--> PUBLISHED(new prefix) + old prefix deleted
 PUBLISHED --expires passes--> WORKER-404 (bytes remain) --any publisher ls/prune--> rm
 PUBLISHED --rm (any publisher)--> DELETE m/<id>, GET proves 404, row dropped, r2-own dropped, delete o/<id>.*, delete app
```

`cmd_add_r2` steps (L3011-3079) and die leftovers:

| # | step | artifact | die leaves | cite |
|---|---|---|---|---|
| 1 | name refusals; `r2_token_check` (stored token resolves) | none | nothing | L3014-3018 |
| 2 | gated only: `/healthz` must be 200 AND `X-Share-Gate: 1` (Worker has Access TEAM) else die; `access_prepare` (preflight scopes, sweep, group lookup) | none | nothing | L3020-3025 |
| 3 | `rand_id` (live `GET m/<id>` + `LIST o/<id>.` both empty; pending line absent; fails closed on any non-200/404) | none | nothing | L3026, L153-186 |
| 4 | `stage_copy`; `r2_stage_check` (<= 500 files, <= 300 MiB per file, no control char / `\` / `"` in names) | stage | trap deletes | L3028-3029, L2807-2818 |
| 5 | `nonce=r2_nonce`; `r2_held_prefix` armed; `r2_put_tree` (8 parallel, failed ones retried alone); `r2_prefix_matches` | `o/<id>.<nonce>/...` | `r2_release_prefix` trap: GET `m/<id>`; 404 or record not naming this prefix -> delete prefix; record names it -> keep; other HTTP -> prefix stays until the 24 h orphan sweep | L3030-3033, L2832-2841 |
| 6 | gated: `access_create` (pending `-:nonce` -> uuid), `access_gate` (3 rounds in a row, <= `SHARE_ACCESS_WAIT` 900 s), aud must be 64 hex | Access app | gate fail: `access_delete` else pending line stays; prefix trap-deleted | L3034-3046 |
| 7 | `PUT m/<id>` v:1 If-None-Match `*` | **the publish** | 412: trap deletes our prefix, gated app deleted, "another publisher took id"; other code: prefix KEPT (PUT may have committed), gated pending line stays for next sweep | L3047-3066 |
| 8 | `r2_own_put id prefix src`; URL; gated link check | `r2-own` line | die between 7 and 8: published but this install cannot refresh ("added from another install") | L3069-3073 |

`refresh` (cloud, own install only): GET `m/<id>` + ETag, record must be sound v:1, `r2-own` line must have the same prefix, source must exist; upload to NEW prefix; `PUT m/<id>` with `If-Match: "<etag>"` (412/404 -> "changed during refresh", trap deletes new prefix); then delete old prefix; record `src` is overwritten with this install's path (L3380-3421).

`rm` (cloud, any publisher): gated needs an api token passing the Apps Edit probe BEFORE any change; `DELETE m/<id>` then a fresh `GET` must be 404 (else die, bytes and app kept); then `r2_delete_prefix "o/<id>."` (every nonce); then `access_delete`; a member given an id that is a machine pointer dies "served from the tenant's origin; remove it there" (L3346-3378).

Cloud expiry: Worker answers 404 once `now > expires` (L2713); bytes and record stay until a publisher's `ls`/`prune` removes them (gated ones only with an Access-proven token, else "waits for a publisher with the Access token") (L3316-3335).

### 2.6 Machine pointer v:2 (R3 only; one per local row)

| from | event | guard | to | artifacts | cite |
|---|---|---|---|---|---|
| none | local `add` on R3 | `r2_token_check` first; `PUT m/<id>` If-None-Match; 412 -> new id (<= 5), other -> die before anything is served | POINTER | `m/<id>` v:2 before bytes/app | L534, L547, L2948-2963 |
| POINTER | local row appended | | LINKED | row | L568 |
| LINKED | local `rm` / prune | token resolves for the mode (`soft` for rm; `prune_mode` for prune; `off` in hourly/quiet means never) | no pointer | `GET m/<id>` must be 200 and v:2 machine, then `DELETE`; else message "pointer stays until prune with the publisher token" | L688, L2999-3009 |
| LINKED | `setup --r2` (retro) | pointer written for each existing row | LINKED | `m/<id>` | L4123-4137 |
| any | member prune/ls, pointer `expires` past | `backend=r2` only | none | `DELETE m/<id>` ("removed expired pointer") | L3336-3342 |
| LINKED | reconcile (origin interactive `ls`/prune with a token) | table 2.8 | | | L2967-2997 |

Worker never checks a pointer's `expires`, `by`, or `own_host` (section 3). A pointer left behind with no row is harmless: Worker passes, Caddy 404s (S8:L149).

### 2.7 Gated variants (Cloudflare Access)

| variant | order of effects | extra persisted state | cite |
|---|---|---|---|
| local snapshot | `access_prepare` (preflight: token source, Zone Read, Access Orgs Read, Apps Edit probe via `POST {}` -> 400/12130; sweep; group name -> id) -> stage OUTSIDE pub -> (R3 pointer, gated flag) -> `access_create` (name `share <id> <host> <nonce>`, destinations `<host>/<id>`, `<host>/<id>/*`, +fqdn) -> `host_add` -> `access_gate` 3 rounds (probe URLs redirect to `*.cloudflareaccess.com` with `kid == aud`) -> index lock -> `pending_has` still mine -> `stage_publish` -> row with `access=<uuid> access_rule=<rule>` -> `pending_drop` -> link check 302/403 | pending line `-:nonce` -> uuid -> dropped; `held_access_id` | L526-577, L2139-2144, L2218-2246, L2302-2324 |
| local rm | (gated) `api_token_resolve` mandatory (not prune) -> `access_account` -> `access_sweep` -> pending line (owner pid, or 0 = deferred) -> bytes/row -> `access_delete` (name must start `share <id> <host|alias> `) | pending line until delete | L669-698, L2247-2263 |
| cloud | app created between upload and record; record carries `aud` and `opts access=<uuid> access_rule=<rule>` (the rule IS in the cloud record, unlike the pointer) | pending line | L3034-3051 |
| pointer | `gated` flag only | | L2939 |
| sweep | per pending line: live owner (pid + start time + `*share*`) skipped; finished-add stale line dropped; orphan bytes trashed; `-:nonce` found by app-name suffix over all pages; `>600 s` old unmatched line forgotten; R2: fresh `GET m/<id>`, record naming the app = finished, 404 = delete app + `o/<id>.<nonce>/` | | L2353-2414 |
| loss mode | Access app deleted behind share's back: local row stays, link becomes PUBLIC; `ls` warns (env token only). On R5 the Worker still checks the JWT, so the link closes | | L2422-2437 |

### 2.8 Who runs what: `ls`, `prune`, `status`, `serve`, and the reconcile

| trigger | local expiry | access sweep | cloud expiry + pointer expiry (member) | orphan-upload sweep | reconcile (origin) | token used |
|---|---|---|---|---|---|---|
| `serve` start / `status` / `cmd_prune quiet` | yes | no | no (r2_snapshot read only on member) | no | no | none (`api_token=""`, `prune_mode=off`) |
| hourly loop (`bash share prune`) | yes | no | no | no | no ("not checked: no publisher token") | `SHARE_API_TOKEN_OFF=1` inherited from serve: none |
| `ls` (`prune listing`) | yes | if env `CLOUDFLARE_API_TOKEN` | yes (R5 / R3 with env token only) | no | yes, only with env token | env only; never `api_token_cmd` or Keychain for the prune/reconcile leg; the LIST itself uses full `r2_creds` |
| `prune` (bare) | yes | yes (soft) | yes | yes (`r2_sweep_orphans`) | yes (R3) | full resolver, soft |
| `state` | no | no | no | no | no | read-only; bucket read only with stored token (Keychain/file) |

cites: L701-728, L3316-3344, L3292-3314, L4811, L1181, L1206, L1435-1448, L1450-1487, L2871-2877.

Reconcile cases (R3, after `r2_read`; the subshell `( r2_prune; r2_reconcile )`, L705):

| local row (unexpired) | `m/<id>` state | other | action | cite |
|---|---|---|---|---|
| no | valid v:2 pointer, `LastModified` older than now-600 s | no pending line for id; no live `.lock-add-<id>` | `DELETE m/<id>`, print "removed orphan pointer" | L2971-2981 |
| no | valid v:2 pointer, younger than 10 min | | skip (an add may be writing its row) | L2975 |
| yes | valid v:2 pointer | | nothing | L2985 |
| yes | key absent | | write pointer If-None-Match; 200 "wrote the missing pointer"; 412 falls to shadow; other -> retry next time | L2986-2993 |
| yes | key present but not a valid v:2 (cloud v:1, corrupt, v>2) | | print "`<id>` is shadowed by a cloud link; rm one of them"; NOTHING deleted | L2995 |
| expired | any | | skipped (prune owns it) | L2984 |

Comment in code: "one origin per tenant: every machine pointer is this machine's" (L2971). Shadowed ids: Worker serves the cloud record (v:1) and never reaches the local file (section 3).

### 2.9 `ls` / listing assembly

`list_rows` (L2897-2923): tunnel profile = local rows (`storage=machine`, type from `pub/<id>/<name>`, `by` from opts else `r2_by`), then, if `r2on`, `list_bucket` rows. `list_bucket` (L2879-2895): `r2_read` (LIST `m/`, parallel GET <= 8, keys must match `^m/[0-9a-f]{6}$`); cloud rows; ids with a local row are skipped (shadowed id lists once); only for `backend=r2` the unexpired v:2 pointers are appended as `storage=machine`. A bucket failure leaves local rows and sets `cloud_error` (exit 0). `state` limits to the newest 25 non-local records (`cloud_more`) (L3241-3246).

---------------------------------------------------------------------------------------------------

## 3. Tenant Worker request routing

### 3.1 Constants and bindings

| item | value | cite |
|---|---|---|
| `WORKER_VERSION` | 4 (bump on every source change; deploy refuses downgrade without `--force`) | L2559 |
| `WORKER_SHA` | `2209e2a60db0` (first 12 hex of emitted source sha256; test suite asserts) | L2560 |
| `WORKER_COMPAT_DATE` | 2026-09-30 (metadata `compatibility_date`; moves only with a version bump) | L2561 |
| `WORKER_RECORD_V` | 2. DEFINED ONLY; its sole reference is `worker_meta` (L2563), which nothing calls. No runtime check uses it | L2562-2563 |
| bindings | `BUCKET` r2, `HITS` analytics dataset, `HOST`, `TEAM` (Access team domain or ""), `VERSION`, `SHA`, tenant: `PASS="1"`, `ALIASES=<alias>`; secret `SALT` (kept via `keep_bindings`) | L3766-3767 |
| `TEAM` source | `GET /accounts/<a>/access/organizations` `auth_domain` matching `*.cloudflareaccess.com`; if that GET fails keep deployed TEAM | L4064-4071 |
| redeploy trigger (tenant) | first, or VERSION, SHA, TEAM, PASS!=1, or ALIASES differ | L4110 |
| redeploy trigger (r2-only) | first, or VERSION, SHA, TEAM differ | L4376 |

### 3.2 Decision table (first match wins)

| # | condition | PASS=1 (tenant) | PASS=0 (r2-only) | cite |
|---|---|---|---|---|
| 1 | `hostname` in `ALIASES` | GET/HEAD: `301 Location: https://<HOST><path+query>`; other method 405 | same | L2673-2677 |
| 2 | `hostname != HOST` | 404 | 404 | L2678 |
| 3 | method not GET/HEAD | continues (origin may need POST) | 405 | L2679 |
| 4 | raw path matches `%2f %5c %2e %00-%1f` (case-insens.) or contains `//` | 400 (checked BEFORE healthz and BEFORE pass) | 400 | L2680-2683 |
| 5 | `/healthz` | non-GET 405; else fetch `https://<HOST>/healthz` (3 s timeout, route skipped for same-host fetch); origin 200 body "ok" -> `200 ok`, `X-Share-Tunnel: 1`; else `503 tunnel down`, `X-Share-Tunnel: 0`. Always `X-Share-Worker: "<VERSION> <SHA>"`, `X-Share-Gate: 1` iff TEAM | `200 ok` with the two headers (no tunnel header) | L2684-2698 |
| 6 | first path segment not `[0-9a-f]{6}` | PASS (pass-through) | 404 | L2699-2701 |
| 7 | `BUCKET.get("m/<id>")` throws, exceeds 2000 ms, or absent | PASS | 404 | L2702-2704 |
| 8 | record body not JSON | 404 (NOT passed) | 404 | L2705-2706 |
| 9 | `v === 2 && storage === "machine"` | PASS (no other field read: `expires`, `by`, `own_host`, `id` ignored) | 404 | L2707-2709 |
| 10 | not (`v===1`, no `storage` key, `id` matches, `prefix` matches `^o/<id>\.[0-9a-f]{8}/$`, not past `expires`) | 404 (never passes: stale/forged cloud id must not fall to the origin) | 404 | L2710-2715 |
| 11 | gated (`aud` non-empty string, or `opts` has `access=`) | `gatedOk` else 404: TEAM bound; `aud` 64 hex; `cf-access-jwt-assertion` present; RS256; `iss == https://<TEAM>`; `aud` claim contains record aud; `exp`/`nbf`; RSA key by `kid` from `https://<TEAM>/cdn-cgi/access/certs` (isolate cache 1 h, refetch <= 1/min, failures never cached) | same | L2716-2720, L2610-2632, L2594-2608 |
| 12 | method not GET/HEAD (cloud record only) | 405 | 405 | L2721 |
| 13 | `/<id>` with no further segment | `308 -> /<id>/` | same | L2722-2723 |
| 14 | object lookup under `rec.prefix`: URI decode failure 400; trailing `/` -> `index.html` then `README.html`; no slash -> exact key; folder without slash with an index/README under it -> `308` to slash; Range past end -> 416; conditional hit -> 412 (`body===null`); Range -> 206; `Content-Type` from extension map else octet-stream; absent -> 404 | | | L2724-2762 |
| 15 | any exception in `handle` | 404 | 404 | L2770-2771 |
| 16 | post-processing for non-passed answers: `Cache-Control: no-store`, `X-Robots-Tag: noindex, nofollow`; if status < 400, not `/healthz`, `HITS`+`SALT` bound, first segment hex: `HITS.writeDataPoint({indexes:[id], blobs:[id, sha256(SALT+cf-connecting-ip)[:16]]})` (includes the alias 301 and cloud hits; passed responses are never counted) | | | L2772-2780 |

### 3.3 `pass()` and the offline page

`pass(request)` = `fetch(request)` (same-host fetch from a Worker skips the route, so it reaches the tunnel CNAME) (L2646-2648). 101 (WebSocket) returned untouched. "Down" := fetch throws, or status 530, 520-527, or 503 WITHOUT `cf-cache-status` (the header only the origin's answers carry) -> `503`, body `the machine serving this link is offline; try again later`, `Retry-After: 60`, `text/plain`. Anything else (including Caddy's own 502 for a dead live port) is returned rewrapped with `no-store` + `X-Robots-Tag`. `passed` WeakSet keeps these out of hit counting and header overwrite (L2643-2662, L2772). Rule history: 502 was removed from the down set in version 4 (A8; implementation-notes one-host-per-tenant.md).

### 3.4 `/healthz` consumers (`r2_healthz`, L3706-3739)

Reads status, `X-Share-Worker`, `X-Share-Gate`, `X-Share-Tunnel`. A `503` with a well-formed `<n> <12hex>` pair and `X-Share-Tunnel: 0` is mapped to `hz_code=200` (Worker up, origin down); a `200` whose body is not `ok` is `000`. Used by: join (any pair accepted), admin/tenant wait (pair must equal this CLI's; tenant also needs tunnel leg 1), gated add precheck (`X-Share-Gate: 1`), `status`, `state ready`.

### 3.5 Version skew between CLI and Worker

| situation | behavior | cite |
|---|---|---|
| CLI newer than deployed Worker (member) | join prints hint to rerun admin setup (tenant: "on the tenant's origin"); `status` prints mismatch; nothing blocks | L4322-4326, L3455-3456 |
| CLI newer (admin/origin setup) | redeploy when VERSION or SHA differ; `r2_wait_healthz admin|tenant` requires the new pair | L4110, L4376, L3746 |
| CLI older than deployed Worker | `setup` dies "Worker runs version N, newer than this share's M" unless `--force` (a downgrade); r2-only admin path also | L4013-4014, L4271-4272 |
| Worker too old for v:2 | answers 404 for pointers (strict `v===1`) | L2711 |
| CLI too old for v:2 | `r2_record_row` requires `v==1` so v:2 vanish from its `ls`; its orphan sweep sees an unreadable record and skips the whole sweep with a warning | L3181, L3293-3295, S8:L158 |
| record newer than this CLI (v>2, unknown shape) | `r2_record_raw` -> `error("unreadable")` -> `r2_sweep_block` (no upload deleted anywhere by this CLI); `r2_record_row` drops it from display; if its id has a local row, reconcile prints "shadowed" | L3283-3287, L2995 |
| Worker answer for v>2 | 404 (not passed) | L2710-2715 |
| origin on an older CLI with R2 on | keeps adding local links WITHOUT pointers; next upgraded `ls` writes them or names collisions | A8 Consequences |

---------------------------------------------------------------------------------------------------

## 4. Publisher / member token lifecycle

### 4.1 Token kinds

| kind | where it lives | used for | cite |
|---|---|---|---|
| tunnel token | Keychain `share-tunnel...`, or `$config_dir/tunnel-token`, or `token_cmd` | `cloudflared run` env `TUNNEL_TOKEN` (origin only) | L293-316, L1233 |
| admin token | `CLOUDFLARE_API_TOKEN` env ONLY (never stored) | setup/teardown/migrate, Worker deploy, `--r2`/`--no-r2`/purge, `--host` | L3841, L4245, L967 |
| Access token | `api-token` store | gated adds/rm, sweeps (tunnel profile) | L2439-2503 |
| publisher token | same store as Access token (`share-api...`) or `r2_token_cmd`/`SHARE_R2_TOKEN`; a Cloudflare USER token with "Workers R2 Storage Bucket Item Write" on this bucket only + Zone Read | all bucket reads/writes; S3 creds derived: key id = `GET /user/tokens/verify` `.result.id`, secret = sha256(token) | L3500-3516, L2955-2962 |
| login cert | `$config_dir/cert.pem` | tunnel/DNS ops without an API token | L1517-1540 |

### 4.2 `api_token_resolve [env|soft]` (L1905-1934)

Order: `SHARE_API_TOKEN_OFF=1` -> nothing; else (mode != env) config `api_token_cmd` (eval; failure dies, or warns and resolves nothing under `soft`) -> Keychain `share-api[.p]:<host>` -> file `$config_dir/api-token` -> `CLOUDFLARE_API_TOKEN`. Mode `env` skips straight to the environment. `r2_creds` order: `SHARE_R2_TOKEN` -> config `r2_token_cmd` -> `api_token_resolve` (L3503-3509).

### 4.3 Storage and refusals

| action | refusal / guard | cite |
|---|---|---|
| `api-token` (paste or stdin) on R3/R5: `r2_publisher_check` BEFORE store | die if `GET workers/scripts/<w>/settings` = 200 (token can edit the Worker = admin); die on other than 200/401/403; die if `GET r2/buckets` = 200 listing any bucket other than this one (account-wide R2); 401/403 accepted | L2476, L2521-2542 |
| `api-token --cmd` on R3/R5 | command is run once and its token checked before the line is written to config; later rotations inside the command are NOT rechecked | L2448-2456 |
| token store | charset `[A-Za-z0-9_-]`; Keychain via `security -i` stdin, else 0600 file (tmp+mv) | L1936-1943 |
| env `CLOUDFLARE_API_TOKEN` used as publisher | checked once per process in `r2_creds` (`r2_publisher_check ... env`) | L3507 |
| `api-token --check` | R3/R5: requires a resolved token, re-runs publisher check, expiry note, then `access_preflight` (on R5 a failing preflight is non-fatal: ungated adds work); tunnel profile: preflight only | L2482-2502 |
| expiry note | `GET /user/tokens/verify` `expires_on`; warns <= 14 days or already expired (shown on `api-token`) | L2504-2520 |
| `state` (menu poll) | bucket read only with stored token (Keychain/file), never a command or env | L2871-2877 |
| quick mode, `api-token` | refused (`access_named_only`) | L2441 |
| `join` | needs an admin-set-up host: bucket exists, marker names host | L4282, L4307 |

`r2_creds` never writes the token to argv, a file, or output; curl gets it via `-K <(...)` (L3539).

### 4.4 What happens when a member's token is deleted, revoked, or expired

| operation | result | state left | cite |
|---|---|---|---|
| any bucket call | `/user/tokens/verify` returns no `result.id` -> `r2_creds` returns 1 -> "no r2 publisher token for <host>"; with a stale-but-present key id, S3 answers 403 | none | L3510-3514, L3529 |
| `add` | `r2_id_taken` dies "needs a publisher token"/"(HTTP 403); no id was picked" | none (stage cleaned) | L176-186 |
| `ls` / `state` | `cloud_error`, exit 0; local rows (R3) still listed | none | L2913-2920 |
| `rm`, `refresh`, `prune` | die at first bucket call | none | L3349, L3385 |
| in-flight add | upload prefix cleanup needs the token: prefix stays until a prune by anyone after 24 h | orphan `o/<id>.<nonce>/` | L2837-2839, L3292-3314 |
| links already published | keep serving (Worker reads via its R2 binding, not the member's token) | records stay | L2702 |
| member's expired shares | other publishers' `ls`/`prune` remove them (any publisher may `rm` any cloud share) | | L3347 |
| member's gated shares | their Access apps are removed by any publisher with Access scopes (name-checked); pending lines on the member's disk stay | `access-pending`, `r2-own` | L2247-2263 |
| origin (R3) with its publisher token gone | local `add` dies at `r2_token_check` BEFORE writes; local rm/prune still work but the pointer stays ("until prune runs with the publisher token"); reconcile skipped | orphan pointers | L534, L3001 |
| origin hourly prune | never had the token (`SHARE_API_TOKEN_OFF`) so pointers/cloud expiry were never its job | | L1181 |

### 4.5 Who may rm / refresh / hits what (`by` semantics)

`by` = `r2_by`: `uname -n` short name, lowercased, chars `[a-z0-9.-]`, else `unknown` (L2828). Written into v:1 and v:2 records at add time (L3049, L2941) and into imported local rows (L797). Shown in `ls`/`state` (L618-633). Required by `rows_in` for r2 rows (`hb`, L113, L127-133) and by the record validators (`^[a-z0-9.-]+$`, L3188, L3272). It is NOT authenticated: any holder of a publisher token can write any `by`, and two machines with the same short hostname are indistinguishable. No authorization decision reads `by` except one: `refresh` of an IMPORTED local row (L644-645).

| actor | target | rm | refresh | hits | basis | cite |
|---|---|---|---|---|---|---|
| origin | own local row | yes (+pointer drop) | yes (re-copy) | Caddy `access.log` | row exists | L658, L636, L730 |
| origin | cloud row | yes (dispatch: no local row) | only if it added it (`r2-own` prefix match) | Analytics Engine SQL | | L660, L638, L3426 |
| member | own cloud row | yes | yes (own install) | AE SQL | `r2-own` line | L3346, L3380 |
| member | another publisher's cloud row | yes ("any publisher may rm any share") | no: "added from another install; refresh it there" | AE SQL | no `by` check | L3347, L3397 |
| member | machine pointer | no: "served from the tenant's origin; remove it there" (rm, refresh) | no | AE gives 0 + hint | storage==machine | L3351-3353, L3392-3393, L3443-3444 |
| any publisher | expired cloud row | removed by their `ls`/`prune`; gated only with Access-proven token | | | | L3316-3335 |
| member | expired machine pointer | its prune deletes the pointer; origin's prune unpublishes the link | | | | L3336-3342 |
| member | `add --local`, `add <port>`, `--host` | refused | | | | L489-490, L501 |

---------------------------------------------------------------------------------------------------

## 5. Concurrency and idempotency

### 5.1 Local locks (same machine/profile only)

`lock_take <name> [secs]`: `ln -sn $$ $root/.lock-<name>`; a lock whose pid is dead is renamed to a private name, re-read, deleted only if still dead (else put back); wait 0.2 s steps up to `secs*5` polls (default 60 s) then die. EXIT trap `release_locks` re-armed on every take (L207-243).

| lock | held across | cite |
|---|---|---|
| `index` | row append + Caddyfile render + reload; rm row removal; refresh swap; pending-line edits; setup --r2 steps 1-9; import publish; sweep claim | L562-573, L681-686, L648-654, L4075-4153, L821-826, L2358 |
| `host` | one Cloudflare-side ingress/DNS edit (60 s) | L1748-1749, L1787-1806 |
| `add-<id>` | R3 only: marks "a live add holds this pointer" for the reconcile; 5 s take; released after row | L2954, L2965, L574 |

None of these coordinate across machines.

### 5.2 Id generation and collision handling

| context | mechanism | cite |
|---|---|---|
| id space | 24 bits (`od -N3`) | L152 |
| tunnel R2 off | loop until no row, no `pub/<id>`, no pending line (no cross-process reservation: two concurrent adds could pick the same id; the later `stage_publish` replaces the earlier tree) | L171 |
| R3 / R5 | additionally live `GET m/<id>` (must be 404) and `LIST o/<id>.` (must be empty); any other HTTP fails closed | L172, L176-186 |
| R3 pointer | `PUT m/<id>` If-None-Match `*`: 412 -> new id, up to 5 tries then die | L2953-2962 |
| cloud record | `PUT m/<id>` If-None-Match `*`: 412 -> trap deletes own prefix (and gated app), "rerun the same add" | L3052, L3056-3061 |
| import | refuse existing row / `pub/<id>` / pending id; re-check under lock | L803, L822 |
| shadow | a v:1 record and a v:2 pointer or local row sharing an id can only arise when the origin had no pointer (older CLI, no token, or pre-`--r2` rows); Worker prefers the cloud record | L2711, L2995 |

### 5.3 Conditional writes in R2 (the only cross-machine concurrency control)

| write | condition | cite |
|---|---|---|
| cloud record publish | `If-None-Match: *` | L3052 |
| machine pointer | `If-None-Match: *` | L2944 |
| refresh swap | `If-Match: "<etag>"` of the GET just made | L3409 |
| marker create | `If-None-Match: *` | L4097, L4368 |
| marker alias update | `If-Match` (or unconditional PUT when no marker was read) | L4160 |
| `DELETE m/<id>` (rm, reconcile, pointer drop, expired pointer) | unconditional; rm follows with a fresh GET to prove 404 | L3367-3369, L2978, L3006, L3339 |
| uploads | each add writes a NEW prefix `o/<id>.<nonce8>/`; swap is the record PUT; nothing overwrites bytes in place | L3030, L3403 |
| orphan sweep | deletes unreferenced prefixes whose newest object is > 24 h (local clock vs S3 `LastModified`); skipped if any record unreadable/newer | L3292-3314 |
| reconcile age test | `LastModified` < now - 600 s (local clock) | L2969, L2975 |
| r2 calls | 429/5xx retried up to 3 times, `Retry-After` capped at 30 s | L3537-3547 |

### 5.4 Atomicity of local files

`index` rewrite on rm: `mktemp` + `awk` + `mv -f` (L682-683); `config`, `Caddyfile`, `r2-own`, `pending`: tmp + `mv -f`. `stage_publish`: `mv pub/<id> <stage>.old; mv <stage> pub/<id>; rm -rf .old` is two moves, so `pub/<id>` is briefly absent during a refresh (L434-436). Appends to `index.tsv` rely on the index lock.

### 5.5 Reruns that converge

- `setup <host>` (R2): reuses tunnel by name; rewrites ingress (NOT convergent for `--host` rules), CNAME "already points", token re-stored (L4500-4540).
- `setup --r2` (R3): deploy/pointers/route/alias domain each skipped when already in place (section 1.4).
- `setup --backend r2` (R4/R5): marker 412 re-read, deploy compare, domain `ours` skip (L4365-4391).
- `add` after "nothing was published": new id each run; stale app/pending claimed by next sweep (L2353).
- `migrate`: already-copied ids skipped; switch uses `--force`; verify gated (L1011, L1048).
- `access_create`/`access_sweep`: intent line first, app, uuid into line, read-back; a sweep that claimed the line makes the adder die "rerun" (L2218-2246, L563-567).
- `teardown --purge`: each delete dies before the Worker goes; rerunnable (L4698-4707).

---------------------------------------------------------------------------------------------------

## 6. Gaps a multi-member design must handle (list only)

Topology and routing
1. Exactly one connector and one ingress per tenant: ingress rule 0 -> `http://127.0.0.1:<port>`; the tunnel token lives in ONE machine's Keychain; `hosts=` is a name allow-list, not a lease; `serve` only checks `this_host in hosts` (L83, L1179, L4508). A second machine running the same token would load-balance silently.
2. Worker `pass()` is `fetch(request)` to the same hostname: no machine selection input; the pointer's `by` and `own_host` are never read by the Worker (L2646-2648, L2707-2709). Pointer opts are whitelisted to `noindex|live|gated`, so a new routing field fails both CLI validators (`r2_take` L3273) and must be added to every reader.
3. `healthz` has one tunnel boolean; the offline page text cannot name which member is down (L2691-2697, L2644).
4. `--host` FQDNs sit outside the Worker route and share the single tunnel via ingress+CNAME edits needing a tenant-wide Cloudflare credential (L1713-1746); a member cannot create one. `setup` rerun wipes extra ingress rules (L4507).
5. Machine-link expiry is not enforced by the Worker (pointer `expires` ignored); enforcement is the serving machine's prune, hourly, and without a token the pointer is never dropped by that loop (L1181, L1206, L2707).

Ownership and identity
6. The origin's reconcile deletes ANY valid v:2 pointer without a local row after 10 min ("one origin per tenant"), so a member-written pointer would be reaped (L2971-2981). `r2_pointer_drop` deletes any v:2 for an id the origin itself removes (L3005).
7. `by` is the short `uname -n`: unauthenticated, non-unique, forgeable by any token holder; no signing; authorization today = (a) storage kind, (b) local `r2-own` file, (c) "any publisher may rm any share" (L2828, L3347, L3397).
8. Member refusals are keyed on `storage==machine` and `backend==r2`: a member can neither publish nor remove nor refresh a machine link; there is no notion of "my machine row" in the bucket (L489-490, L3351, L3392).
9. Admin/member is not persisted; the admin token is env-only and the tenant Worker can only be redeployed from the origin profile; join writes nothing on Cloudflare, so there is no non-admin path to register a member machine (Workers VPC binding changes would need admin) (L4254-4262, L4314-4330, L4274).
10. Marker `share.json` is writable by anyone with bucket write and is trusted by joiners for aliases (kept only when a 301 is observed) (L4318-4321).
11. Everything assumes ONE Cloudflare account and ONE zone: `access_account` (L2063), `tenant_admin` zone walk (L3802-3815), S3 creds from a user-token id.

Namespace and versions
12. Single id namespace with 24-bit ids depends on every writer using `If-None-Match`; an origin without pointers (older CLI, no token) can be shadowed by a member's cloud id; Worker prefers the cloud record (L2711, L2995).
13. `WORKER_RECORD_V` and `worker_meta` are dead code; version skew is handled only by VERSION/SHA at deploy time plus per-reader `v` checks; a record of an unknown version blocks the orphan sweep for every CLI that cannot read it (L2562-2563, L3283-3287).
14. All time windows (10 min reconcile, 24 h sweep, `expires`) compare local clocks with S3 `LastModified`; no skew handling beyond "24 h absorbs any sane skew" (L3298).
15. `ls` on a member lists all of `m/` and GETs each key (8 parallel); `state` caps at 25 (L3238-3258, L3241).

Gating
16. Access apps are per `<host>/<id>` path on the one hostname; app name embeds host and nonce; pointer carries only `gated`; the Worker does not verify a JWT for passed (machine) links, so a member-served gated link depends entirely on the Access app existing (L2221, L2707-2709, L2939). `access_ls_check` reports a vanished app only on tunnel profiles with an env token (L2422).
17. The cloud record (v:1) carries `access_rule` (email lists) readable by every publisher; the pointer deliberately omits it (L3043, L2939).

Partial states (all currently self-healing only partly)
18. Unlisted but reachable `pub/<id>` if an add dies between `stage_publish` and the row append (L549 vs L568); no sweep trashes it unless an Access pending line exists (L2371-2374).
19. Orphan pointer (add died after `PUT m/<id>`): reaped after 10 min only when an interactive `ls`/`prune` with an env token runs on the origin (L705, L2967).
20. Orphan upload prefix: 24 h, only by a bare `prune` on any publisher (L3343).
21. `teardown` on an R3 origin deletes the tunnel and CNAME but leaves the route, Worker, pointers, and marker; config (with bucket keys) is trashed (L4557-4639).
22. `migrate` refuses R3 and `--host`; R6 is detectable only indirectly (index.migrated, missing token, deleted tunnel id) (L959-966, L897-936).
23. Crash between cloud `PUT m/<id>` and `r2_own_put` leaves a published share this install cannot refresh (L3052-3069).
24. Hits: machine links are never counted by the Worker (passed responses skip it); stats for them are the serving machine's Caddy `access.log`, so a multi-machine tenant has per-machine hit logs (L2643, L730-744).
