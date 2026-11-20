# Changelog

## [v0.10.0] - 2026-11-21

### Features

- rename share to Handout and add the team docs (#80)
- **share:** media-aware generated folder index (#79)
- **share:** member adopt, min_cli enforcement and live member shares (#77)
- **sharebar:** members tab, all links window and app states (#76)
- **share:** member pause, resume, invite, rotate and renew (#75)
- **mac:** popover drop-in, drag out, Quick Look and a global hotkey (#69)
- **mac:** share bar settings window (#68)
- **mac:** share bar popover (#65)
- **share:** member rm, purge, leave, admin revoke and member reconcile (#62)
- **mac:** share bar foundations, compat check and screenshot harness (#61)
- **share:** members core: tenant tier, lease, registry, add, join, ls (#57)
- **mac:** open-ring mark as menu bar glyph and app icon (#53)
- **share:** serve phase, link state, add journal and .health cache (#56)
- **share:** serve listed rows only and ship Worker v5 (#55)
- **share:** state groundwork: codes, step journal, roles, config writer (#54)

### Fixes

- stop reaps the bucket pass; dry PUT writes atomically (#84)
- **share:** close the spec gaps the state-machine audit trace found (#74)
- **mac:** match the popover to the revision 8 design (#66)
- **share:** stop member add hanging where SIGPIPE is ignored (#60)
- **share:** clear the held Access id after a finished alias fold (#47)

### Performance

- **ci:** run main's suite as parallel shards on both OSes (#82)

### Documentation

- re-check member docs against the built verbs and grep them (#78)
- member onboarding, rev C design, glossary and quality entries (#63)
- **members:** record the live Cloudflare samples on Console Labs (#52)
- validated member specs and the mega-goal scaffold (#51)
- multi-member design, specs and Share Bar redesign (#50)
- **share:** record the early Worker delete and token revoke (#49)
- **share:** record the direct personal move and tick its task (#48)
- **share:** record the Dwarves go-live in Batch 9 and tick TASK-11a (#46)

### Tests

- **mac:** queue the second verb only after the first starts (#83)
- **share:** add a section filter and a timing table to the suite (#64)
- **share:** a cloudflared stand-in for join on Linux CI (#58)

### Maintenance

- copyright to Superbits LLC (Console Labs) (#86)
- Console Labs branding, tap move and a re-recorded demo (#85)
- give the macOS full suite 45 minutes (#81)
- shard the bash suite on pull requests (#67)
- skip the suite a change cannot affect, and time out hung jobs (#59)

## [v0.9.0] - 2026-10-06

### Features

- spec for one hostname per tenant with optional cloud storage (#45)

### Fixes

- **test:** isolate token-free tests from the host keychain (#44)

### Documentation

- changelog for v0.9.0

## [v0.8.0] - 2026-10-01

### Features

- R2 storage backend for multi-publisher tenants (#43)

### Fixes

- main CI after the r2 merge (compat row, SC2015) (#42)

### Documentation

- changelog for v0.8.0
- spec for an R2 storage backend per profile (#41)

## [v0.7.1] - 2026-09-30

### Documentation

- changelog for v0.7.1
- spec for Share Bar across profiles with login-gated adds (#40)

## [v0.7.0] - 2026-09-29

### Features

- per-link Cloudflare Access login gate (#38)
- --profile runs a second share setup beside the default (#35)
- **release:** find the notary key item by title suffix (#33)

### Fixes

- **test:** keep the deliberate cat in two count checks lint-clean (#39)
- **test:** keep the suite off the real launchctl and systemctl (#37)
- **test:** probe the file mode with GNU stat first (#36)

### Documentation

- changelog for v0.7.0
- retro for the Share Bar cycle (#32)

### Tests

- suite ports derive from one overridable base (#34)

## [v0.6.0] - 2026-09-28

### Features

- **mac:** About Share Bar in the menu (#31)
- Share Bar, a menu bar app for share (#29)

### Documentation

- changelog for v0.6.0

## [v0.5.2] - 2026-09-27

### Fixes

- a stale serve.pid with a reused pid no longer blocks serve (#28)

### Documentation

- changelog for v0.5.2

## [v0.5.1] - 2026-09-27

### Fixes

- match Spacedown's figure and syntax conventions in md renders (#27)

### Documentation

- changelog for v0.5.1

## [v0.5.0] - 2026-09-27

### Features

- render markdown in Spacedown's paper reading theme (#26)

### Fixes

- **release:** pin fetch.prune=false for origin/main sync check (#24)

### Documentation

- changelog for v0.5.0
- document the /healthz route in README, setup, how-it-works (#25)

## [v0.4.0] - 2026-09-24

### Features

- **serve:** add /healthz route to share serve (#23)

### Fixes

- release.yml needs a checkout for gh release create (#20)

### Documentation

- changelog for v0.4.0
- restore the Cloudflare badge in README (#22)
- commits carry no co-author or generated-with trailers (#21)

### Tests

- verification record for release workflow fix (#19)

## [v0.3.0] - 2026-09-19

### Features

- CHANGELOG.md generated from tag history (#16)
- quick tunnels via 'share setup --quick' (TryCloudflare) (#14)
- release pipeline (#13)

### Documentation

- changelog for v0.3.0
- escape pipes inside README table cells (#18)
- slim README to features, how it works, install (#17)

### Tests

- assert no leaked processes at the end of the suite (#15)

## [v0.2.0] - 2026-09-19

### Features

- live shares, own hostnames, folder index (#11)
- markdown renders get a reading stylesheet and KaTeX (#9)

### Documentation

- bash 3.2 parser traps that bit the suite twice (#12)

## [v0.1.6] - 2026-09-19

### Documentation

- fix the claims a docs-versus-code check flagged (#8)

### Tests

- real-zone e2e test; live check needs three 200s in a row (#10)

## [v0.1.5] - 2026-09-19

### Fixes

- start returns once the link answers through the public hostname (#7)

## [v0.1.4] - 2026-09-19

### Fixes

- a restarted server is ready only when its own tunnel is (#6)

## [v0.1.3] - 2026-09-18

### Fixes

- reinstalling the login service no longer fails with launchd error 5 (#5)

### Documentation

- re-record use.gif on v0.1.2; keep demo/ out of release archives (#4)

## [v0.1.2] - 2026-09-18

### Documentation

- real demo recordings; hits output uses singular forms (#3)

## [v0.1.1] - 2026-09-18

### Features

- hits, rm, and refresh accept a pasted link (#2)

## [v0.1.0] - 2026-09-18

### Features

- share CLI with browser-login setup, login service, and docs

### Maintenance

- initialize repository

