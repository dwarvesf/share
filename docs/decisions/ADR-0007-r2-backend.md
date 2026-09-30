# ADR-0007: a profile can serve from R2 through a Worker, with one record per share as the publish

Status: accepted
Date: 2026-09-30

## Context

Every link of a tunnel profile lives on one machine. When that machine sleeps, reboots, or loses its uplink, every link answers Cloudflare 530, and only someone with a shell on it can publish. A team profile needs links that Cloudflare serves by itself and uploads from several people, while the per-share Access gate (ADR-0006) keeps its guarantees and existing installs change by zero bytes. The design and its test plan are in `docs/specs/SPEC-007-r2-backend.md`; the measurements behind the choices below are in `docs/implementation-notes/r2-backend.md`.

Measured on the Dwarves account before the build: a bucket-scoped API token gets 403 on every call of the R2 REST object path, which also ignores `If-None-Match` and `If-Match`; the S3 endpoint accepts the same token (access key = the token id, secret = sha256 of the token) and honors both headers. A token that lists buckets reaches `payout`, `invoice`, and the KYC evidence bucket. A new Worker gets a public `workers.dev` route by default. `request.url` in a Worker keeps `%2F`, `%5C`, and `//` raw, while `new URL()` resolves `\` and `%2e%2e`.

## Decision

- A profile has one backend, fixed at setup: `share setup <host> --backend r2 --bucket <name>`. Switching goes through `teardown`, as ADR-0002 fixes the tunnel mode. The r2 config carries `port=r2`, a sentinel an older share dies on at load, so it can never write `pub/` or create an Access app against an r2 profile.
- Storage: a private bucket (no r2.dev, no custom domain) holding a `share.json` marker, one record `m/<id>` per share, and the bytes under `o/<id>.<nonce>/`. The record names its prefix, so the record PUT with `If-None-Match: *` is the publish, and an upload no record names is never served. A refresh uploads a new prefix and swaps the record with `If-Match`. Uploads no record names are deleted by a bare `prune` after 24 h.
- Transport: every object call goes through the S3 API with `curl --aws-sigv4`, the credential passed as `-K <(printf ...)`. The REST object path is out: it needs an account-wide token and has no conditional writes.
- Serving: a Worker `share-<host-with-dashes>`, source embedded in `bin/share` and deployed by `setup` with one multipart PUT, versioned by `WORKER_VERSION` plus `WORKER_SHA`. It answers only its exact Host, only GET and HEAD, 400 on encoded separators, 404 on anything a sound, unexpired record does not name, and `no-store` plus `noindex` on every answer. A gated record is served only with an Access JWT signed by the team's key for that record's `aud`, so a path the edge matched differently or a deleted app never serves the bytes. Setup turns `workers.dev` and previews off and reads the setting back before it attaches the custom domain.
- Expiry is checked by the Worker per request; records and bytes are deleted by the next `ls` or `prune` from any publisher. No Worker cron, because deleting an Access app needs a token the Worker must not hold.
- Tokens: the admin token (Workers Scripts Edit, Workers R2 Storage Edit, Zone Read, DNS Read; Access Organizations Read for gated links) is read from `CLOUDFLARE_API_TOKEN` only and never stored. Each publisher stores one bucket-scoped token (Workers R2 Storage Bucket Item Write on the share bucket, Zone Read) with an expiry; `share api-token` refuses a token that reads the Worker settings or lists another bucket. Gated publishing adds the account-wide Access scopes, so only named people hold them.
- Multi-publisher rules: any publisher can list and remove any share; `refresh` works only from the install that added the share, reading the source path from its local `r2-own` file, never from a record.
- `teardown` is local by default. `teardown --yes --purge` with the admin token checks the Worker bindings, the marker, and the custom domain first, then removes every share, the gated shares' apps, the marker, the domain, the Worker, and the bucket when it is empty.
- Live dev-server links, `--host`, quick mode, and the login service stay tunnel-only; an r2 profile and a tunnel profile run side by side.

Alternatives rejected:

- One index object written with `If-Match`: every add and rm contends on one key, and a retry re-uploads the whole index.
- D1 for the index: a database read per request and no per-database token scope to match a bucket-scoped token.
- wrangler or rclone as the uploader: a node or rclone dependency on every teammate's machine; wrangler also has no list verb.
- A `worker/` directory with a `wrangler.toml`: `install.sh` over curl ships `bin/share` alone.
- Lifecycle rules or a Worker cron for expiry: a link would outlive its second, or the Worker would hold an Access token.
- Moving `s.d.foundation` to r2: its live links and gated share would die at teardown; the Dwarves r2 profile gets a new hostname instead.

## Consequences

- Links answer while every publisher's machine is off, and a teammate publishes from a laptop with a token that reaches one bucket.
- The publish is one conditional PUT, so a crash mid-upload leaves nothing served, only an orphan prefix the next `prune` removes.
- A Worker change ships only with a version bump; the suite fails when the source sha and the constants drift, and a deploy refuses a downgrade without `--force`. The admin reruns `setup` after a release that bumps the Worker.
- A publisher token can read every object in the bucket, gated shares included: Access gates visitors, not publishers. Every publisher's HTML runs on one origin, accepted for v1 because only named teammates publish; per-share subdomains are the upgrade if an untrusted publisher is ever added.
- `hits` counts come from Analytics Engine, keyed by a salted hash of the visitor IP; the dataset cannot be deleted by API and ages out after `--purge`.
- Cleanup of an unused profile waits for some publisher's `ls` or `prune`, or an admin purge; until then expired shares are unreachable but still stored.
