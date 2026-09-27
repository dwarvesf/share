# ADR-0005: a profile is a name that prefixes every per-install value

Status: accepted
Date: 2026-09-27

## Context

share keeps its state in fixed places: `~/share`, `~/.config/share`, the launchd
label `foundation.d.share`, port 8787, and the Keychain item `share-tunnel:<host>`.
Every one of those already reads an environment override (`SHARE_ROOT`,
`SHARE_CONFIG_DIR`, `SHARE_SERVICE_LABEL`, `SHARE_PORT`), which the test suite uses to
run a throwaway instance. A second install on one machine needs all of them to move
together, and the first install must not move at all.

## Decision

A profile is a validated slug, `--profile <name>` before the verb or `SHARE_PROFILE`,
that supplies the default for each of those values:

- config dir `~/.config/share/profiles/<name>`, root `~/share/profiles/<name>`
- service label `foundation.d.share.<name>`
- Keychain service `share-tunnel.<name>:<host>`
- a port pair picked once at setup and stored in the profile's config

No profile means today's values, unchanged. The explicit environment overrides keep
their precedence over the profile, so the suite and the service plist keep working.

Alternatives rejected:

- A `profile=` key inside one config file: the config dir is one of the values that
  has to move, and setup would have to learn to merge two profiles into one file.
- Separate `SHARE_*` exports per shell: what the operator can already do today;
  the service plist and the hourly prune loop do not inherit a shell.
- `default` as a real directory: it would move the existing install.
- Sibling directories (`~/share.<name>`, `~/.config/share.<name>`): same cost, and they
  decouple a profile from a wholesale removal of `~/share`. Nesting won because one
  directory lists, backs up, and restores every profile, and the operator's rule never
  deletes `~/share` wholesale; a profile that must live elsewhere uses `SHARE_ROOT`.

## Consequences

- Profiles are independent: nothing is shared, so `share ls` shows one profile and
  `share profiles` lists them by reading each one's `state`.
- The only cross-profile logic is two read-only scans of the derived locations: the
  other profiles' config files (the port pick, the `add <port>` refusal of another
  profile's port pair, the `setup` refusal of a hostname or a tunnel name another
  profile holds) and every
  profile's index (the port pick skips a port any profile live-shares). A profile moved
  with `SHARE_ROOT` or `SHARE_CONFIG_DIR` is invisible to both; the serve port guard
  still catches a collision that results.
- Every message that names a command builds it from the current profile, so a hint
  for a named profile never points at the default install; a suite check greps for a
  bare `share <verb>` hint so the rule cannot drift.
- A profile set up before the default creates `~/share` and `~/share/profiles` with
  mode 700, so the default's root keeps the mode it has always had.
- `serve` refuses a port that already answers, for every profile including the
  default: caddy binds with SO_REUSEPORT, so two servers on one port would split
  requests silently.
- The launchd plist and systemd unit of a named profile carry `SHARE_PROFILE`; the
  default's stay byte-identical.
- Share Bar keeps watching the default profile only.
