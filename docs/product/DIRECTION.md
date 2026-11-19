# Direction

What Handout is for, what stays free, what could be paid, and what the owner still has to decide. This page is a working draft for the owner. Nothing here is a commitment. No price is set.

## What Handout is for

Handout hands out resources: a file, a folder, a guide, a deck, a build, a running dev server. Each goes to people at a link on your own domain, with an expiry, a visitor count, an optional login, and a page for a folder. The link stays the same, so you can print it, email it or put it in a doc.

Who uses it:

| Who | Hands out | Why Handout and not the usual tool |
|---|---|---|
| A freelancer or an agency | Reports, decks, builds, prototypes to clients | The link carries the agency's own domain, expires on a date, and shows who opened it |
| A small team | A guide folder, a release build, design exports | One hostname for the whole team, each person publishing from their own machine |
| A developer | A dev server, to a reviewer, for an hour | A stable hostname, not a random URL that changes at every start |
| A coding agent | Whatever it just built | `handout skill --install` teaches the agent to publish and report the link |

## Positioning

Handout does not replace any of these. It covers the case between them.

| Tool | What it does well | Where Handout differs |
|---|---|---|
| ngrok | Puts a local dev server on a public URL | The hostname is yours and stays the same. It also hands out files and folders as snapshots that outlive the source, with expiry and visitor counts |
| Dropbox or Drive links | Share a file with people you already work with | The link lives on your domain, expires on a date you set, and a folder becomes a web page, not a download list |
| WeTransfer | Send a large file once | No size-capped transfer service in the middle: your machine or your own bucket holds the bytes, the link is stable, and you refresh it in place |
| Vercel or Netlify previews | Preview a build that comes from a git push | No git project, no deploy pipeline: one command from a laptop, for a PDF as easily as a site |

The wedge is three things together: your domain, local-first (nothing leaves your machine until you say so), and your own Cloudflare account, so there is no Handout server holding anyone's files. Check each vendor's current plan before quoting this table outside the team.

## The free core

The CLI is open source (MIT) and self-hosted on your own Cloudflare account. It is the product people try. The proposal is that it stays whole, pending the owner's call on the free tier (Open decisions):

- Proposed: everything that works today stays free: stable links, snapshots, live dev servers, own hostname per share, the folder page, markdown rendering, expiry, visitor counts, quick tunnels, profiles, the agent skill, and private links through your own Cloudflare Access.
- No Handout account, no login to us, no telemetry. The CLI talks to Cloudflare and to your machine.
- Proposed: a feature that exists now is not taken away to make a paid tier look better. A paid layer adds something that costs us to run or to support.

## Candidate paid layers

Each row starts from something that exists or is specced, so a layer is a product we can already describe. Prices are undecided.

| Layer | Grounded in | What a paid version adds | Open |
|---|---|---|---|
| Links that stay up | The R2 backend: a private bucket and a Worker serve snapshots while every machine is off (ADR-0007, `docs/setup.md` 4f) | We run the bucket, the Worker and the domain wiring, so a user does not need a Cloudflare account to get links that stay up | Hosted or self-hosted; price: undecided |
| Team on one hostname | Tenants and members: one hostname, one shared list, members' links served from their own machines (ADR-0008, ADR-0009) | Seats, invites and member lifecycle managed for a team, with one bill | Per seat or per hostname; price: undecided |
| Private links at scale | Per-link Cloudflare Access login by email, domain or group (ADR-0006) | Rule groups and access lists managed in Handout, an audit of who opened what | Needs Zero Trust on the user's account today; price: undecided |
| Visitor analytics | `handout hits` counts requests and unique IPs; the Worker already writes one Analytics Engine point per answer under 400 (`docs/how-it-works.md`) | A view over time per link and per folder, exports, a weekly digest | Retention and privacy terms; price: undecided |
| Handout Bar | The menu bar app: state, share list, drop to publish, a members tab (ADR-0003, ADR-0009) | A team edition with the members tab and the all-links window, or the whole app as the paid entry point | Free or paid app; price: undecided |

Proposed, not charged for: the ability to publish at all, the link format, and leaving. A user can always `teardown` and keep their files and their Cloudflare resources.

## Now, next, not now

Proposed by this page. The owner confirms.

### Now

- Finish the rebrand: the CLI, the Homebrew formula and cask, the docs, and the `share` alias for existing installs.
- Cut the first release since v0.9.0. The members verbs, the state groundwork and the media folder page are on `main` and in no release.
- Answer the open decisions below that block a public launch: licence, the domain and trademark check for the name, and how an existing `share` Homebrew install moves to `handout`.

### Next

- Decide hosted or self-hosted for links that stay up, because every paid layer above depends on it.
- A first-run path that gets a stranger to a live link in under ten minutes, with the quick tunnel as the no-domain route.
- A visitor view beyond `handout hits`, if analytics is a paid layer.

### Not now

Written down so nobody builds it by accident. Move an item up with a demo.

- Billing code, accounts, or any server that holds user files, until hosted versus self-hosted is decided.
- A Windows or Linux menu bar app. The CLI already runs on macOS and Linux.
- A rewrite of the CLI in another language. `docs/how-it-works.md` names the trigger: a need for Windows, or a distribution without a git checkout.
- Telemetry in the CLI.

## Open decisions for the owner

| Decision | Options on the table | Why it matters | State |
|---|---|---|---|
| Licence | Keep MIT for everything; MIT core with a separate paid repo; a source-available licence for the paid layers | MIT lets anyone resell the whole thing. The paid layers need a licence that fits how they are sold | Undecided |
| Pricing model | Per seat, per hostname, per volume of links or visitors, flat per team | Each shapes who buys and what we must meter | Undecided; no number is set |
| Hosted or self-hosted | We run the Workers and buckets; users run their own; both | Hosted brings billing, support, abuse handling and data terms. Self-hosted keeps the "no server of ours" promise | Undecided |
| Names of the tiers | A free tier and a team tier, with names | The README and the site need words | Undecided |
| What the free tier includes | The whole CLI today, or a cap on links, hostnames or members | A cap is a change from what users have now | Undecided |
| The name | Handout as the product; the domain; a trademark search | The name is on the package, the tap and the app | Undecided: check before a public launch |
| Selling entity | Which company sells, and which bank account | Needed before any payment | Undecided |
| Moving existing installs | A tap migration or an alias formula for `share` | Today's users must not be stranded | Undecided |
| Cloudflare terms | Whether a managed offer fits Cloudflare's terms for resellers | A hosted layer sits on their products | Undecided: read their terms |
