# Implementation notes: per-link Access gate

Delta from `docs/specs/SPEC-004-access.md`. Decisions already in the spec are referenced, never restated.

## TASK-1 spike, measured on the Dwarves LLC account (2026-09-28, read-only unless stated)

| Question | Answer |
|---|---|
| empty-body `POST access/apps {}` | HTTP 400, `errors[0].code` 12130, `access.api.error.invalid_request: app type is missing or invalid`; the app count stayed at 4. The preflight accepts exactly `400` + `12130` as the Apps Edit proof. |
| `GET /user/tokens/verify` with the Toolkit token | `success:true`, `status:active`; `GET /user/tokens/<id>` answers 9109 (no API Tokens Read), so scopes cannot be listed, only exercised. |
| `GET /zones?name=d.foundation&status=active` | exactly one zone, account Dwarves LLC (the 4-account token sees no duplicate). |
| `GET access/groups?name=dwarves-ops` | one group, 8 include entries, 1 page. |
| Access org, IdPs | org 200; IdPs `[onetimepin]` only. |
| inline `policies` on app create, the `kid == aud` delay on an already-routed host | recorded below once the e2e gated leg runs. |

## Decisions made without the operator

- The build landed on a successor branch (`feat/access-gate`, the three spec commits cherry-picked onto main after SPEC-005) rather than a force-push of `docs/share-access-spec`; PR #30 is closed as superseded by the successor PR.
- `share api-token` refuses quick mode with the same line `add --access` prints: `need_host` passes in quick mode with an empty hostname, and the spec's "never `share-api:` with an empty host" needs the refusal.
- The name of the account-token form for the default profile is `share access (default)`; the spec fixes the form only for a named profile.
- The dry seam sits inside `cf_try` (`cf_dry`): every Access call, the group paging, the read-back, and the lost-POST lookup run the real code paths against fixture answers, instead of separate dry branches per function. Preflight outcomes are environment knobs (`SHARE_ACCESS_DRY_ZONES`, `_ORGS`, `_APPS`) rather than fixture files.
- `access_ls_check` (the PUBLIC warning) and the pending-count note run from `cmd_ls`, so `status` gets both through its `cmd_ls` call.
- `cmd_prune` takes a mode: `serve` (no token from any source), `listing` (`ls`, `status`: the exported environment token only), bare (`share prune`: the full resolver). The spec names the outcome; the mode is how the one function serves the three callers.

## Deviations

- None from the behavior contract so far; the test rows are the check.

## Landmines found while building

- `case` patterns: `*/access/apps?*` also matches `/access/apps/<uuid>` because `?` is a glob wildcard; the id pattern comes first and the list pattern escapes the `?`.
- `rows()` validates `access=` and `access_rule=` in awk with `index`/`substr`/`length` only: mawk has no `{n}` intervals and no `\b`.
