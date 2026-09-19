# Verification: CHANGELOG.md generation

Work: `bin/changelog` regenerates `CHANGELOG.md` from tag history and
conventional-commit subjects; `bin/release` regenerates + commits it to main
before tagging so every tag carries its own section.

Done = the committed `CHANGELOG.md` is byte-identical to a fresh
`bash bin/changelog` run, sections group the right subjects under the right
tag ranges, the script parses under bash 3.2, and the generator is
load-bearing (a broken generator produces output that fails the check).

## Green run

```
Command: bash bin/changelog | diff -q - CHANGELOG.md
Exit:    0
Verdict: PASS   (generated output byte-identical to the committed file)

Command: /bin/bash -n bin/changelog && /bin/bash -n bin/release
Exit:    0
Verdict: PASS   (parses under macOS /bin/bash 3.2)

Command: shellcheck bin/changelog bin/release
Exit:    0
Verdict: PASS

Command: bash bin/changelog --next v0.3.0 | head -3
Exit:    0
Verdict: PASS   (top section reads "## [v0.3.0] - <today>", not Unreleased)
```

Spot-checked against git: `git log --format=%s v0.1.0..v0.1.6` matches the
`## [v0.1.6]` section; `v0.1.6..v0.2.0` matches `## [v0.2.0]` (feat #9, #11;
docs #12); `v0.2.0..HEAD` matches `## [Unreleased]` (feat #13, #14; test #15;
the changelog commit itself).

## Negative control

Mutated `entry()` in `bin/changelog` to `printf '%s\n' "$1"` (type prefixes no
longer stripped, no `- ` bullets), keeping every other line intact.

```
Command: bash bin/changelog | diff -q - CHANGELOG.md
Exit:    1
Verdict: RED    (every entry line malformed; check catches it)
```

Restored via `git checkout bin/changelog`, regenerated `CHANGELOG.md`,
amended; `bash bin/changelog | diff -q - CHANGELOG.md` returns 0 (GREEN).
