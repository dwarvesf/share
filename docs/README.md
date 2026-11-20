# Docs index

Start with [team/HANDOVER.md](team/HANDOVER.md). The root [README.md](../README.md) is the product page and the user guide. A coding agent needs only [AGENTS.md](../AGENTS.md) at the repo root; it reads the pages here on demand. This page lists every doc and what it holds.

Docs are grouped by who reads them. Decisions, specs, proofs and notes are records: nobody reads them front to back, so follow a link when a task needs one.

## Layout

| Folder | Who reads it | What is in it |
|---|---|---|
| [team/](team/) | Teammates and agents | How we work: handover, onboarding, build and test guides, releases, owners |
| [product/](product/) | Anyone who builds or sells the product | What the product is: who it is for, what stays free, what could be paid |
| [brand/](brand/) | Anyone who draws the mark | The mark as SVG and PNG, and its contact sheet |
| [design/](design/) | Anyone who changes Handout Bar | The menu bar app design pages and the multi-member UML sheets |
| [decisions/](decisions/), [specs/](specs/), [implementation-notes/](implementation-notes/), [verification/](verification/), [retro/](retro/), [research/](research/), [briefs/](briefs/) | Anyone tracing a change | Dated records. They keep the name `share`, the product name when they were written. the agent kit's tools look for these exact folders |
| [how-it-works.md](how-it-works.md), [setup.md](setup.md), [SYSTEM-DESIGN.md](SYSTEM-DESIGN.md), [QUALITY.md](QUALITY.md) | Everyone | The model, the admin guide, the UML design and the measurable qualities, at the top because tests and specs cite them |

A new doc goes in `team/` if it tells people how to work, and in `product/` if it says what the product is or does. The rule is in [AGENTS.md](../AGENTS.md), section "Docs layout".

## Team: start here

| Doc | What it covers |
|---|---|
| [team/HANDOVER.md](team/HANDOVER.md) | Entry page for a new teammate: status today, why, reading order by role, who can do what, risks |
| [team/onboarding.md](team/onboarding.md) | New engineer start: prerequisites, a first hour of passing commands, architecture map, which tests for which change, your own stack, what to learn and the tooling to install |

## Team: how we work

| Doc | What it covers |
|---|---|
| [../CONTRIBUTING.md](../CONTRIBUTING.md) | Branches, commits, test tiers before a PR, and the code guidelines: bash, state, secrets, tests, Swift, comments |
| [../AGENTS.md](../AGENTS.md) | The repo section "This repo: team rules for agents": commands, work queue, what a PR carries, proof, one-way doors, merge, docs layout |
| [team/OWNERS.md](team/OWNERS.md) | Who owns each script, workflow and job: the rule, and one table row per file |

## Team: build, test and ship

| Doc | What it covers |
|---|---|
| [team/development.md](team/development.md) | How the parts fit, run from source, the names kept from the share era, build scripts, test, CI, project layout |
| [team/testing.md](team/testing.md) | Test tiers, the suite and its isolation, the CI shards, the Worker tests, Handout Bar tests, the live legs |
| [team/release.md](team/release.md) | The versioned release flow, `bin/release`, the cask, what works with what |

## Product

| Doc | What it covers |
|---|---|
| [product/DIRECTION.md](product/DIRECTION.md) | Positioning, the free core, candidate paid layers, now, next and not now, and the open decisions for the owner |
| [setup.md](setup.md) | The admin guide: API token setup (no browser), the login service, profiles, private links, the R2 backend and teammate onboarding, a tenant's R2 and alias fold, members, moving machines, teardown, troubleshooting |
| [how-it-works.md](how-it-works.md) | Architecture, config keys, the lifecycle of a share, the security model, the R2 data model and Worker, members, the state JSON, testing, releasing |
| [SYSTEM-DESIGN.md](SYSTEM-DESIGN.md) | The system design of a multi-member tenant: use cases, components, store, flows, lifecycles, risks. Its UML set is [design/multi-member-uml.html](design/multi-member-uml.html) |
| [QUALITY.md](QUALITY.md) | One entry per measurable quality the system promises; specs cite the IDs |
| [../CONTEXT.md](../CONTEXT.md) | The glossary: terms the code, specs and tests use with one meaning |

