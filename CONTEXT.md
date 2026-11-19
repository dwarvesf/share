# Glossary

Terms the code, specs and tests use with one meaning. A spec that adds a term adds its line here.

- `role`: the one kind a profile is, from `profile_role`: `none`, `quick`, `origin`, `tenant_origin`, `r2_profile`, `migrated`, `member`.
- `tier`: an origin's tenant level: `t0` no bucket, `t1` bucket, `t2` bucket and members on.
- `code`: a stable snake_case name for a refusal or a serve exit reason, listed in `code_table` and by `handout state-fn codes`; versioned by `codes_v`, never by `schema`.
- `step journal`: one JSON file per running multi-step verb under `$root/ops/<verb>.<pid>.json`, naming the verb, the step it reached and its rerun.
- `op`: one journal entry as `state.ops` shows it: `{verb, step, of, name, alive, rerun, rerun_argv}`, plus `rollback` and `rollback_argv` when the verb has one.
- `serve exit record`: `$root/.serve-exit`, `{"code", "at"}`: why the last serve of this profile ended.
- `owned keys`: the config keys one writer may rewrite or drop; `config_put` keeps every other line byte for byte.
- `admin token`, `minter token`: the Cloudflare tokens for admin verbs and for minting member tokens; each comes from its environment variable, else from a command in the profile config (`admin_token_cmd`, `minter_token_cmd`), never stored.
- `serve phase`: the reasoned serving state in `state.serve`: `not_setup`, `elsewhere`, `failed`, `stopped`, `starting`, `tunnel_down`, `worker_down`, `serving`; `serve.reason` is the serve exit code for `failed`, else the phase name (`ok` when serving).
- `link_state`: a row's served state in `state.shares[]`: `live`, `expired`, `shadowed`, `gate_missing`, `revoked`; `reason` carries the detail.
- `.health`: `$config_dir/.health`, the cache of the last token check, Worker probe and listing (`token`, `worker`, `gates`, `shadow`, `min_cli`); `state` reads it and never refreshes it.
- `member`: a person registered in the tenant's bucket registry with a `u/` record; either a machine member or a cloud member.
- `machine member`: a member whose links stay on their own machine; served by their own Caddy and cloudflared, reached by the tenant Worker through one Workers VPC Service binding.
- `cloud member`: a member who publishes cloud links only (the R5 publisher, now registered).
- `member_id`: `m-<name>-<8 hex>`; the stable identity of a member across rotate, pause and resume; never reissued.
- `origin` (of a pointer): the field of a v:3 pointer naming the member_id whose machine serves it. A v:2 pointer's origin is the tenant origin.
- `pointer v:3`: `m/<id>` record `{v:3, storage:"machine", origin, ...}`; routes through the binding `M_<8hex>`.
- `tombstone`: `t/<id>`, written when someone other than the owner removes a machine link; tells the owner to stop serving it; never deletes bytes.
- `sealed invite`: `i/<sha256("share-invite-id:" + code)>`, an envelope holding the member's tokens encrypted under a key derived from the invite code; redeemed once through the Worker.
- `invite code`: 20 base32 characters (100 bits) shown once to the admin; the invite line is `handout join <host> <code>`.
- `admin lease`: `lock/admin`, the bucket object every admin verb holds while it changes Cloudflare state.
- `minter token`: a Cloudflare user token with API Tokens Read and Write only, read from `SHARE_MINTER_TOKEN`, else from the output of the config key `minter_token_cmd`; mints, extends and deletes member publisher tokens.
- `T0`, `T1`, `T2`: tenant states; tunnel only, R2 on, members on.
- `R7`: the member profile role, detected by config `role=member`.
- `carry-forward`: every Worker deploy reads the deployed settings and re-sends every `vpc_service` binding, `MEMBERS` and `PAUSED`, then applies only the running verb's change.
- `deploy nonce`: the `DEPLOY` plain-text binding, new on every deploy, echoed by `/healthz` as `X-Share-Deploy`.
