# Changelog

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