## Design

| Doc | What it covers |
|---|---|
| [design/](design/) | The menu bar app: an interactions page (states, copy and actions) and the approved design page, an HTML file to open in a browser. Files keep their old names, because scripts in `mac/` read them |
| [design/multi-member-uml.html](design/multi-member-uml.html) | The UML drawing set of the multi-member tenant (open in a browser) |
| [brand/share-mark.svg](brand/share-mark.svg) | The mark: an open ring with one dot leaving through the opening |

## Decisions and specs

| Doc | What it covers |
|---|---|
| [decisions/](decisions/) | One ADR per decision, `ADR-NNNN-<slug>.md`; the ones that shape everything are listed in [team/HANDOVER.md](team/HANDOVER.md) |
| [specs/SPEC-001-live-shares.md](specs/SPEC-001-live-shares.md) | Live shares, own hostnames, the folder index |
| [specs/SPEC-002-quick-tunnel.md](specs/SPEC-002-quick-tunnel.md) | Quick tunnel mode: no domain needed |
| [specs/SPEC-003-menu-bar.md](specs/SPEC-003-menu-bar.md) | The menu bar app |
| [specs/SPEC-004-access.md](specs/SPEC-004-access.md) | The per-link login gate (`--access`) |
| [specs/SPEC-005-profiles.md](specs/SPEC-005-profiles.md) | Profiles: two setups on one machine |
| [specs/SPEC-006-menu-bar-profiles.md](specs/SPEC-006-menu-bar-profiles.md) | The menu bar app across profiles, with login-gated adds |
| [specs/SPEC-007-r2-backend.md](specs/SPEC-007-r2-backend.md) | The R2 storage backend per profile |
| [specs/SPEC-008-one-host-per-tenant.md](specs/SPEC-008-one-host-per-tenant.md) | One hostname per tenant, cloud storage optional per link |
| [specs/SPEC-009-multi-member.md](specs/SPEC-009-multi-member.md) | Multi-member tenants |
| [specs/SPEC-010-state-groundwork.md](specs/SPEC-010-state-groundwork.md) | Explicit state for the CLI's implicit machines |
| [specs/SPEC-011-media-folder-index.md](specs/SPEC-011-media-folder-index.md) | A media-aware generated folder page |

## Dated evidence (never rewrite)

| Doc | What it covers |
|---|---|
| [verification/](verification/) | One proof file per change: a green run with `Command:`, `Exit:` and a `Verdict:`, and a negative control. [verification/README.md](verification/README.md) is the marker that turns the proof gate on |
| [implementation-notes/](implementation-notes/) | Where a build departed from its spec, one file per spec or feature |
| [retro/](retro/) | Retrospectives |
| [research/](research/) | Research snapshots that fed the specs |
| [briefs/](briefs/) | Decision briefs and context sheets that came before the specs |

## Elsewhere in the repo

| File | What it covers |
|---|---|
| [../CHANGELOG.md](../CHANGELOG.md) | Release notes per version, generated by `bin/changelog` |
| [../demo/README.md](../demo/README.md) | How the README GIFs are recorded |
| [../.github/pull_request_template.md](../.github/pull_request_template.md) | The PR body sections: What, Demo, Proof, Bookkeeping |
| [../.github/ISSUE_TEMPLATE/task.yml](../.github/ISSUE_TEMPLATE/task.yml) | The Task issue form: Goal, Done when, Scope, Notes |
| [../.github/ISSUE_TEMPLATE/bug.yml](../.github/ISSUE_TEMPLATE/bug.yml) | The Bug issue form |
| [../.github/workflows/ci.yml](../.github/workflows/ci.yml) | CI: lint, the suite in shards, the Swift job |
| [../WORKFLOW.md](../WORKFLOW.md) | A pointer to the agent kit's lanes and gates |
