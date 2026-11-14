# Implementation notes: multi-member (SPEC-009)

The delta from `docs/specs/SPEC-009-multi-member.md` that the builder needs. TASK-1a writes its live answers here too.

## Spec validation round 1: warnings for the builder

The criticals were folded into the spec (DEC-58 to DEC-73). These warnings were not; each is something the build's own tests should catch, or a choice the builder makes.

### Die points and retries
- Add DP rows the spec does not list: resume (TASK-3a); renew; invite at the VPC Service PUT, the record hash, the old `i/` delete and the `invited` write; rotate at the token re-mint, the new invite and the `rotation+1` write; rm with `--cloud-links delete` part done and at the `i/` delete; admin revoke between the `t/` write and the `m/` delete; `sync --rebind` at its deploy.
- `rotation` increments only when rotate starts from `active` or `paused`, never on a rerun from `rotating`. "Old" means every tunnel or service of this member whose name is not `-r<rotation>`.
- `r2_api_retry` retries POST on any 5xx. Never auto-retry a create (tunnel, service, token): a committed create that answered 500 leaves a second object. A rerun finds it by name. Add a dry seam that commits and then answers 500.
- Join: step 3 finding a status that is not `invited` with no 412 (for example `removing`) removes local config and tokens, as a 412 does. Step 6 hitting a 412 because the admin ran `member invite` from `joining` dies `member_changed`. A new `join <code>` retires a stale `ops/join.*`.

### Worker
- `decide()` cannot be pure for `V3_DOWN`, `V3_SERVED` and the `REDEEM_*` rows: split it into `decide` before I/O (an intent row) and a pure `settle(intent, outcome)`, so SV-26 asserts both.
- Row 15 needs a fetch timeout (an `AbortSignal`); pick the value from TASK-1a(d)'s measurement and record it here.
- The claimed `i/` body keeps `expires`, so `member sync` can sweep a claim left without its delete.

### CLI
- After TASK-0b, `add` ignores a `caddy_reload` failure (`|| true`), so a new link would answer 404 with no message. Warn when the reload fails.
- The 20-member cap: count non-`removed` machine records plus bound `M_*` bindings, whichever is larger. TASK-1a(e) should deploy at 20 and at 25 and route one request through each binding, not deploy only.
- `--no-members` leaves REMOVED `u/` records, `u/purged.json`, `t/` and `i/` objects. Either sweep them in `--no-members` after its refusals pass, or say in the docs that they stay.
- `sync --rebind` finds services only. A tunnel or token whose record is gone is found only by the e2e listings; consider a `member ls` drift code for account objects named `share-<host-dashes>-*` with no record.
- `sync --rebind` and a `removing` record forged back to `active` mid-rm: rebind prints the list and needs `--yes`.

### Security hygiene
- Minter least privilege: MB-04 refuses a minter missing scope but not one with extra scope. Read the minter's own policies and refuse anything beyond API Tokens Read and Write.
- `share join <host> -` reading the code from stdin would keep the code out of shell history; the Share Bar would then pass it on stdin. Optional for v1 (invariant 7 now names the code as an exception).

### Sustainability
- `member ls` reads recorded `expires_on`, not live validity. Add drift codes `token_expiring` and `token_missing` from the current minter's `GET /user/tokens`, and feed them to the Share Bar's Needs a look.
- The minter token needs an owner and a runbook line in `docs/setup.md` (TASK-4c): which user mints, its own expiry, what to do when that user leaves (DEC-73's `--token-unreachable`, then `rotate`).
- A Workers VPC regression looks like a sleeping member (both answer the generic 503). `member ls` could flag a bound service whose connectors are above 0 while a probe of a known link answers 503.
- The beta is free today (ADR-0009). Record the post-beta cost line and the "cloud members only" fallback as a procedure in the docs.
- The hourly member loop with a locked Keychain only logs a line. Surface `loop_stalled` in `status` when the last good reconcile is over 24 h old.

### Share Bar
- `shadowed` and `gate_missing` have no row in the UI `link_state` table: treat both as `live` for click, drag and menu, with their state word in the meta line.
- The All links window's bulk Remove appends one entry to `pending` (DEC-70), with every id in one `rm` argv.

### Other
- TASK-4b23 attributes the Stop Waiting copy to SPEC-010 G9; SPEC-010 says G11 owns it. Use G11's string.
- Phase 0's "a sample that disagrees lands as a Worker v6 fix in Phase 1" also covers a CLI fix in carry-forward (TASK-0e), which needs no Worker bump.
