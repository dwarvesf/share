# Fast test loop: implementation notes

The delta for the fast-test-loop sub-goal. There is no spec file: the goal file is the contract (Design: obvious). It reserved SPEC-017 but needs no spec text.

## Decisions the goal left open

| # | Decision | Why |
|---|---|---|
| F1 | One filter, `SHARE_TEST_ONLY`, covers `tests/share.sh` and `tests/members.sh`. The old `MX_ONLY` is gone. | One knob; `MX_ONLY` matched a substring of a title and was members-only. Proof files that cite `MX_ONLY` stay as history. |
| F2 | A section is `if section "<name>"; then ... fi`. Setup that every run needs is `section_always "<name>"`. | The marker line also prints the old `=== name ===` line, so a full run prints what it printed before. |
| F3 | Groups are `# group <name> = <ERE>` lines in the header of `tests/share.sh`. A filter that names any member runs every member. `# pull A -> B C` makes group A run groups B and C too. | The goal asks for named groups in a comment block. Pull edges express "late sections need all earlier state" without making every early section pull the whole suite. |
| F4 | `stop` is now `section_always`, and its `stop takes links down` check runs only when `md_url` is set. | A filtered run that skips `add` still has to stop its server, or the host-guard control after it sees a running serve. A full run keeps the same check count. |
| F5 | The timing table also prints a second list: stretches of 5 s or more before a check. | The goal asks to cut idle waits; the list finds them by measurement instead of grep. It also tells later builders where a section idles. |
| F6 | A filter that is not a valid ERE exits 2 before any test runs; a filter that matches no section prints a warning on stderr. | A typo should not look like a green run. |
| F7 | Bash 3.2 rules for the harness: indexed arrays only, no `${v,,}`, no associative arrays. | The suite also runs under `/bin/bash`. |

## Open questions

- `late` and `groundwork` pull `core` because `serve on a busy port` needs the suite's own server on the port, and `serve` hangs without it. A new check that reads a running server belongs in `core` or pulls it.
- Groups are coarse. `core` pulls 25 sections for any one of them. The proof file says how they were validated.
- The suite check count is the proof that the markers lost nothing: 1826 before, the same after.

## AC map

| Done = | Test or check |
|---|---|
| (a) filter runs only matching sections, fixtures always run, one `skip` line per skipped section | filtered run in the proof file; every section run alone by a sweep script |
| (a) groups pulled whole | `SHARE_TEST_ONLY` on one member of a group in the proof file |
| (b) timing table, slowest first, total | last lines of every run |
| (c) idle waits cut | before and after tables in the proof file |
| Proof: same check count | `1826 checks, PASS` before and after |
