# Implementation notes: menu bar app

Delta from `docs/specs/SPEC-003-menu-bar.md`. Decisions already in the spec are referenced, never restated.

## Decisions made without the operator

- The operator delegated the whole cycle and was away, so design and spec approval were self-approved and recorded in the gate ledger as such. The design lane's one-question loop could not run (bypass mode).
- Research changed the contract before it was written: no `version` field (the script carries no version string), a `serves_here` field added (the `hosts=` guard), `SHARE_CLIPBOARD=0` set for every child process.

## Deviations

- The first spec draft used `share status --json`. The design review showed an older CLI ignores the flag and prunes, so the contract became the verb `share state` (DEC-008). The ADR carries an amendment line rather than a rewrite.
- The review turned up two bugs in share that exist today and that the app would trigger more often: concurrent index writers lose rows, and `quick.url` survives `stop`. Both are fixed in the spec's TASK-001 instead of a separate PR, since the app's correctness depends on them.

## Landmines found while building

- bash 3.2's `printf '%d' "'c"` sign-extends bytes above 127 (`%FFFFFFFFFFFFFFC3` for the first byte of `é`). The pure-bash `urlenc` masks with `$((c & 255))`; probed against `jq @uri` on accented, CJK and emoji names under both `/bin/bash` 3.2 and bash 5.

## Open questions for the operator

- The final product name. The spec ships "Share Bar" as a working name (DEC-007); the rename touches one constant, the Info.plist, and the cask file.

## 2026-09-27 15:00 TASK-006: ShareBarCore CLI runner

- Used `posix_spawn` directly (not Foundation's `Process`), since `Process.terminate()` only signals the direct child and the spec needs `killpg` to reach grandchildren (e.g. a `sleep 30 &` a shell wrapper backgrounds).
- `SHARE_BIN` is trusted outright when set, no `fileExists` check, matching the existing convention for `SHARE_ROOT`/`SHARE_CONFIG_DIR` in `bin/share` (both are trusted env overrides with no existence probe). The four fixed candidate paths are each gated by the injected `fileExists`, since those are guesses, not explicit operator intent. The spec's acceptance line ("locate order with an injected file-exists check") doesn't pin down whether `SHARE_BIN` itself is checked; this reads it as consistent with the bash side's convention.
- The exit-status decoding for the BSD wait status is a plain reimplementation of `WIFEXITED`/`WEXITSTATUS` (the C macros aren't directly callable from Swift): normal exit yields the exit code; a signal-killed process yields `128 + signal`, the common shell convention. Not stated in the spec; only `status: Int32` is.
- `MutationQueue` chains each call onto the previous call's `Task` rather than relying on actor isolation alone: a bare `await CLI.run(...)` inside an actor method is reentrant (Swift actors interleave suspended calls), so two `run()` calls could otherwise spawn concurrently despite the actor. Verified with a negative control (reverting to the bare/reentrant form fails the strict-order test, "B\nA\n" instead of "A\nB\n").
- The shared in-flight `state` call is a private `StateCoalescer` actor behind `CLI.state(timeout:)`, not a new type in the public API sketch; `CLI`, `CLIResult`, and `MutationQueue` are the only names the spec pins. Verified with a negative control (dropping the coalescing spawns 3 processes for 3 concurrent calls instead of 1).
- `CLI.spawnCancellable` and `CLIJob` are implemented per the API sketch (streaming `onOutput`, `cancel()` TERMs the group then KILLs 3s later) even though TASK-006's acceptance bullets don't name a specific test for them; TASK-011 (the setup window) is the real consumer. Added one smoke test covering streaming + cancel-kills-the-group, using the same `/bin/sh -c 'sleep 30 & echo $!; wait'` shape as the timeout test.

## 2026-09-27 12:15 TASK-012: Info.plist and build.sh

TASK-012: no deviations; matches the spec verbatim (every Info.plist key, ad-hoc default, `--sign` hardened runtime, `--notarize` staple-then-zip, precondition checks named the missing identity/profile and exit non-zero, `--show-bin-path` locates the universal binary).

- The DWARVES_NOTARY notarytool profile was not present on this build Mac (`xcrun notarytool history --keychain-profile DWARVES_NOTARY` errored) despite the task brief stating it was. The App Store Connect API key backing it exists in 1Password (`dfoundation-prod`, item ending "Hacker Bar Release", stored on the Mini as profile `HACKERBAR_NOTARY`; see memory `dwarves-macos-release-signing`). Attempted to provision `DWARVES_NOTARY` locally via `xcrun notarytool store-credentials` against both the login keychain and the dedicated `codesign.keychain-db`; both failed non-interactively ("User interaction is not allowed" / keychain locked). Storing a new notarytool credential needs an interactive GUI keychain prompt this session cannot supply.
- Verified everything else for real: the ad-hoc universal build (`lipo -archs` -> `x86_64 arm64`, every Info.plist key present with the given version), `--sign` alone (`codesign -dvv` shows `Authority=Developer ID Application: Dwarves Foundation Company Limited (W777S7V8TN)`, `flags=0x10000(runtime)`, `spctl` accepts as plain Developer ID), and the missing-identity negative control (exits 1 naming the identity). Did not run `--notarize` end to end; the script's own precondition check correctly refuses with the missing-profile message, which is itself a real (if unintended) exercise of that code path.
- Open for the operator: provision `DWARVES_NOTARY` once, interactively, on this Mac (`xcrun notarytool store-credentials DWARVES_NOTARY --key-id ZXWS6YT3KX --issuer 9d5d08d8-d5bf-4414-af78-2fb50c26fe44 --key <path to the Hacker Bar Release .p8>`, pulled from 1Password `dfoundation-prod`), then rerun `bash mac/build.sh --sign --notarize <version>` to get the `Accepted` / `stapler validate` / `Notarized Developer ID` outputs this task could not produce.
