# SG-09 Share Bar popover (SPEC-009 TASK-4b6 to 4b13)
Model: opus
Effort: high
**Branch:** feat/sharebar-popover
Design: bearing
Done-mode: proof
Wall budget: 600 min
Port base: 31500

## Done =
SPEC-009 TASK-4b6 to 4b13 pass their AC. Every screen an AC names is captured by `mac/shots.sh` through real clicks, key events and drags (never by setting state), in light, dark and the narrowest popover width the spec allows. Before landing: score each screen against `docs/design/share-bar-redesign.html` revision 8 and `docs/design/share-bar-interactions.md` (layout, copy, states, contrast, focus), fix every gap, and re-shoot until clean; then compare with Mobbin references (the Mobbin MCP tools; references named in SPEC-009 `## UI design` and the prototype) and record the comparison per screen in `docs/verification/share-bar/popover.md`. swift build, test, `mac/build.sh 0.0.0` and `mac/compat-check.sh v0.9.0` pass.

## Scope edges
`mac/` only. The fake CLI decouples the UI from the live CLI.

## Touches
mac/**
docs/verification/share-bar/**
docs/implementation-notes/share-bar.md
