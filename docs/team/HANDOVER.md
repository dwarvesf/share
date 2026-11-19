# Handover

The one entry page for a new teammate. It orders the docs, gives a status snapshot, and lists the gaps. It does not copy the source docs: follow the links.

## What this is

- One product with three parts. The CLI (`bin/handout`) hands out a file, a folder or a dev server at a link on your own domain. The Worker, which the CLI deploys, serves links from a private R2 bucket when your machine is off. Handout Bar is a macOS menu bar app that sits on top of the CLI.
- It was called `share` until recently. The command, the package and the docs are Handout now; `share` stays a working alias. A list of names did not change on purpose, because live installs depend on them: [development.md](development.md#names-kept-from-the-share-era).
- The CLI is open source (MIT) and runs on the user's own Cloudflare account. Paid layers are being considered, none is built: [../product/DIRECTION.md](../product/DIRECTION.md).

## Status today

| Piece | Where | State | Evidence |
|---|---|---|---|
| Tunnel backend: add, serve, expiry, hits, own hostname, live dev servers, profiles, quick tunnel | `bin/handout` | built, released | SPEC-001, SPEC-002, SPEC-005; ADR-0001, ADR-0002, ADR-0005; `CHANGELOG.md` |
| Private links (`--access`) | `bin/handout` | built, released | SPEC-004; ADR-0006 |
| R2 backend: links that stay up with the machine off | `bin/handout`, the Worker it emits | built, released in v0.8.0 | SPEC-007; ADR-0007; PR 43 |
| One hostname per tenant: R2 on at the origin, the alias fold, `migrate` | `bin/handout` | built, released in v0.9.0 | SPEC-008; ADR-0008 |
| Members: add, ls, sync, rm, purge, pause, resume, invite, rotate, renew, adopt, join, leave | `bin/handout` | built on `main`, not in a release | SPEC-009; ADR-0009; PRs 57, 62, 75, 77 |
| State groundwork: codes, step journal, roles, serve phase, `.health` | `bin/handout` | built on `main`, not in a release | SPEC-010; PRs 54, 55, 56 |
| Media-aware folder page | `bin/handout` | built on `main`, not in a release | SPEC-011; PR 79 |
| Handout Bar | `mac/` | built; the members tab, popover, settings window and all-links window are on `main` | SPEC-003, SPEC-006; ADR-0003, ADR-0010; PRs 61, 65, 68, 76 |
| Release and distribution | `bin/release`, `mac/release.sh` | built; newest tag v0.9.0; formula and cask in `dwarvesf/homebrew-tools` | [release.md](release.md) |
| The Handout rebrand | docs, CLI, formula, cask | in progress | this docs pass; the code branch; the tap |
| Paid layers, hosted option, accounts | none | not started | [../product/DIRECTION.md](../product/DIRECTION.md) |

`main` is 30 commits ahead of v0.9.0. The first release after this page ships the members work and the folder page.

## Why: direction and use cases

These are plans, not commitments. Detail and the open decisions: [../product/DIRECTION.md](../product/DIRECTION.md).

- Who it serves: people who send things to other people and want the link on their own domain. Freelancers and agencies, small teams, developers who show a dev server, and coding agents that publish what they build.
- Core use case: `handout add ./team-guide` prints one link. It expires, counts visitors, can be private, and a folder gets a page.
- The hard promise: no Handout server holds anyone's files. The user's machine or the user's own Cloudflare account does.
- A tenant is one hostname with one shared list. Teammates publish from their own machines under it.

## Reading order by role

| Role | Read in this order |
|---|---|
| Engineer | [onboarding.md](onboarding.md) (with what to learn and the tooling), [../../CONTRIBUTING.md](../../CONTRIBUTING.md) (code guidelines), [development.md](development.md), [testing.md](testing.md), [../how-it-works.md](../how-it-works.md), [../SYSTEM-DESIGN.md](../SYSTEM-DESIGN.md), [../../CONTEXT.md](../../CONTEXT.md), then the spec for your area ([../README.md](../README.md) lists them) |
| Product person | this page, [../product/DIRECTION.md](../product/DIRECTION.md), the root [README.md](../../README.md), [../setup.md](../setup.md) |
| Operator or tenant admin | [../setup.md](../setup.md) (tokens, R2, tenants, members, troubleshooting), [../how-it-works.md](../how-it-works.md) (security model) |

## How it is built

```
 Path 1: tunnel profile (the default)

 visitor --> Cloudflare edge --> tunnel --> cloudflared --> caddy --> ~/share/pub
                                            (login service)   bin/handout

 Path 2: r2 profile, and cloud links of a tenant

 visitor --> Cloudflare edge --> Worker --> private R2 bucket
                                  |
                                  +--> a member's machine, through a Workers VPC binding

 Handout Bar --reads--> handout profiles --json  (it only calls the CLI)
```

The CLI is one bash file that carries the Worker's JavaScript and deploys it. There is no server of ours in the path. The model, the config keys and the security rules are in [../how-it-works.md](../how-it-works.md).

### Decisions that shape everything

| ADR | Decision |
|---|---|
| [0001](../decisions/ADR-0001-own-hostname-per-share.md) | A live or SPA share gets a named first-level hostname, never a random subdomain |
| [0002](../decisions/ADR-0002-quick-tunnel-mode.md) | The quick tunnel is a setup-time mode, not a per-share flag |
| [0003](../decisions/ADR-0003-menu-bar-reads-through-cli.md) | The menu bar app reads state only through the CLI |
| [0005](../decisions/ADR-0005-profile-is-a-path-prefix.md) | A profile is a name that prefixes every per-install value |
| [0006](../decisions/ADR-0006-access-gate-per-share.md) | A login gate is one Cloudflare Access app per share, observed before the bytes go public |
| [0007](../decisions/ADR-0007-r2-backend.md) | A profile can serve from R2 through a Worker, with one record per share as the publish |
| [0008](../decisions/ADR-0008-one-host-per-tenant.md) | A tenant is one hostname; storage is local by default and cloud per link |
| [0009](../decisions/ADR-0009-members.md) | Members serve from their own machines behind the tenant hostname, through Workers VPC |
| [0010](../decisions/ADR-0010-share-mark-drawn-in-code.md) | The mark is an open ring, drawn in code |

The ADR records keep the name `share`: they are dated, and `share` was the name when they were written. There is no ADR-0004.

## Where work lives

GitHub Issues are the work queue. The Task form gives the shape: Goal, Done when, Scope. Assigning yourself is the claim. Rules: [`AGENTS.md`](../../AGENTS.md), section "This repo: team rules for agents". Larger work starts as a spec in `docs/specs/` and a decision in `docs/decisions/`.

## Who can do what

The rules and who says yes to a one-way door: [`AGENTS.md`](../../AGENTS.md#one-way-doors). These facts are not rules.

| Action | Who today | Why |
|---|---|---|
| Cut a release | A maintainer | [release.md](release.md): push to `main`, rights on the tap, a Mac with the signing identity |
| Deploy a Worker | Each tenant's admin, in their own Cloudflare account | There is no central Worker; `handout setup` deploys it |
| Run the live legs | Anyone with a zone and a token of their own | [testing.md](testing.md) |
| Secrets | A new engineer needs none from a maintainer: the suite needs no account, and the live legs use your own zone and token | [onboarding.md](onboarding.md), section Running your own stack |

## Risks and open calls

| Item | Why it matters | Where recorded |
|---|---|---|
| Names kept from the share era | A renamed Keychain item, service label or Worker route strands a live install | [development.md](development.md#names-kept-from-the-share-era); one-way doors in `AGENTS.md` |
| Existing `share` Homebrew installs | A user who runs `brew upgrade` must land on `handout`: a tap migration or an alias formula | [release.md](release.md), section Open |
| Licence and pricing undecided | MIT lets anyone resell the whole tool; no paid layer can ship before the choice | [../product/DIRECTION.md](../product/DIRECTION.md), Open decisions |
| Unreleased work on `main` | Members and the folder page are 30 commits past v0.9.0 | `CHANGELOG.md`; [release.md](release.md) |
| Tunnel links die when the machine sleeps | Visitors get Cloudflare 530; the r2 backend is the answer | [../../README.md](../../README.md); [../how-it-works.md](../how-it-works.md) |
| Members need Workers VPC | A beta Cloudflare product; members stay off until `--members` | [../setup.md](../setup.md) section 4i; ADR-0009 |
| The bucket token cannot tell members apart | Members are named teammates only, never strangers | [../SYSTEM-DESIGN.md](../SYSTEM-DESIGN.md), risks |
| One large bash file under a bash 3.2 floor | Easy to break on macOS, hard to review; the how-it-works page names when a rewrite earns its cost | [../how-it-works.md](../how-it-works.md); [`CLAUDE.md`](../../CLAUDE.md) |
| The live legs run by hand | CI has no Cloudflare zone or token, so setup, teardown and the Worker's live behavior are proved only before a release | [testing.md](testing.md) |
| The cask needs a signing Mac | `bin/release` exits 3 with `CASK NOT RELEASED` on any other machine | [release.md](release.md) |
| The docs are tested | The suite fails when a documented flag or `state` key goes missing, so a rename touches docs and tests together | [testing.md](testing.md) |

## Working agreement

- The rules live in one place: the repo section of [`AGENTS.md`](../../AGENTS.md).
- What the team builds now, next and not now: [../product/DIRECTION.md](../product/DIRECTION.md).
- Who owns each script, workflow and job: [OWNERS.md](OWNERS.md).
- Branches, commits, tests and code guidelines: [`CONTRIBUTING.md`](../../CONTRIBUTING.md).

## First week

- Install the tools (Prerequisites in [onboarding.md](onboarding.md)), then run the first hour there. Note every prerequisite you lacked and fix the page.
- Read [`CLAUDE.md`](../../CLAUDE.md): the bash 3.2 traps and the process-lifecycle traps that already bit once each.
- Read the Lifecycle of a share and the Tenants sections of [../how-it-works.md](../how-it-works.md), then `CONTEXT.md`.
- Pick one or two small issues that touch the built path, and open one PR per issue with `Closes #<n>`, a demo and a proof file.
- Do the "brief an agent" and "verify agent output" exercises (What to learn in [onboarding.md](onboarding.md)) on your first issues. Then pick one more skill each week.
