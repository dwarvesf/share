# Verification -- menu-bar-profiles

Share Bar reads `share profiles --json` (every profile's state in one call), renders a section per profile with health, gated-share lock markers and pending Access counts, and publishes drops/selected files publicly or behind a login rule, with `--profile <name>` on every app-side CLI call.

## Green run 1: CLI suite

```
Command: bash tests/share.sh
Exit:    0
Checks:  every check ok, 0 FAIL (PASS), tree at this commit
Tail:    === NEGATIVE CONTROL: a host outside hosts must not serve ===
           ok    start refused on another host
         === process leaks ===
           ok    no real launchd or systemd share job appeared during the run
         PASS
Verdict: PASS
```

Covers, in the new `profiles --json` blocks: exit 0 and parseable output, `schema: 1`, default-then-alphabetical order, each entry's nested `state` byte-equal to an independent per-profile `share state` read, no filesystem writes during the read, `--bogus` and a second argument refused with the usage line, the TSV listing unchanged, an exported `SHARE_ROOT` not leaking into children, `Bad`/`a"b`/`profiles/default` as error entries beside intact good profiles, and the bash `env -u` list matching the Swift `strippedEnvironmentKeys` list.

## Green run 2: app tests

```
Command: swift test --package-path mac
Exit:    0
Checks:  146 tests, 0 failures
Verdict: PASS
```

Covers the matrix rows assigned to `swift test`: `ProfilesSnapshot` decode (fixture, unknown fields, newer entry schema -> `Update Share Bar`, unreadable state confined to its entry), `from(_:)` result mapping (missing CLI, TSV -> `.oldCLI`, brace-check, stderr rules), the `profiles --json` argv, coalescing plus the `fresh` no-join-then-rerun rule, `verbForLog`, the child environment strip with PATH/LANG/SHARE_CLIPBOARD rules, `Health` table precedence (`notSetUp` before `elsewhere`, neutral vs attention), worst-health icon, every header rule including `Working...` variants and the stale-snapshot case, section actions (`showStart`/`showStop`/`showSetUp`, per-profile command names, `access_pending`), row caps (25 / 10 each), the (profile, id) composite key, gated-row text and marker semantics, `AccessRule`/`PublishChoice`/`PublishForm` (eligibility, remembered profile and rule, login surviving a switch, quick-mode disable, button titles, add argv, relative-path refusal), `MutationOutcome` verbatim `detail`, `PublishMessage` batch/folder/file text, and `MutationQueue` JobToken (`cancel(job:)` reaching only its own job, stale token a no-op).

## Green run 3: app build + lint

```
Command: swift build --package-path mac
Exit:    0 (Build complete)
Command: shellcheck bin/share install.sh tests/share.sh tests/e2e.sh demo/render.sh mac/*.sh
Exit:    0
Verdict: PASS
```

## Negative control 1: the pre-change CLI cannot answer --json

```
Command: env -u SHARE_ROOT -u SHARE_CONFIG_DIR -u SHARE_PORT -u SHARE_HOSTNAME \
           -u SHARE_HOSTS -u SHARE_SERVICE_LABEL -u XDG_CONFIG_HOME HOME=<scratch> \
           bash /tmp/share-ae71cd4 profiles --json
Exit:    0, but stdout is `default<TAB>not_setup<TAB>-` (TSV);
         `jq -e .` exits 5: the new JSON checks would be RED on the old binary.
Command: same invocation against bin/share at this commit
Exit:    0, stdout `{"schema":1,"profiles":[{"name":"default",...` -- GREEN.
Verdict: PASS (pre-change -> RED -> current -> GREEN)
```

## Negative control 2: dropping the `{` check maps TSV to oldCLI wrongly

```
Command: sed -i.bak 's/guard trimmed.hasPrefix("{") else {/guard false \&\& trimmed.hasPrefix("{") else {/' mac/Sources/ShareBarCore/Snapshot.swift
         swift test --package-path mac --filter StateMappingTests
Result:  RED, 2 failures at this commit:
           testBraceThatDoesNotDecodeOnExitZeroIsAnOtherFailure: got .oldCLI, expected .other
           testValidJSONOnExitZeroDecodesToSnapshot: decode never ran (got .oldCLI)
Command: restore Snapshot.swift; swift test --package-path mac
Result:  GREEN, 146 tests, 0 failures
Verdict: PASS (mutate -> RED -> restore)
```

## Not proven

- UAT on a real login session (SPEC-006 rows 8 and 25): real menu rendering, a real drop and dialog, an Access-group add on the Mini's `dfoundation` profile, the stale-snapshot icon. These are the operator's manual checks; everything the spec assigns to `swift test` or `tests/share.sh` is green above.
- Two suite flakes seen on this loaded machine (load avg ~222) and passed on the clean run above: `500-row index answers under 3s` (a documented load-sensitive check, the pre-change binary also exceeded the bound) and `row 6: pub/<id> absent while a PROBE fail was logged` (a watcher-poll race in the Access gate tests, untouched by this change).
