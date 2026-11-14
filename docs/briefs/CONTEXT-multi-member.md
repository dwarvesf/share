# Context for implementation: multi-member tenants

Distilled from `docs/briefs/DECISION-BRIEF-multi-member.md` (r2), `docs/research/2026-11-13-current-state-machines.md`, `docs/research/2026-11-13-multi-member-review-1.md`, `docs/research/2026-11-13-multi-member-outside.md`, `docs/research/2026-11-13-multi-member-spikes.md`. Spec: `docs/specs/SPEC-009-multi-member.md`; decision: `docs/decisions/ADR-0009-members.md`.

## Stack

- CLI: one bash script, `bin/share` (4,833 lines at 4564c5c, v0.9.0 line). Must parse under macOS `/bin/bash` 3.2: no empty arrays under `set -u`, no heredoc inside `$( )`. Runtime deps: caddy, cloudflared (2025.7.0 or later for Workers VPC, QUIC, outbound UDP 7844), jq, curl, openssl, optional pandoc.
- Worker: JavaScript module embedded in `bin/share` as the `SHARE_WORKER_JS` heredoc (L2566 to L2783, `export default` at L2765), deployed by one multipart PUT (`r2_deploy`, L3770). Versioned by `WORKER_VERSION` (4 today, L2559) and `WORKER_SHA` (L2560); a source change needs a version bump, and the suite checks both. This work moves it to 5.
- Storage: R2 through the S3 API with `curl --aws-sigv4`, credentials via `-K <(...)` (never argv). Conditional writes `If-None-Match: *` and `If-Match` are the only cross-machine concurrency control (current-state 5.3).
- Serving: Caddy on `127.0.0.1:<port>` behind a named tunnel; launchd (`foundation.d.share[.p]`) or systemd user units.
- Crypto for invites: `openssl enc -aes-256-cbc -pbkdf2 -iter 200000 -md sha256` and `openssl dgst -sha256 -hmac`; works on macOS LibreSSL 3.3.6 and Homebrew OpenSSL 4.1.0 (sampled). Pass secrets with `-pass fd:N`, never `pass:`.
- App: Swift package `mac/` (Share Bar), reads `share profiles --json` / `share state`.
- Tests: `tests/share.sh` (bash, about 3,900 lines; isolated `SHARE_ROOT`, `SHARE_CONFIG_DIR`, `SHARE_TUNNEL=0`, a `check "<label>" <expected> <actual>` helper; runs `node tests/worker.mjs` at L3876); `tests/worker.mjs` (drives the emitted Worker with an in-memory `Bucket` and a stubbed `fetch`; `--dir` integration mode over a dry bucket); live legs `tests/e2e-*.sh` by hand; `swift test --package-path mac`.
- CI: `.github/workflows/ci.yml`, public repo: shellcheck, then `bash tests/share.sh` on `ubuntu-latest` and `macos-latest`, then the Swift job.

## Conventions

- Errors: `die() { echo "share: $*" >&2; exit 1; }`; a refusal names the next command. Every refusal runs before the first write; a multi-step verb skips each step already in place, so a rerun converges (`cmd_setup_r2` steps 0 to 14 are the model).
- Subcommands are `cmd_<verb>`; helpers snake_case; dispatch is the `case` at the bottom (L4799).
- A cloud or bucket record never enters `rows()`, the index, the Caddyfile, a stage path, or shell arithmetic; every field is validated in jq first (`r2_take`, L3262).
- Anything another writer may still be finishing is deleted only after a 10-minute age test on `LastModified` (`r2_reconcile`, L2967).
- Test seams, never a new transport: `SHARE_R2_DRY=1` plus `SHARE_R2_DRY_DIR` (a directory bucket, `r2_dry` L3553), `r2_api_dry` (account API state under `.cf/`, L3633), `r2-calls.log` (one `METHOD key` or `API METHOD path` line per call), `SHARE_R2_DRY_FAIL` (`"PUT <key>"` or `"API <METHOD> <glob>"`), `SHARE_R2_DRY_FAIL_TIMES`, `SHARE_R2_DRY_PAUSE` (holds a call until `.resume`, for kill and race tests), `SHARE_ACCESS_DRY`, `SHARE_HOST_DRY`, `SHARE_TEST_IDS`; seams refuse outside `SHARE_TUNNEL=0` and a `.test` hostname. Suite helpers: `tn` (origin HOME, L2861), `tm` (member HOME, L2956), `trow`, `aged` (L2322), `mdel`; stub `security`, `launchctl`, `systemctl` on PATH with `STUBSEC_LOG`.
- New test labels: `mm <edge id>: ...` in `tests/share.sh`, `v5 <edge id>: ...` in `tests/worker.mjs`.
- A behavioral change gets `docs/verification/<slug>.md`: green run, negative controls with red runs, a table from spec rows to test names.
- Commits: Conventional Commits; no co-author or "Generated with" trailers (CLAUDE.md). The full lane records its gates in the kit gate ledger.
- Process traps that bit once each (CLAUDE.md): an EXIT trap cannot read `local` vars after return; a background loop must redirect its output; `pkill -P` a subshell before `kill`.

## Key files

