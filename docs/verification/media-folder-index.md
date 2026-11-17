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

## Recorded run

```
Command: SHARE_TEST_ONLY='folder index' bash tests/share.sh
Exit:    0
Output:
=== folder index ===
  ok    folder without index gets a listing
  ok    txt linked by name
  ok    .md listed by its render
  ok    --no-index keeps the 404
  ok    README folder answers
  ok    README render is the index
  ok    no generated list under a README
  ok    refresh keeps the listing
  ok    nested folder answers
  ok    nested file listed by path
  ok    no subfolder entry
  ok    media folder answers
  ok    media: the generated-listing marker stays exact on line 1
  ok    media: a video is an inline player with its attributes
  ok    media: the video has a download link
  ok    media: every image is lazy and async, uppercase extension included
  ok    media: the lightbox and its script ship once
  ok    media: rows group by folder, the root has no heading
  ok    media: a non-media file is a plain row with its type and size
  ok    media: a human size on the video
  ok    media: the page loads nothing from outside
  ok    media: the folder still types as a folder, not a site
  ok    text-only folder answers
  ok    text-only: a clean grouped list, no player, no lightbox, no script
  ok    text-only: both files listed with a size
  ok    a folder with its own index.html answers
  ok    a folder with its own index.html keeps it byte for byte
  ok    --no-index on a media folder writes no index.html
  ok    hostile folder answers
  ok    hostile: no injected script or tag, the page's own script is the only one
  ok    hostile: no element beyond ours, three img (two files and the viewer) and one video
  ok    hostile: the label is escaped text
  ok    hostile: the href is percent-encoded
  ok    hostile: unicode and ampersand encode byte for byte
  ok    hostile: a name that looks like a scheme stays a relative link
  ok    hostile: an attribute-breaking alt is escaped
  ok    hostile: a hostile folder name is an escaped heading
  ok    hostile: the encoded link serves the file
586 checks, PASS (filtered by SHARE_TEST_ONLY: 25 sections ran, the rest skipped)
Verdict: PASS
```

```
Command: shellcheck bin/share tests/share.sh
Exit:    0
Output:
(no output)
Verdict: PASS
```
