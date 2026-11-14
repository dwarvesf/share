# Glossary

Terms the code, specs and tests use with one meaning. A spec that adds a term adds its line here.

- `role`: the one kind a profile is, from `profile_role`: `none`, `quick`, `origin`, `tenant_origin`, `r2_profile`, `migrated`, `member`.
- `tier`: an origin's tenant level: `t0` no bucket, `t1` bucket, `t2` bucket and members on.
- `code`: a stable snake_case name for a refusal or a serve exit reason, listed in `code_table` and by `share state-fn codes`; versioned by `codes_v`, never by `schema`.
- `step journal`: one JSON file per running multi-step verb under `$root/ops/<verb>.<pid>.json`, naming the verb, the step it reached and its rerun.
- `op`: one journal entry as `state.ops` shows it: `{verb, step, of, name, alive, rerun, rerun_argv}`, plus `rollback` and `rollback_argv` when the verb has one.
- `serve exit record`: `$root/.serve-exit`, `{"code", "at"}`: why the last serve of this profile ended.
- `owned keys`: the config keys one writer may rewrite or drop; `config_put` keeps every other line byte for byte.
- `admin token`, `minter token`: the Cloudflare tokens for admin verbs and for minting member tokens; each comes from its environment variable, else from a command in the profile config (`admin_token_cmd`, `minter_token_cmd`), never stored.
- `serve phase`: the reasoned serving state in `state.serve`: `not_setup`, `elsewhere`, `failed`, `stopped`, `starting`, `tunnel_down`, `worker_down`, `serving`; `serve.reason` is the serve exit code for `failed`, else the phase name (`ok` when serving).
- `link_state`: a row's served state in `state.shares[]`: `live`, `expired`, `shadowed`, `gate_missing`, `revoked`; `reason` carries the detail.
- `.health`: `$config_dir/.health`, the cache of the last token check, Worker probe and listing (`token`, `worker`, `gates`, `shadow`, `min_cli`); `state` reads it and never refreshes it.
