# SPEC-005: profiles (two share instances on one machine)

Status: DRAFT
Lane: full
ADR: docs/decisions/ADR-0005-profile-is-a-path-prefix.md

## Problem

One machine can run one share. Every path, the service label, the port, and the
Keychain item are fixed by `$HOME`, so a second setup (another Cloudflare account,
another hostname) overwrites the first. The operator needs `s.han.ws` (personal
account) and `s.d.foundation` (Dwarves account) served from the same Mac Mini at the
same time, and existing installs must keep working with no migration.

## Picture

```
 share [--profile P] <verb> ...          SHARE_PROFILE=P (environment)
          |                                      |
          +-------------- flag wins -------------+
                           |
             P empty or "default"? --yes--> default column
                           | no
        validate ^[a-z0-9][a-z0-9-]{0,31}$   (die before any path is built)
        any later arg --profile / --profile=* -> die "goes before the verb"
                           v
 +-----------------------------+   +------------------------------------+
 | default (byte-identical)    |   | profile P                          |
 | cfg  ~/.config/share        |   | cfg  ~/.config/share/profiles/P    |
 | root ~/share                |   | root ~/share/profiles/P            |
 | svc  foundation.d.share     |   | svc  foundation.d.share.P          |
 | key  share-tunnel:<host>    |   | key  share-tunnel.P:<host>         |
 | port 8787/8788 or port=     |   | port= picked once at setup (8789+) |
 +-----------------------------+   +------------------------------------+
   SHARE_CONFIG_DIR / SHARE_ROOT / SHARE_PORT / SHARE_SERVICE_LABEL /
   SHARE_HOSTNAME / SHARE_HOSTS override either column, as today
                           |
           export SHARE_PROFILE=<normalized P>   (always, "" for the default)
           +----------------+---------------------+
           v                v                     v
  nohup bash $0 serve   hourly bash $0 prune   plist / unit env (named only):
                                               SHARE_PROFILE + the pinned dir and root

 One Mac at runtime:
 s.han.ws       -> CF account A -> cloudflared -> caddy 127.0.0.1:8787 -> ~/share/pub
 s.d.foundation -> CF account B -> cloudflared -> caddy 127.0.0.1:8789 -> ~/share/profiles/P/pub
                   serve dies when its port or metrics port already answers
                   (caddy binds with SO_REUSEPORT: a double bind would split requests silently)
```

## Design

Chosen: a profile is a validated slug that supplies the default for each per-install
value (config dir, root, label, Keychain key, port); the explicit `SHARE_*` overrides
keep their precedence. Alternatives and why they lost: ADR-0005. Nothing is shared
between profiles, so the only cross-profile logic is two read-only scans: the other
profiles' config files (`other_cfg`), used for three refusals (the port pick, `add <port>`
of another profile's port pair, and `setup` on a hostname another profile owns), and
every profile's `index.tsv` (`live_shared`), used by the port pick to skip a port any
profile live-shares. Both scans follow the derived locations (`~/.config/share`,
`~/share`, and their `profiles/` subdirectories); a profile moved with `SHARE_ROOT` or
`SHARE_CONFIG_DIR` is invisible to them (DEC-007).

## Behavior contract

### Selecting a profile

- `share --profile <name> <verb> ...` selects a profile for that command. The flag
  takes a separate argument and comes before the verb. `--profile` or `--profile=...`
  anywhere after the verb dies with `share: --profile goes before the verb: share
  --profile <name> <verb>`, because the fixed-position dispatch (`teardown "${2:-}"`)
  would otherwise run the verb against the default install.
- `SHARE_PROFILE=<name>` selects the same profile from the environment. The flag wins
  over the variable. An empty variable is the default profile.
- No flag and no variable, or the name `default`, is the default profile: every path,
  Keychain item, service label, port, and config location is byte-identical to today.
- A profile name, from the flag or the variable, is validated before anything else:
  `^[a-z0-9][a-z0-9-]{0,31}$`. Any other value dies with `share: bad profile name
  '<name>' (a-z, 0-9, -; 32 chars max)` before a path is derived, so `..`, `/`, and
  spaces never reach a path, a plist, or a Keychain service name.
- share exports the normalized `SHARE_PROFILE` unconditionally, so `nohup bash "$0"
  serve` (`share start` without the service) and the hourly `bash "$0" prune` run under
  the same profile, and `SHARE_PROFILE=a share --profile default start` starts the default.

### What a profile maps to

