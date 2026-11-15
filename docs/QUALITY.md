# Quality requirements

One entry per measurable quality the system promises. Specs cite these IDs and never restate them.

# QUALITY additions for SPEC-009 (multi-member tenants)

The worktree has no `docs/QUALITY.md` (checked 2026-11-13), so these are the first entries; numbering starts at 1 in each area. TASK-4c creates `docs/QUALITY.md` with them. Edge-case and negative-control ids refer to `docs/specs/SPEC-009-multi-member.md`.

## Security

- ID: `Q-SEC-1`
  - Quality: security (integrity of member data)
  - Scenario: any publisher token writes a tombstone, deletes a pointer, or both, for a link served by another machine; that machine's reconcile runs
  - Measure: 0 bytes deleted under `pub/` on the owning machine across every forged-write fixture
  - Check: tests `mm RC-08`, `mm RC-10`, `mm FG-01`, `mm FG-02`; negative control NC-1

- ID: `Q-SEC-2`
  - Quality: security (serving integrity, routing integrity)
  - Scenario: a publisher writes a v:3 pointer for an unlisted, revoked or foreign id, or rewrites a `u/` record's status
  - Measure: 0 answers of 200 for an unlisted or revoked row; 0 changes to the deployed binding set or `PAUSED` caused by a bucket write
  - Check: tests `mm SV-01`, `mm FG-03` to `mm FG-07`; negative controls NC-2, NC-9

- ID: `Q-SEC-3`
  - Quality: security (one-time invites)
  - Scenario: an invite code is redeemed a second time, after its expiry, or twice at the same moment
  - Measure: sealed bytes returned at most once per invite (100% of runs); expired redeem answers 410; second redeem answers 404
  - Check: `tests/worker.mjs` rows `v5 SV-14` to `v5 SV-18`, `CC-11`; negative control NC-5

- ID: `Q-SEC-4`
  - Quality: security (credential confinement)
  - Scenario: a visitor holding an Access session (cookie `CF_Authorization`, header `cf-access-jwt-assertion`) opens a member link
  - Measure: 0 occurrences of `cf-access-jwt-assertion`, `cf-access-authenticated-user-email` or `CF_Authorization` in requests reaching a member machine
  - Check: `v5 SV-21`; live leg ML-7 reads the member's Caddy access log; negative control NC-4

- ID: `Q-SEC-5`
  - Quality: security (revocation completeness)
  - Scenario: the admin runs `member rm <name>` and it exits 0
  - Measure: 0 tunnels, VPC Services, `M_<8hex>` bindings, tokens, `i/` objects or v:3 pointers of that member remain
  - Check: `mm MB-13` (dry listings); live leg ML-11 (API listings by name); negative control NC-10

- ID: `Q-SEC-6`
  - Quality: security (secret handling)
  - Scenario: any member verb, join, or redeem runs, including failure paths
  - Measure: 0 occurrences of a token value, invite code or derived key in argv (a logging `curl`/`openssl` shim), `r2-calls.log`, stdout, stderr, or any file outside the Keychain
  - Check: TASK-1f argv and log grep; the "r2 backend: live transport, retries, secrets" section extended to the minter, connector token and code

- ID: `Q-SEC-7`
  - Quality: security (admin and minter token handling)
  - Scenario: any admin or minter path runs, or any non-admin path runs while `admin_token_cmd` or `minter_token_cmd` is set
  - Measure: 0 occurrences of either token in argv, a file, or output; `admin_token_cmd` runs only on admin paths and `minter_token_cmd` only on minter paths (member add, invite, rotate, renew, rm, adopt)
  - Check: `tests/share.sh` rows AT-02, AT-03, AT-05, AT-06, AT-09 to AT-12; the G13 grep

## Reliability

- ID: `Q-REL-1`
  - Quality: reliability (convergence)
  - Scenario: a multi-step admin verb or `join` is killed after any one step, then rerun
  - Measure: rerun reaches the happy-path end state with 0 orphan objects, for 100% of die points
  - Check: every `mm DP-*` test (kill via `SHARE_R2_DRY_PAUSE` plus `kill -9`, or fail via `SHARE_R2_DRY_FAIL`)

- ID: `Q-REL-2`
  - Quality: reliability (concurrency)
  - Scenario: two admin verbs start at once from two shells or two machines
  - Measure: 0 lost bindings and 0 lost pause entries; record status equals the deploy afterwards
  - Check: `mm CC-01`, `mm CC-02`; negative control NC-7

- ID: `Q-REL-3`
  - Quality: reliability (deploy safety)
  - Scenario: a deploy runs on any path (`setup --r2` rerun, `--alias`, version bump, member verb)
  - Measure: 100% of deployed `vpc_service` bindings and the `PAUSED` list present after the deploy, except the one the verb changes
  - Check: `mm DY-01` to `mm DY-04`; negative control NC-6

