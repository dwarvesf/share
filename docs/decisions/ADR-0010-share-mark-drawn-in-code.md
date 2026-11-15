# ADR-0010: the Share mark is an open ring, drawn in code

Status: accepted
Date: 2026-11-14

## Context

Share Bar's status item used one SF Symbol (`antenna.radiowaves.left.and.right`, slashed when not serving), as `docs/briefs/DECISION-BRIEF-menu-bar.md` decided. It is a borrowed, generic radio glyph, it says nothing about share, and the app had no icon of its own: Finder and System Settings showed the default. A logo comparison on the two menu bar apps picked the open ring.

## Decision

- The mark is a ring (your Mac) with an opening at the top right and one dot leaving through it (the link going out). Serving is the open ring plus the dot. Not serving is the closed ring with no dot. Master: `docs/brand/share-mark.svg` (1024, macOS grid: 824 body, ink `#0B1B16`, ring `#F4F1EA`, dot `#18C37E`).
- The menu bar glyph is a template image drawn in code from `ShareBarCore/Mark.swift`, 18 pt with 16 pt of glyph, bitmaps at 1x, 2x and 3x (`StatusGlyph`). It replaces the SF Symbol. A bitmap that fails to draw leaves the text title "Share Bar", so the item is never blank. The brief's "one SF Symbol, no badge, no color" becomes "one template glyph, open ring plus dot while serving, closed ring otherwise; no badge, no color". The brief carries the amendment.
- The app icon is drawn by `mac/Tools/make-icons.swift` (run through `mac/icons.sh`, which `mac/build.sh` calls), from the same `Mark.swift`. It writes the 1024 master, the iconset, and `AppIcon.icns`, which the build puts in the bundle with `CFBundleIconFile`. No binary art is committed except the rendered master and contact sheet under `docs/brand/`.
- Small sizes use a second cut, `Mark.Cut.small`: ring 46 thick instead of 40, opening 68 degrees wide instead of 60, dot pushed 10 units out and 1 unit larger. The menu bar glyph and the 16 and 32 px app icon renders use it; the master uses the full cut. In the eval sheet the green dot merged into the ring at 16 px, so the gap between dot and ring must stay open at every size the app draws.
- The 1.5 second checkmark after a successful add stays an SF Symbol: it is a confirmation, not the brand.

Alternatives rejected:

- Keep the SF Symbol: no identity, and the slash reads as "broken" rather than "stopped".
- Ship PNG or PDF glyph assets: a binary to keep in step with the SVG, and a tint and scale path to test. Code is one source for the glyph and the icon.
- A badge or a color on the glyph for the state: the brief rules out color in the menu bar, and the dot already carries the state.

## Consequences

- One set of shapes feeds the glyph, the icon, and the tests; `MarkTests` renders both states at 16, 18, 32, 36 and 54 px and fails when the dot touches the ring, the opening closes, or the two states stop differing.
- `mac/build.sh` compiles a small Swift tool each build (a few seconds) and needs `swiftc` and `iconutil`, both part of the Xcode command line tools the build already requires.
- A change to the mark is a change to `Mark.swift` plus a re-export of `docs/brand/share-mark.svg`; the SVG is the full cut only and is not generated.
- The CLI has no graphical surface; the mark reaches it through the app and the brand assets in `docs/brand/`.