| Item | Default profile (unchanged) | Profile `<p>` |
|---|---|---|
| config dir | `~/.config/share` | `~/.config/share/profiles/<p>` |
| root (pub, index, pidfile, locks, logs) | `~/share` | `~/share/profiles/<p>` |
| launchd label / systemd unit | `foundation.d.share` | `foundation.d.share.<p>` |
| Keychain item (account `share`) | `share-tunnel:<hostname>` | `share-tunnel.<p>:<hostname>` (built when used, since setup learns the hostname after the script loads) |
| token file (Linux), `cert.pem`, `cert.zone` | under the config dir | under the profile's config dir |
| port / metrics port | `8787` / `8788`, or `port=` in config | `port=` in the profile's config, picked at setup |

`SHARE_CONFIG_DIR`, `SHARE_ROOT`, `SHARE_PORT`, `SHARE_SERVICE_LABEL`, `SHARE_HOSTNAME`,
and `SHARE_HOSTS` keep overriding the derived value, as they do today (the service plist
relies on the first two). `XDG_CONFIG_HOME` moves the config base for every profile,
including the `profiles/` directory. An override that points two profiles at one
directory is caught at serve time by the port guard below, not at parse time.

### Port of a named profile

The first `share --profile <p> setup ...` (named or `--quick`) with no `port=` in the
profile's config and no `SHARE_PORT` picks a port before any Cloudflare call, and
reassigns both `port` and `metrics_port`, so the ingress rule setup writes and the
config it stores carry the same value. The pick: the lowest odd `p >= 8789` such that
the pair `{p, p+1}` is disjoint from `{q, q+1}` for every other profile's `port=` `q`
(the default profile claims `8787` even before its own setup), neither is the port of a
live share in any profile's index (a dev server that is down today would otherwise be
proxied onto the new profile's caddy tomorrow), and nothing listens on `p` or `p+1`. Setup prints `port:       <p> (metrics <p+1>)` and writes `port=<p>` to
the profile's config. A rerun of setup keeps the stored port.

### Collisions are refused, never silent

- `share serve` dies before starting caddy when `127.0.0.1:<port>` already accepts a
  connection, and, with the tunnel on, when the metrics port does: `127.0.0.1:<port> is
  already in use: an orphaned server, or another share profile (share profiles)? free it,
  or change port= in <config> and rerun share setup` (the rerun moves the tunnel's ingress
  rule to the new port). This applies to the default profile too: today an orphaned caddy
  lets a second one bind the same port and split requests; that becomes a loud failure.
- `share add <port>` refuses a port that is another profile's port or metrics port:
  `<port> belongs to another share profile (share profiles)`, so one profile never
  republishes another profile's shares under its own hostname.
- `share setup <hostname>` refuses a hostname that another profile's config already
  holds: `<hostname> is already the hostname of another profile (share profiles)`, so
  two profiles never reuse, then delete, one tunnel.

### The service

`svc_install` writes `SHARE_PROFILE=<p>` into the plist or unit environment for a named
profile, beside the `SHARE_CONFIG_DIR` and `SHARE_ROOT` it already pins, so the daemon
reads the profile's Keychain item. The default profile's plist and unit are unchanged.

### Every verb honors the profile

`setup`, `add`, `ls`, `refresh`, `rm`, `hits`, `prune`, `start`, `stop`, `service`,
`status`, `state`, `serve`, `teardown`, and `skill` all run against the derived paths,
label, and Keychain key. `share ls` shows one profile. `teardown` of a named profile
also removes the profile's config dir when it is empty afterwards; the root
(`~/share/profiles/<p>`, with its shares) stays, as it does for the default.

### Listing profiles

`share profiles` prints one line per profile, the default first, then every directory
under `<config base>/share/profiles`, as `<name>\t<state>\t<host or ->`, the state and
host taken from that profile's `share state` run with `SHARE_ROOT`, `SHARE_CONFIG_DIR`,
`SHARE_PORT`, `SHARE_HOSTNAME`, `SHARE_HOSTS`, and `SHARE_SERVICE_LABEL` unset. A profile whose `state` fails prints `<name>\terror\t-` and
the listing continues.

### Help

`share --help` prints the whole usage header through the `Docs:` line, so the
`--profile` line, `profiles`, and the previously cut `serve`, `skill`, and `teardown`
lines all show.

### Everything else unchanged

Index rows, links, the Caddyfile, locks, quick mode, `--host`, `state` fields, the
skill text's rules. The only text additions: a `--profile` usage line, a `profiles`
verb, and one skill row.

## Files

- `bin/share`: profile parse and validation at the top; derived `config_dir`, `root`,
  `svc_label`, `token_key`, `me`; `other_cfg`, `port_claimed`, `live_shared`, `listening`,
  `free_port`, `profile_port`;
  the serve port guard; `cmd_profiles`; plist and unit environment; teardown rmdir;
  usage header and help range; skill row.
- `tests/share.sh`: a profiles section (see test plan), a Keychain-key probe, stubs
  for `security`, `launchctl`, and `systemctl`.
