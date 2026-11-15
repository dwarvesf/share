# Popover B: publish and drop, drag out, Quick Look, hotkey

SPEC-009 TASK-4b10 to TASK-4b13. Every capture here comes from the app's own DEBUG hook (`-ShareBarShotsRender` with `-ShareBarShotsScene`), run by `mac/Tests/fixtures/popover/popover-b-shots.sh`: no pointer, key or drag input reached the desktop (owner decision 2026-11-15, SPEC-009 DEC-83). Light and dark. The popover is a fixed 340 pt wide, so 340 pt is also the narrowest width; Quick Look is drawn at 560 pt, the widest the spec allows.

| Screen (AC) | Capture | How it is reached |
|---|---|---|
| drop overlay during a drag from Finder | `drop-{light,dark}.png` | `dragEnter`, the event the status item and popover drop targets send |
| uploading row at step 2 | `uploading-*.png`, `publish-live-*.png` | `publish-live` runs the real drop path: `add` through the queue with `SHARE_PROGRESS=1` against the fake CLI, captured while step 2 is the latest journal line; `argv.log` holds `--profile default add <file>` |
| new row flashed after publish | `flashed-*.png` | `publishFinished` plus the row flash |
| footer hint during a drag out | `dragout-*.png` | `dragOutBegan` |
| URL pasted in TextEdit after the drop | not captured | needs a real drag into another app; the payload is covered by `DragOutTests` (URL and plain text on one provider) |
| Quick Look on a local PDF, a folder, a port share, a cloud link | `ql-pdf-*`, `ql-folder-*`, `ql-port-*`, `ql-cloud-*` | the Quick Look view for a fixture row; the PDF and folder read `pub/<id>/<name>` under a fixture home |
| popover opened by ⌃⌥S, search focused | `hotkey-*.png` | `issues`, then the handler the Carbon hotkey calls (`openForHotkey`); the Finder-frontmost part is not imaged |

## Design parity

`parity/<scene>-<theme>-parity.png` has the revision 8 render (headless Chromium, `popover-b-parity.sh`) on the left and the build on the right. `parity/run.txt` holds the sRGB samples of every screen. All 18 runs read `every sample within its allowance`: 6 steps, the search placeholder 16 (the deliberate darker tertiary of the popover parity run).

## Deliberate deviations

- Search focus ring after ⌃⌥S: the design shows a caret and a ring on the field; the build draws the ring (the caret needs a live key window).
- Drop overlay: `Stored on this Mac` where the design says `Stored on Mini`; SPEC-009 words it as `this Mac`.
- Uploading row: `Step 2 of 3 · Uploading` where the design says `Uploading to this Mac · 50%`; the CLI reports steps (SPEC-010 G9), not bytes.
- Quick Look pdf capture composes the file's `QLThumbnailGenerator` image; the live panel uses `QLPreviewView`, which an offscreen window captures blank.
- Quick Look cloud link: glyph and meta line, no preview (DEC-55); the design draws a type placeholder.
- Folder preview lists entries alphabetically with a film glyph for video; the design uses a fixed sample list and a camera glyph.
- Row glyphs for pages stay the compass of popover A; the design draws a window glyph.
- The design page is 2 pt taller than the build (530 against 526), as in the popover parity run.

## Mobbin comparison

See `mobbin.md`.
