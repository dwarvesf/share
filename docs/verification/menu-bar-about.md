# Verification: About Share Bar menu item

Work: the status-bar menu gets an "About Share Bar" item, placed directly
above "Quit Share Bar", that opens the standard `NSApp` About panel;
`Info.plist` carries `NSHumanReadableCopyright` so the panel shows the
copyright line.

Done = the live app's status menu shows the item in that position, clicking
it opens a real About panel showing the app name, version, and copyright,
and the parent commit (before this change) has no such item.

## Green run

Built `mac/build/Share Bar.app` at `8e2bd98` via `bash mac/build.sh 0.0.0`,
launched with `SHARE_BIN` pointed at a stub CLI (prints the repo's
`state.json` fixture for `share state`, exits 0 otherwise), driven through
System Events on the real status item.

```
Command: bash mac/build.sh 0.0.0
Exit:    0
Verdict: PASS (produced mac/build/Share Bar.app + Share-Bar-0.0.0.zip)

Command: SHARE_BIN=<stub> "mac/build/Share Bar.app/Contents/MacOS/ShareBar" &
Exit:    0 (backgrounded; pgrep -x ShareBar confirmed running)
Verdict: PASS
```

Menu items, in order, after clicking the status item (System Events, AXPress
only, no keystrokes):

| # | Title |
|---|---|
| 1-9 | share rows (Serving at s.han.ws, docs.han.ws, localhost:3000, notes.txt, separators) |
| 10 | Share File... |
| 11 | Stop Sharing |
| 12 | (separator) |
| 13 | Open at Login |
| 14 | (separator) |
| 15 | **About Share Bar** |
| 16 | **Quit Share Bar** |

"About Share Bar" sits directly above "Quit Share Bar", as specified.

Clicked "About Share Bar". A new window appeared (AX description `dialog`).
Its static text values, read via AX (`entire contents`, class `static text`):

| AX static text |
|---|
| Share Bar |
| 0.0.0 (0.0.0) |
| Copyright © 2026 Dwarves Foundation. MIT License. |

App name, a version string containing the build version (`0.0.0`), and the
`NSHumanReadableCopyright` string all render, confirming both the
`StatusItemController.swift` menu-item wiring and the `Info.plist` addition.

Closed the panel via its AX close button (`button 1 of window 1`, subrole
`AXCloseButton`), not Cmd+W:

```
Command: click button 1 of window 1 (About panel)
Exit:    0
Verdict: PASS (window count 1 -> 0)
```

Killed the app PID; `pgrep -x ShareBar` returned empty (exit 1).

## Negative control

Extracted the parent commit's `mac/` tree (`git archive 8e2bd98^ mac | tar -x
-C <scratch dir>`, no worktree), built and launched it identically with the
same stub CLI.

```
Command: bash mac/build.sh 0.0.0   (parent-commit copy)
Exit:    0
Verdict: PASS (builds cleanly, as expected: unrelated to this change)

Command: click status item, list menu item names
Exit:    0
Verdict: RED as expected -- "About Share Bar" is absent; the menu ends
         ...Open at Login, Quit Share Bar (no item between them)
```

This is the expected RED: the parent commit predates the feature, so the
menu item and About panel do not exist there. Killed the process; `pgrep -x
ShareBar` returned empty.

## Not proven

- Signed/notarized builds (`--sign`/`--notarize`) were not exercised; only
  the ad-hoc-signed dev build.
- No coverage of the About panel's "Credits"/other buttons beyond the close
  button.

## Rollback

Revert the commit: `git revert 8e2bd98`.
