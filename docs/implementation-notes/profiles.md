# Implementation notes: profiles

Delta from `docs/specs/SPEC-005-profiles.md`. Decisions already in the spec are referenced, never restated.

## Decisions made without the operator

- The dispatch brief named the spec SPEC-003; that number was already taken by the menu bar app, and a sibling agent had reserved SPEC-004 for per-link Access, so this cycle took the next reserved number, 005, with ADR-0005 to match.
- The brief called the default profile "personal". The CLI reserves `default` for the unnamed profile (DEC-001) and does not alias `personal`; a profile named `personal` would be a fresh setup. The report says so.
- The operator was away; the spec's two validation rounds ran as fresh-context subagents, and the lead applied their findings and recorded the gates.

## Deviations

- Round 1 of validation turned three "profiles share nothing" assumptions into refusals the first draft lacked: a misplaced `--profile` after the verb, a runtime port guard in `serve`, an `add <port>` refusal of another profile's port pair, and a `setup` refusal of another profile's hostname. All four landed in the same diff; the spec was rewritten before the code, not amended after.
- The serve port guard changes the default profile's behavior (DEC-005): a second `share serve` on an already-bound port now dies instead of binding beside an orphaned caddy through SO_REUSEPORT. The validator reproduced the silent double bind with caddy v2.11.4 before the guard was added.
- The negative control for the port pick is a mutation (`free_port` returns a constant), not a revert: reverting the pick would put two test profiles on 8787 beside the operator's real share on this machine, and SO_REUSEPORT would split its live traffic for the length of the run.

## Landmines found while building

- `env VAR=x cmd --flag` puts `--flag` after the command, but a helper that splices `"$@"` before `bash` hands the flag to `env`; the probe helper takes `VAR=value` words first and everything else after the script.
- A launchd plist names the profile's root three times (config dir, root, both log paths), so a grep count of the directory is not a useful assertion; the test greps the two keys instead.
- `set -e` and `[[ test ]] && cmd` as the last line of a function make the function fail when the test is false; the teardown rmdir is written as `[[ -z $profile ]] || rmdir ... || true`.

## Open questions for the operator

- None blocking. The live proof on the Mini needs a Cloudflare token with Tunnel Edit, DNS Edit, and Zone Read on `d.foundation`; the CI token has Zone Read and Tunnel Read but no DNS scope, so `setup` stops at the DNS check before creating anything.
