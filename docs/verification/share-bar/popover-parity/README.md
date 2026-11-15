# Popover design parity (revision 8)

Each image in `parity/` has the design render on the left and the build on the right. The design renders come from the mega-goal's reference set (`calm` and `menu`, light and dark; the menu scenario is the admin tenant, so its rows differ from the build's calm list). The build renders come from the app's own DEBUG hook (`-ShareBarShotsRender`), driven by `mac/Tests/fixtures/popover/parity-shots.sh`: no pointer or key input reached the desktop.

Samples are sRGB, from `parity-sample.swift`. Text is the extreme pixel of its box. The whole popover shifts about +3 steps from the raw token values in both renders, so the build and the design compare like for like.

| Sample (light) | Design | Build after | Step | PR #65 build before |
|---|---|---|---|---|
| background | #f2f3f5 | #f2f3f5 | 0 | #e4e4e5 (system vibrancy, desktop dependent; owner measured #dddedf) |
| primary text | #272729 | #272729 | 0 | same |
| secondary text | #727277 | #727277 | 0 | same |
| search placeholder | #8d8d92 | #7e7e83 | 15 (deliberate) | prompt color ignored, system gray |
| separator | #e0e1e3 | #e3e4e6 | 3 | 12% ink, about 3 steps darker |

| Sample (dark) | Design | Build after | Step | PR #65 build before |
|---|---|---|---|---|
| background | #393a40 | #393a40 | 0 | #7b7c7d (vibrancy over a light desktop; owner measured #676869) |
| primary text | #f7f7f9 | #f7f7f9 | 0 | same |
| secondary text | #bebec3 | #bebec2 | 1 | same |
| search placeholder | #9c9ca0 | #a2a2a7 | 7 (deliberate) | system gray |
| separator | #4e4f55 | #4e4f55 | 0 | 12% ink |

## Gaps

- (a) Background: the popover root paints `#eff0f3` (dark `#2b2c31`) opaque, so it no longer depends on the desktop behind it. Opaque, because a tint over the material would still move with the wallpaper. The native arrow keeps the system material; it cannot be imaged without screen input, so it is not sampled.
- (b) Placeholder: drawn as its own text in the tertiary ink, since SwiftUI ignores a color on `prompt:`. It stays darker than the design (`#6b6b70` against `#7a7a80`) on purpose: the tokens keep the 4.5:1 contrast the prototype missed. This is the one deviation.
- (c) Keycap: `⌃⌥S` sits in a 1 pt border at 14% ink with the 4 pt chip radius, 10.5 pt medium type.
- (d) Row menu: anchored under the row's More button, right edge aligned, first item lit. The popover grows to hold the menu below the row. Before, the popover's height read as zero, so the menu flipped up over the header and the search.
- (e) Trailing age: the spec wins. SPEC-009 `### Components & states` lists a "relative age" on every link row, so the age shows on every row. The design's "Nd left" is the meta line and is unchanged. The CLI does not print `added` in `share state` yet, so on a live tenant the column stays empty until it does; the fixtures carry `added`.
- (f) Separator: 12% to 9%.
- Arrow: the native `NSPopover` arrow stays; no spec text asks for another.
- Kept: the darker tertiary, and every other color and token.

Files: `parity/after/*.png` (build), `parity/before/*.png` (the old views through the same hook; they have no root fill, so they read transparent), `parity/*-parity.png` (side by side), `parity/*-parity-before.png`.
