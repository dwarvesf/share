# Proof of done: media-aware folder index

Branch: feat/media-folder-index
Spec: `docs/specs/SPEC-011-media-folder-index.md`

## Green run

| Check | Command | Result |
|---|---|---|
| core group, which holds the `folder index` section with the new rows | `SHARE_TEST_ONLY='folder index' bash tests/share.sh` | exit 0, 586 checks, PASS, 0 FAIL; all 38 `folder index` rows ok |
| shellcheck | `shellcheck bin/share tests/share.sh` | clean, no output |
| macOS bash 3.2 parse | `/bin/bash -n bin/share`; the suite adds the media folder through `"$SH" add`, which runs under the `#!/bin/bash` shebang (3.2.57) | ok |
| shard map | `bash tests/ci/shard-check.sh` | 85 sections, each in exactly one shard |
| GNU and BSD `stat` | `gen_index` on one folder with GNU coreutils `stat` first on `PATH`, then the stock BSD `stat` | byte-identical page apart from the `<h1>` folder name |
| lightbox in a real browser | headless Edge, a script that sends a click, ArrowRight, two ArrowLeft and Escape | opens on the clicked image, moves, wraps 1 to 9, `Open full file` points at the original, Esc closes and clears the `lb-open` class |
| rendered pages | headless Edge at 1440 px and a true 400 px viewport (iframe), light and dark, lightbox open at both widths | no horizontal scroll, one column at 400 px, the image fits the viewport, the lightbox covers the page |

## Negative control

`html_esc` with its `<` rule removed, same suite run in a scratch copy:

```
Command: SHARE_TEST_ONLY='folder index' bash tests/share.sh   (scratch copy, bin/share without the < escape)
Result:  RED
  FAIL  hostile: no injected script or tag, the page's own script is the only one: expected '1 0 0 0', got '2 1 0 0'
  FAIL  hostile: the label is escaped text: expected '1', got '0'
  FAIL  hostile: a hostile folder name is an escaped heading: expected '1', got '0'
```

Restored (the real tree was never edited): the same rows are ok in the green run. The other FAIL lines in that scratch run come from the copy having no git history and no top-level README, not from the change.

## Not covered

The Cloudflare tunnel and R2 serving paths are not run here: `gen_index` is one call inside `stage_copy`, shared by both, and the suite exercises it through the local server. Video seeking over R2 depends on the Worker's range handling, which this change does not touch.