- ID: `Q-REL-4`
  - Quality: reliability (record integrity)
  - Scenario: any verb or join writes a member record's status
  - Measure: 100% of status writes move along a row of the spec's transition table; 0 other moves
  - Check: `member_can` iteration test (the expectation is parsed from the spec's table); `mm MB-24`, `mm MB-25`

- ID: `Q-REL-5`
  - Quality: reliability (journaled verbs)
  - Scenario: a journaled verb (setup, teardown, migrate, add) is killed at any step, then rerun
  - Measure: the rerun converges, and `$root/ops/` is empty afterwards, for 100% of die points
  - Check: the G2b and G2c die-point loops

- ID: `Q-REL-6`
  - Quality: reliability (config integrity)
  - Scenario: any config writer runs on a config holding keys it does not own
  - Measure: 0 dropped or reordered lines outside the writer's owned keys
  - Check: `tests/share.sh` rows CF-01 to CF-04

## Availability and latency

- ID: `Q-AVAIL-1`
  - Quality: latency
  - Scenario: a visitor fetches a member link and an origin link 20 times each from one vantage
  - Measure: added time of the member link at most 400 ms at p50 and 800 ms at p95 (spike O1 measured 151 to 354 ms)
  - Check: live leg ML-6

- ID: `Q-AVAIL-2`
  - Quality: availability (change visibility)
  - Scenario: `member pause`, `resume`, `rm` or `add` exits 0
  - Measure: the routing change answers at verb exit (the verb waited for `X-Share-Deploy` with its nonce 3 times in a row), and within 60 s from a second vantage
  - Check: `mm DY-05`; live leg ML-8

- ID: `Q-AVAIL-3`
  - Quality: availability (isolation of failures)
  - Scenario: a member machine sleeps, or its cloudflared or Caddy stops
  - Measure: 0 change in status or body of origin and cloud links; member links answer the generic 503 offline page on the first request
  - Check: `mm OT-01`, `v5 SV-22`; live leg ML-9

## Compatibility

- ID: `Q-COMPAT-1`
  - Quality: compatibility (installs without members)
  - Scenario: a tenant with R2 off, or on without members, upgrades to the release with Worker v5
  - Measure: `index.tsv`, config and `state` byte-identical; the Caddyfile differs only by per-row handles and the 404 catch-all; unlisted `pub/<id>` answers 404
  - Check: SPEC-008 compat row 1 (updated for the Caddyfile only); `mm SV-01` to `mm SV-05`

- ID: `Q-COMPAT-2`
  - Quality: compatibility (older CLIs and Workers)
  - Scenario: a v0.9 CLI or a v4 Worker meets v:3 pointers, tombstones or member records
  - Measure: 0 deletions and 0 wrong-content answers for member links (v4 answers 404; v0.9 hides and never reaps)
  - Check: `mm OC-01` to `mm OC-06`

- ID: `Q-COMPAT-3`
  - Quality: compatibility (the shipped Share Bar)
  - Scenario: the released v0.9.0 Share Bar reads every profile the new CLI reports
  - Measure: `bash mac/compat-check.sh v0.9.0` exits 0; `state` stays schema 1 with no new `state.state` value
  - Check: `mac/compat-check.sh` (TASK-4b1); `mm OC-06`, `mm OC-08`

- ID: `Q-COMPAT-4`
  - Quality: compatibility (`share state` contract)
  - Scenario: a profile of any role is read by `share state` after the groundwork change
  - Measure: schema stays 1; keys are only added; every existing key keeps its value
  - Check: `tests/share.sh` rows CP-01 to CP-03; `state_schema_ok`

## Cost

- ID: `Q-COST-1`
  - Quality: cost (R2 operations)
  - Scenario: a visitor request for a v:1, v:2 or v:3 link
  - Measure: `BUCKET.get` calls per request: v:1 2, v:2 1, v:3 1 (no new read for v:1 or v:2)
  - Check: `v5 SV-24`

## Scale

- ID: `Q-SCALE-1`
  - Quality: scalability
  - Scenario: a tenant has 20 machine members
  - Measure: one deploy carries 20 `vpc_service` bindings and each routes; the CLI refuses the 21st until the measured limit allows more
  - Check: TASK-1a(e) live probe (25 bindings); `mm DY-04`; `mm MB-05`

## Operations

- ID: `Q-OPS-1`
  - Quality: operability (revocation latency)
  - Scenario: the admin revokes a member link with `rm <id>`
  - Measure: the Worker answers 404 on the first request after the verb exits; the owner's Caddy handle is gone within one hourly loop (at most 3,660 s) while the member's machine is up and its Keychain unlocked
  - Check: `mm LK-11` (loop forced with `share prune --loop`); live leg ML-10

## Agent experience

- ID: `Q-AX-1`
  - Quality: agent experience (refusals an agent can act on)
  - Scenario: a guard refuses a verb
  - Measure: 100% of refusals carry a stable snake_case code and, where one exists, a next command an agent can run; `SHARE_ERROR_JSON=1` adds the JSON line
  - Check: the G1 and G5 acceptance rows; the suite check that every code has a `code_table` line and a skill table row
