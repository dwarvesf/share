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
