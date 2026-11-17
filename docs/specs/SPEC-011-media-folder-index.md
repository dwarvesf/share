# SPEC-011: a media-aware generated folder index

Status: IMPLEMENTED
Lane: normal

## Problem

`gen_index` writes a bare `<ul>` of links. A folder of App Store videos and screenshots shared with `share` came out as a wall of file names, so a gallery `index.html` was built by hand. Every share user should get that by default, tunnel or R2, with no extra flag.

## Behavior contract

- Unchanged: a folder with its own `index.html` or `README.html` keeps it; `--no-index` writes no index; dotfiles and symlinks never ship; line 1 of the generated page keeps `<title>index</title>` (`type_of` reads it to type the share as a `folder`, not a `site`).
- Rows are grouped by folder path (the root first, no heading). Each row has the name as a link, a short type and a human size. A `.md` that pandoc rendered is listed by its `.html`.
- `mp4 mov m4v webm`: an inline `<video controls playsinline preload="metadata">` plus a download link.
- `png jpg jpeg gif webp avif svg`: a responsive grid of `<img loading="lazy" decoding="async">` on the originals, with a lightbox (click opens, Esc closes, arrows and swipe move, a link to the full file; fits the viewport, covers the page on a phone).
- Everything else: a plain row. A folder with no media is a clean grouped list with no script.
- The look is `write_md_style`'s paper theme, light and dark, readable at 400 px with no horizontal scroll; inline CSS and one inline script; no external font, script, image or request.
- Safety: every label is HTML-escaped and every href and src is `urlenc`-encoded; a name with a control character is served but unlisted.
- bash 3.2 and shellcheck clean, no new dependency; `stat` is read GNU form first, then BSD.

## Verification

`SHARE_TEST_ONLY='folder index' bash tests/share.sh` (the section runs as part of the `core` group), then `shellcheck bin/share`. New rows cover a mixed media folder, a text-only folder, a folder with its own `index.html`, `--no-index`, and a hostile-name folder (quotes, markup, spaces, unicode, a scheme-looking name, a hostile folder name). A headless-browser pass renders a real mixed folder at 1440 and 400 px, light and dark, with the lightbox open.

## After state

`gen_index` in `bin/share` emits the page above; `README.md` and `docs/how-it-works.md` describe it; `tests/share.sh` holds the new rows.

## Task Breakdown

- [x] TASK-1: rewrite `gen_index` and its helpers (`html_esc`, `human_size`, `gi_kind`, `gi_flush`, the page CSS and script) in `bin/share`
- [x] TASK-2: add the media, text-only, own-index, `--no-index` and hostile-name rows to the `folder index` section of `tests/share.sh`
- [x] TASK-3: document the page in `README.md` and `docs/how-it-works.md`
