# One hostname per tenant: implementation notes

The delta from SPEC-008 for the builder. Spike answers (TASK-1a, TASK-1b, TASK-7a's tar step) land here too.

## Validation warnings carried to the build

Round 1 warnings the spec did not fold. Each one is a build rule unless a task's spike answer overrides it.

| Warning | Build rule | Task |
|---|---|---|
| Every request to an R2-on tenant runs the Worker plus one bucket read; dev-server HMR multiplies both | measure live-link request volume in L3; if it matters, memo "machine or miss" per id in the Cache API for a few seconds; add a Worker-requests or Class B threshold to the vps-mon catalog | TASK-3, TASK-9a |
| The route fails closed at the Workers request limit, taking machine links down | TASK-1b(k) reads the plan; on a free plan set the route to fail open (Caddy 404s cloud ids, edge Access still gates) | TASK-1b, TASK-4 |
| A publisher token reaching its `expires_on` silently blocks local adds on an R2-on origin | `api-token --check` warns 14 days ahead; vps-mon expiry coverage for the origin token | TASK-2, TASK-11a |
| `setup --r2` holds no index lock while pointers backfill | take the index lock from step 6 through step 11, so a concurrent local add waits and then writes its pointer | TASK-4 |
| A dry trace exists for one negative control only | write the dry trace for each control into the verification record as it goes red | TASK-10 |
| A tar truncated at a member boundary can publish a partial tree | `migrate` sends a per-id file count and sha256 manifest; `import` verifies it before publishing; the rerun skip compares the manifest | TASK-7a, TASK-7b |
| A member could take a machine link's URL by deleting its pointer and writing a cloud record (accepted trust, SPEC-007 DEC-011) | `state` reports `shadowed` ids so Share Bar can show them | TASK-6 |
| The migrate switch token can be broad if TASK-1b(i) picks the Toolkit token | prefer a run-scoped one-day token for the switch | TASK-11b |
| The Worker's `//` and low-escape 400s now cover live dev-server paths too | document it in how-it-works; scope them to cloud ids only if a real dev server needs `//` | TASK-3, TASK-10 |
| `brew pin` is no downgrade | the D1 and P1 rollback is an install of the previous tag from the tap's git history | TASK-11a, TASK-11b |
| After P2 nothing watches `s.han.ws` | add `s.han.ws/healthz` to vps-mon in TASK-11b | TASK-11b |
| After P2, a local restore on the Air (rows from `index.migrated`, trees from `migrated/`) has no command | rehearse the manual restore once in R2 and write it into the verification record | TASK-9b |
| `--alias` adds permanent surface for a one-time fold | keep the alias code small and covered; it retires with the alias rollback and `--no-r2` | TASK-5 |

Round 2 warnings, same rule:

| Warning | Build rule | Task |
|---|---|---|
| A D3 rollback breaks cloud links added after the fold | the alias rollback list prints the cloud ids added since the fold, so Han re-adds or warns first | TASK-5 |
| Teammates still joined at `f.d.foundation` are not told | D4 lists the bucket's `by` values and tells each to rejoin at `s.d.foundation` | TASK-11a |
| `migrate` holds no index lock; an add on the old origin mid-run is never moved | hold the index lock from step 1 to step 5, or re-diff the index before retiring and stop on new rows | TASK-7b |
| `migrate` on a laptop can sleep mid-retire | run under `caffeinate -i` on macOS; make the retire idempotent on rerun | TASK-7b |
| The 2 GiB import cap has no override | the preflight lists over-cap ids; add `--max-bytes` | TASK-7b |
| A fresh-bucket `setup --r2` can die between pointers and the marker | write `share.json` before step 9 when the bucket is new; add a fresh-bucket variant of row 11 | TASK-4 |
| A slow R2 adds up to 2 s to every machine request | add a failure-mode line with Worker wall-time as the signal; consider a lower read cap after L3 measures it | TASK-3 |
| A DELETE-then-PUT rebind can leave NXDOMAIN cached past the API gap | TASK-1b(f) measures through a public resolver queried during the gap | TASK-1b |
| A die at steps 9 or 10 with `--alias` leaves `v:2` pointers that block a v0.8.0 member's sweep | that die names the rerun or the pointer cleanup | TASK-5 |
| The Mini carries both tenants; a reboot stalled at the login window takes both down | vps-mon `healthz` on both hostnames is the signal; state it in the failure table of the ADR | TASK-10, TASK-11b |
| `hits` of a machine row on a member is unspecified; members see `--host` rows at the wrong URL | `hits` on a member refuses a machine row; pointers carry an `own_host` display field | TASK-2b, TASK-6 |
| The member purge is undefined on a tenant (route, not custom domain; machine rows refused on members) | a member purge refuses while the Worker binds `PASS="1"`; the origin runs `--no-r2` first; tenant purge order is route, pointers, records, script, bucket | TASK-4 |
| The migrate gated check needs Access read; the old origin's tunnel name may be missing | step 4 uses the old origin's stored Access token; preflight reads `tunnel_name` from the API by `tunnel_id` when the key is absent | TASK-7b |
| bsdtar lists a hardlink as a regular mode with `link to`; archive flags can pin files | the pre-scan rejects any `link to`; extract with no file flags or xattrs; row 18 gains a sibling hardlink and an absolute one | TASK-7a |
| Pointers expose every machine link's URL to every member | `docs/setup.md` says so in the onboarding | TASK-10 |
| The D3 rollback rebinds before restoring app destinations | restore destinations first, then rebind | TASK-5 |
