# ADR-0006: a login gate is one Cloudflare Access app per share, observed before the bytes go public

Status: accepted
Date: 2026-09-28

## Context

Every share link is public to anyone who holds it. Some files must reach a named set of
people (an ops report for Dwarves OPS staff, not for contractors, who also hold
`@d.foundation` addresses). The other links on the same hostname must stay public, and
removing a share must remove its gate. Cloudflare Access can gate a path on a hostname
that share already routes, but the edge matches paths after normalizing case, doubled
slashes, and dot segments, and it does not decode `%2F` or `%5C`; Caddy does. A new
Access app can take minutes to enforce (foundation-ops INC-009 measured 6.5 minutes on a
new hostname).

## Decision

- One self-hosted Access app per gated share, named `share <id> <host> <nonce>`, with one
  app-scoped allow policy and the destinations `<host>/<id>`, `<host>/<id>/*` (and the
  `--host` fqdn when there is one). It is created at `add` and deleted by its stored id at
  `rm`, at expiry with a token, and at `teardown`.
- Three rule forms on one flag: `group:<name>` references an existing Access rule group
  (share never creates, edits, or lists members), `email:<a>[,<b>...]` is an inline list,
  `domain:<d>` admits a whole domain and says so.
- Observe, then publish: the copy is staged outside `pub/`, and the bytes move in only
  after `https://<host>/<id>/`, `/<id>`, and the fqdn all redirect to Access with
  `kid == aud` of the new app, three rounds in a row. A visitor during the wait gets Access
  or a 404, never the bytes. On removal the order flips: bytes gone, row gone, then the app.
- Every app is tracked from intent to deletion in `<root>/access-pending`: an intent line
  with a nonce goes in before the POST, so a lost response is still findable by the app's
  fixed name, and a line outlives any failed delete until a later sweep finishes it. A
  sweep claims a line under the index lock before any network call, skips a live owner
  (pid plus start time), trashes orphaned bytes before it deletes an app, and never holds
  the lock across a network call.
- Caddy answers 400 on the main hostname to a raw path carrying `%2F`, `%5C`, or `%2E`, the
  one measured way past a path-scoped app. `--host` sites are host-wide gates and keep
  their paths.
- In named mode the main Caddy site is bound to its hostname (plus loopback for local
  probes) and a catch-all site answers 404, so a `--host` name routed before its own block
  exists, during a gate wait of up to fifteen minutes, never reaches the `pub` tree.
- Every delete reads the app first and requires the name `share <id> <host> ...`; a forged
  row or pending line plus an account-wide token can never delete a foreign app.
- The API token comes from one resolver per profile: `api_token_cmd` in the config, the
  Keychain item `share-api[.<profile>]:<host>` (a mode-600 file on Linux), then
  `CLOUDFLARE_API_TOKEN`. `share serve` exports `SHARE_API_TOKEN_OFF=1`, so the login
  service and its hourly prune never touch Access; an expired gated share leaves its app
  in `access-pending` for the next interactive `share prune`.

Alternatives rejected:

- Email-domain rules only: contractors pass.
- share creating and maintaining groups: an identity admin tool, out of scope.
- A gate in Caddy (basic auth, JWT check): no per-person identity, or a plugin share does
  not ship.
- Validating the Access JWT in cloudflared per ingress rule: fail-closed at the connector,
  but one ingress edit per share under the host lock; deferred as the upgrade path if
  another edge bypass appears.
- An own hostname per gated share: no path matching, but a DNS record, the `--host`
  credential, and the new-hostname delay on every gated add.

## Consequences

- Nothing is ever public while share believes it is gated: the gate is proven before the
  bytes exist, the app is removed only after they are gone, and every app share creates is
  either deleted or named in `access-pending`.
- First use is guided: `share api-token` opens the prefilled token form and reads a hidden
  paste, `--cmd` points at any existing Access-capable token, and the preflight names each
  scope by its dashboard name with a fix line. Groups are optional; `email:` and `domain:`
  work with nothing but the account's one-time-PIN provider.
- A gated `add` waits for the edge (seconds to minutes) and prints the link only then.
- Every login uses a Zero Trust seat; the per-account app cap and seat cap are the tenant
  admin's to watch.
- `ls`, `status`, and `state` surface apps waiting for deletion and a gated row whose app
  is gone, so an orphan or a hand-deleted app is visible to a human.
