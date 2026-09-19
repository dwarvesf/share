# Changelog

## [Unreleased]

### Features

- generate CHANGELOG.md from tag history on release
- quick tunnels via 'share setup --quick' (TryCloudflare) (#14)
- release pipeline (#13)

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