| File | Why it matters |
|---|---|
| `bin/share` L56 to L88 | config, roots, derived flags; the R7 detector goes after L79 |
| `bin/share` L90 to L135 | `rows_in`: the only index reader; accepts the new `revoked` token |
| `bin/share` L152 to L186 | `rand_id`, `r2_id_taken`: add the `t/<id>` check |
| `bin/share` L476 to L584 | `cmd_add`: storage choice, pointer PUT before `pub/<id>`, row, Caddy |
| `bin/share` L636 to L744 | `refresh`, `rm`, `prune`, `hits` dispatch on `r2on` |
| `bin/share` L1087 to L1165 | `write_caddyfile`: the whole-tree `handle` becomes one handle per listed row |
| `bin/share` L1177 to L1243 | `cmd_serve`: hourly prune loop with `SHARE_API_TOKEN_OFF=1` |
| `bin/share` L1905 to L1949 | `api_token_resolve`, token store (Keychain `share-api[.p]:<host>`) |
| `bin/share` L2521 to L2542 | `r2_publisher_check`: refuses admin-capable tokens |
| `bin/share` L2559 to L2783 | Worker constants and source (`pass()` at L2646, record branches at L2699 to L2715) |
| `bin/share` L2948 to L3009 | `r2_pointer_put`, `r2_reconcile`, `r2_pointer_drop` |
| `bin/share` L3262 to L3314 | `r2_take`, `r2_record_raw`, orphan sweep and its block |
| `bin/share` L3346 to L3378 | `cmd_rm_r2`: member refusals; admin revoke lands here |
| `bin/share` L3553 to L3700 | `r2_dry`, `r2_api`, `r2_api_retry`, `r2_api_dry`: extend for tunnels, services, tokens |
| `bin/share` L3706 to L3759 | `r2_healthz`, `r2_wait_healthz`: add the deploy nonce |
| `bin/share` L3761 to L3790 | `r2_deploy_meta`, `r2_deploy`: `keep_bindings` holds only `secret_text`; carry-forward goes here |
| `bin/share` L3867, L3977 to L4224 | `tenant_config`, `cmd_setup_r2` on the origin, `--no-r2` |
| `bin/share` L4557 to L4725 | teardown (tunnel and r2) |
| `bin/share` L4799 to L4833 | verb dispatch |
| `tests/share.sh` L1 to L115 | isolation, stubs, `check` |
| `tests/share.sh` L2856 to L3120 | tenant sections: `tn`, `tm`, reconcile row 6 (model for the reconcile rows) |
| `tests/worker.mjs` | Worker unit rows and integration mode |
| `tests/e2e-tenant.sh` | live-leg model: `share-e2e-*` prefix guard, minted 2 h tokens, cleanup by name in the EXIT trap |
| `docs/SYSTEM-DESIGN.md` | rev B UML with the diagram ids the spec cites |
| `docs/specs/SPEC-008-one-host-per-tenant.md` | coverage matrix and negative-control format to imitate |
| `bin/release` | must stamp the new `SHARE_VERSION` |

## External dependencies

- Workers VPC (beta; free on every plan during the beta; 1,000 VPC Services per account). REST: `POST|GET|PUT|DELETE /accounts/<a>/connectivity/directory/services[/<id>]`, body `{type:"http", name, host:{ipv4:"127.0.0.1", network:{tunnel_id}}, http_port}` (omit `https_port`). Worker binding in deploy metadata: `{type:"vpc_service", name:"M_<8hex>", service_id}`. Fetch: the URL host fills `Host` only; the service's port is always used; use `http://`. Spike O1 proved the path live with wrangler; the REST create and binding entry are documented, sampled in TASK-1a.
- Cloudflare Tunnel API: `POST /accounts/<a>/cfd_tunnel`, `PUT .../configurations` (at least one ingress rule: keep only the `http_status:404` catch-all), `GET .../token`, `GET .../connections` (array of connectors, each with `conns[]`; one cloudflared registers about 4 connections), `DELETE .../connections`, `DELETE .../cfd_tunnel/<t>`. No API rotates a tunnel token.
- API tokens: user tokens `GET|POST /user/tokens`, `PUT /user/tokens/<id>` (moves `expires_on`, secret unchanged; spike O2), `DELETE /user/tokens/<id>`, `GET /user/tokens/permission_groups`, `GET /user/tokens/verify`. Secret only in the create response. List has no name filter (5 to 50 per page): filter client-side. R2 one-bucket resource `com.cloudflare.edge.r2.bucket.<acct>_default_<bucket>` with group "Workers R2 Storage Bucket Item Write". Account-owned `/accounts/<a>/tokens` answers 403 today.
- R2 S3 credentials from a token: key id = token id, secret = sha256(token value); endpoint `https://<acct>.r2.cloudflarestorage.com`.
- R2 Worker binding: `get`, `delete`, `put` with `onlyIf.etagMatches` for the redeem claim (documented; sampled in TASK-1a(h)).
- Credentials (1Password, never stored by share): admin token in `CLOUDFLARE_API_TOKEN` (Workers Scripts Edit, Workers R2 Storage Edit, Zone Read, DNS Read, Cloudflare Tunnel Edit, Connectivity Directory Admin, Access Apps Edit for gated links); minter token in `SHARE_MINTER_TOKEN` (API Tokens Read and Write only, a separate item; spike O2 used `cf-tokens-admin`). Member tokens live in the member's Keychain only.
- Live test account: Console Labs (Workers Free). Spike leftovers to clean or reuse: tunnel, VPC Service and Worker `share-spike-vpc`; user token `share-spike-mint` (expires 2026-11-15). Live acceptance tenant: `s.console.so`; first member: a second machine of the owner's.