- `README.md`: Features row, Commands line.
- `docs/how-it-works.md`: files on disk for a profile, a Profiles section.
- `docs/setup.md`: a Profiles section (second account, headless setup, monitoring label).
- `docs/verification/profiles.md`: proof of done.

## Security / safety

- The profile name is the only new untrusted input. It is validated to a slug before
  any path, plist string, or Keychain key is built from it, and a misplaced flag is a
  refusal, never a silent fallback to the default install.
- Two profiles never share a Keychain item: the service name carries the profile, so
  two profiles set up for the same hostname in two accounts still hold separate tokens.
  The default key is unchanged. The token still goes through `security -i` on stdin
  and `TUNNEL_TOKEN` in the environment, never argv.
- A named profile's root sits under `~/share/profiles`, outside the default's `pub`,
  and the serve port guard plus the `add <port>` refusal keep one profile's caddy from
  serving another's files.
- Cloudflare credentials are per invocation (`CLOUDFLARE_API_TOKEN`) or per profile
  config (`token_cmd`, the login certificate). When SPEC-004's `share api-token` stores an
  API token (a token command or a Keychain item, on the tunnel token's pattern), that
  storage is namespaced per profile the same way: the config dir and the Keychain service
  name carry the profile, so two profiles never share or clobber an API token. The login
  service never reads an API token; it reads only the tunnel run token.

## Failure modes

| Failure class | Detection signal | Mitigation / recovery |
|---|---|---|
| `--profile` after the verb | the pre-dispatch scan finds it | die naming the right form; nothing runs |
| a bad name from the flag or the env | the slug check | die before any path is built |
| two profiles on one port (hand-edited `port=`, inherited `SHARE_PORT`, an override that collapses two profiles) | `serve` finds the port answering | die naming the port and the config to change; the other profile keeps serving |
| a live share of another profile's caddy or metrics port | `port_claimed` at `add` | die naming `share profiles`; no row written |
| two profiles on one hostname | `other_cfg hostname` at `setup` | die before any Cloudflare call |
| a profile's `state` fails inside `share profiles` | non-zero child | that row reads `error`, the rest print |
| a named profile's outage | none from Share Bar (it watches the default only) | `share profiles`; an external monitor watches label `foundation.d.share.<p>` |

## Task Breakdown

- [ ] TASK-001: parse, validate, derive. The top block (`profile`, the misplaced-flag scan, `config_dir`, `root`), `svc_label`, `token_key`, the unconditional export, the help range. Accept: test rows 1 to 4, 9, 13.
- [ ] TASK-002: ports. `other_cfg`, `port_claimed`, `free_port`, `profile_port` before any Cloudflare call in both setups, the serve guard, the `add <port>` refusal, the setup hostname refusal. Accept: rows 5, 6, 12.
- [ ] TASK-003: `share profiles`, the service environment, teardown rmdir, the skill row. Accept: rows 8, 10, 11.
- [ ] TASK-004: docs and the proof record (README, how-it-works, setup, verification). Accept: the docs name every item in the mapping table and the monitoring label.

## Test plan

| Row | Scenario | Assert |
|---|---|---|
| 1 | no `--profile`: derived paths, label, Keychain key | config `~/.config/share`, root `~/share`, label `foundation.d.share`, key `share-tunnel:<host>` |
| 2 | `--profile a` and `SHARE_PROFILE=a` | same derived paths under `profiles/a`; label `foundation.d.share.a`; key `share-tunnel.a:<host>`; the flag wins over the variable, both ways (`SHARE_PROFILE=b --profile a`, `SHARE_PROFILE=a --profile default`) |
| 3 | `--profile ../x`, `'a b'`, `A`, `x/y`, `-a`, each also as `SHARE_PROFILE`; `--profile` with no name | die before any write; the message names the rule or the usage |
| 4 | `--profile default`, `SHARE_PROFILE=` (empty) | identical to no flag |
| 5 | two profiles `setup --quick --no-service` under one `HOME` | each config holds its own `port=`; the pairs are disjoint from each other and from `8787/8788`; setup printed the pick; a third profile's pick skips a port the default live-shares; both serve at once; each answers on its own port and 404s on the other's; each `share ls` shows only its own rows |
| 6 | rerun `setup --quick` on a profile | the stored port is kept |
| 7 | `add`, `rm`, `refresh`, `hits`, `state`, `stop` under a profile | act on that profile's root only; the other profile's rows and server are untouched |
| 8 | `share profiles`, also with `SHARE_ROOT` exported | lists `default` (not set up under that HOME) and both profiles with state and host; the exported override does not leak into the rows |
| 9 | Keychain key with a stubbed `security`, in setup's order (token code loaded with an empty hostname, hostname assigned, then store) | `token_store` under profile `a` writes service `share-tunnel.a:<host>`; the default writes `share-tunnel:<host>`; no key ends in `:`; the token never appears in the stub's argv or log |
| 10 | `teardown --yes` on a quick profile | config trashed; the empty profile dir is gone; the profile leaves `share profiles`; the other profile keeps serving |
| 11 | `service install` for a profile with stubbed `launchctl`/`systemctl` | the file uses the suffixed label, carries `SHARE_PROFILE`, and pins the profile's config dir and root |
| 12 | collisions | `add <other's port>` and `add <other's metrics port>` die; `setup <other's hostname>` dies before writing; `serve` with `port=` hand-set to the other profile's port dies naming the port and this profile's own `setup` command while the other keeps answering |
| 13 | misplaced flag and help | `teardown --yes --profile a` and `stop --profile=a` die; `--help` shows the `--profile` line, `profiles`, and `teardown` |

Test seam: a stub `security` earlier in `PATH` that records the verb and the `-s`
service name it was asked for (never the `-w` value) to a log; stub `launchctl` and
`systemctl` that do nothing (`launchctl print` fails, so the unload wait returns at
once); the existing fake `cloudflared` for quick mode. Profile paths are exercised
through `HOME=$WORK/home` with `SHARE_ROOT`, `SHARE_CONFIG_DIR`, `SHARE_PORT`,
`SHARE_SERVICE_LABEL`, `SHARE_HOSTNAME`, and `XDG_CONFIG_HOME` unset.

## Verification

```sh
bash tests/share.sh
shellcheck bin/share install.sh tests/share.sh tests/e2e.sh demo/render.sh mac/*.sh
/bin/bash -n bin/share
```

Negative controls: (1) drop the profile from the Keychain service name: row 9 fails
(both profiles write `share-tunnel:<host>`); (2) make `free_port` return a constant:
row 5 fails (both configs hold the same `port=`, one profile answers on the other's port);
(3) fix the Keychain key at load time instead of when used: row 9 fails (every key ends
in `:`, the bug the second validation round found in the first implementation).

Live proof on the Mini, once a Cloudflare token with Tunnel Edit + DNS Edit + Zone Read
on `d.foundation` exists (not part of this PR; needs the operator's token):
`shasum ~/Library/LaunchAgents/foundation.d.share.plist ~/.config/share/config` before
and after `share --profile dfoundation setup s.d.foundation` are equal; `share profiles`
shows both profiles serving; `https://s.han.ws/healthz` and
`https://s.d.foundation/healthz` both answer 200; `launchctl print
gui/$(id -u)/foundation.d.share.dfoundation` shows the job running.

## After state

`share --profile dfoundation setup s.d.foundation` on the Mini creates a second tunnel,
service, and Keychain item beside the existing `s.han.ws` setup; `share add ./notes.pdf`
still publishes on `s.han.ws` with no change to any existing file. Docs and the skill say
how to pick a profile.

## Out of scope

- Share Bar reading a named profile: it runs the CLI with an inherited environment and
  no `SHARE_PROFILE`, so it shows the default only. The docs name the launchd label a
  monitor can watch for a named profile.
- `--profile=<name>` as one argument: the flag takes a separate argument.
- A profile e2e run in `tests/e2e.sh`: it pins every override for its throwaway
  instance; the live proof above covers the profile path by hand.

## Decision Log

- DEC-001: `default` is a reserved alias for the unnamed profile, never a directory, so the existing install never moves.
- DEC-002: the `SHARE_*` overrides keep precedence over the profile; the serve port guard, not a parse-time refusal, catches an override that collapses two profiles onto one config, because a moved root for one profile is a legitimate use of the override.
- DEC-003: profiles nest under `~/share/profiles` and `~/.config/share/profiles` rather than siblings (`~/share.<p>`): one directory to list and to back up, and the operator's rule never deletes `~/share` wholesale.
- DEC-004: a misplaced `--profile` is a refusal, not a second parse, because the fixed-position dispatch would otherwise run `teardown --yes` against the default install.
- DEC-005: the serve guard applies to the default profile too, turning a silent SO_REUSEPORT double bind into a loud failure.
- DEC-007: the cross-profile scans (`other_cfg`, `live_shared`) read the derived locations only and ignore `SHARE_ROOT` and `SHARE_CONFIG_DIR`; a profile moved by an override is a deliberate step outside the layout, and the serve port guard still catches a resulting collision.
- DEC-008: every message that names a command to run builds it from `me` (`share` or `share --profile <p>`), so a recovery hint for a named profile never points at the default install.
- DEC-006: the Keychain key is a function, not a variable: `host_name` is empty when the script loads on a first setup and is assigned inside `cmd_setup`, so a key fixed at load time stored every fresh token under `share-tunnel:` (found by validation round 2 against the first implementation).
