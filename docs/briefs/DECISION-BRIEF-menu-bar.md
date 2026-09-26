# Decision brief: a menu bar app for share

## Problem

share is a CLI. To see whether links are live, what is shared, when a share expires, or who opened it, the user opens a terminal and runs `share status` or `share hits <id>`. Nothing on screen says the tunnel went down, and a non-terminal user cannot share a file at all.

## Context

- State lives in files the CLI owns: `~/.config/share/config` (hostname, mode, port), `~/share/index.tsv` (id, name, source, added date, expiry epoch, opts), `~/share/serve.pid`, `~/share/quick.url`, `~/share/access.log` (caddy JSON).
- The link for a share is not a pure function of its row. `share_url` reads the opts (`live`, `host=`), the served tree (a folder gets `/`, a `.md` with a render links to the `.html`), and the mode (quick mode reads `quick.url`).
- `share status` calls `cmd_prune` first, so it deletes expired shares. It is not a read.
- The serve daemon is share's own login service (`share service install`, launchd label `foundation.d.share`). The app must not become a second owner of it.
- dwarvesf already ships a signed, notarized macOS app from Homebrew: Spacedown (`dwarvesf/tools/spacedown` cask, bundle ids under `foundation.d.`).
- The repo is public, so a GitHub-hosted macOS CI job costs nothing.

## Solution

Design decided without the operator (bypass mode, operator away). Every call below is recorded so the spec review can reopen it.

### Approaches considered

| Approach | What it is | Traded away |
|---|---|---|
| A. App parses the files | Swift reads `index.tsv`, `config`, `serve.pid` and rebuilds each URL | Duplicates `share_url` in a second language. Every CLI change to link shape silently breaks the app. |
| B. CLI JSON contract (chosen) | New read-only `share status --json`; the app renders it and runs CLI verbs for actions | One extra CLI flag and a process spawn per refresh. |
| C. Native engine | The app reimplements share | Two engines. Rejected outright. |

### Chosen approach + why

B. The CLI stays the only code that knows what a share is. The app is a thin view plus verb runner, so it cannot drift from link logic, and the JSON is testable in the existing bash suite.

**UI toolkit: AppKit `NSStatusItem` + `NSMenu`, not SwiftUI `MenuBarExtra`.** Three needs decide it: `menuNeedsUpdate` refreshes state at the instant the menu opens; per-share submenus fetch hit counts lazily; the status item button accepts file drops. `MenuBarExtra` in menu style gives none of the three without AppKit escapes. The one window (setup) is SwiftUI hosted in an `NSWindow`.

**Ships together.** Same repo (`mac/`), same version tag as the CLI. A new cask in `dwarvesf/homebrew-tools` declares `depends_on formula: "dwarvesf/tools/share"`, so one command installs both. The formula's caveats mention the app.

**Working name.** The app's display name comes from one constant and the Info.plist. It ships as "Share Bar" until the tool rename is decided; the bundle id is `foundation.d.share.bar`.

### Onboarding

```
 brew install --cask dwarvesf/tools/share-bar      (pulls the formula too)
                 │
          first launch, icon appears, no Dock icon
                 │
     ┌───────────┼───────────────────┬────────────────────┐
     ▼           ▼                   ▼                    ▼
 CLI missing   not set up          set up, stopped      serving
 menu: "share  menu: "Set Up…"     menu: "Start         normal menu
 CLI not       opens the setup     Sharing" runs        (see UI)
 found" +      window              `share start`
 Copy Install
 Command
                 │
         setup window: hostname field, or "Quick link, no domain"
         Set Up runs `share setup <host>` (or `--quick`), output streams
         into the window; Cloudflare login opens in the browser
                 │
         checkbox "Open at login" (on by default) -> SMAppService
```

### UI

```
 ● Serving at s.han.ws              (grey ○ "Stopped", or "Not set up")
 ─────────────
 team-guide/        2d left   ▸     Copy Link      (default click on the row copies)
 notes.html         11h left  ▸     Open in Browser
 localhost:3000     live      ▸     Refresh        (snapshots only)
 ─────────────                      12 hits · 4 visitors   (fetched when opened)
 Share File…               ⌘N       ─────────
 Stop Sharing / Start Sharing       Remove…        (confirm dialog; CLI moves the copy to Trash)
 ─────────────
 Open at Login  ✓
 Quit                      ⌘Q
```

- Status icon: one SF Symbol, filled while serving, slashed while not serving. No badge, no color.
- Dropping files or folders on the icon runs `share add` for each and copies the last link.
- "Share File…" opens an `NSOpenPanel` (files and folders, multiple).
- A small notification is not used; the copied link is confirmed by a brief icon change.

### Extensibility & boundaries

| Unit | Purpose | Interface | Tested by |
|---|---|---|---|
| `share status --json` (bash) | read-only state snapshot | JSON on stdout, schema below | `tests/share.sh` |
| `ShareBarCore` (Swift library) | locate the CLI, run a verb with a timeout, decode the snapshot, map it to menu rows | `CLI.run(args) -> Result`, `Snapshot` decoding, `MenuModel(snapshot, now)` | `swift test` |
| `ShareBar` (Swift executable) | status item, menu, drop target, setup window, login item | AppKit | build + manual smoke |
| `mac/build.sh` | assemble, sign, notarize the `.app`, zip it | env: identity + notary profile | release run |

Growth: a new share kind or link shape changes only bash. A new field appears in JSON first; the app ignores unknown fields.

### I/O contract: `share status --json`

```json
{
  "schema": 1,
  "state": "serving | stopped | not_setup",
  "mode": "named | quick",
  "host": "s.han.ws",
  "service": true,
  "serves_here": true,
  "shares": [
    {"id": "3d324a", "name": "theme-check.md", "url": "https://s.han.ws/3d324a/theme-check.html",
     "kind": "snapshot | live | host", "source": "/tmp/x/theme-check.md",
     "added": "2026-09-27", "expires": 1759000000, "source_gone": false}
  ]
}
```

`expires` is 0 for never. `status --json` never prunes, never writes, and exits 0 even when not set up. Hits stay on `share hits <id>` and the app calls it per share, on demand.

### Failure modes

| Failure | Behavior |
|---|---|
| CLI not found (GUI apps get no login-shell PATH) | Probe `/opt/homebrew/bin`, `/usr/local/bin`, `~/.local/bin`; menu shows the missing state and a copy-install item. |
| CLI hangs | Every call has a timeout (status 5s, verbs 60s, setup unbounded but cancellable); a timeout shows as an error row. |
| `schema` newer than the app knows | Menu shows "Update Share Bar" and still renders fields it can decode. |
| CLI too old for `--json` (exit non-zero, no JSON) | Menu shows "Update share CLI" with the brew command. |
| Verb fails (`rm` on a gone id, setup error) | The CLI's stderr last line is shown in an alert. |
| Large access log | Hits run only when a share's submenu opens, off the main thread. |

## Design

### Diagram

ASCII by house rule (no Mermaid).

```
 ┌─────────────── Share Bar.app ───────────────┐        ┌──────── share CLI ────────┐
 │ NSStatusItem ── menuNeedsUpdate ──┐          │  spawn │ status --json  (read only) │
 │   drop target ──┐                 ▼          │ ─────▶ │ add / rm / refresh / hits  │
 │ setup window ─┐ │         ShareBarCore       │        │ start / stop / setup       │
 │               └─┴──────▶ CLI.run + decode ───┼──────▶ └─────────────┬─────────────┘
 └──────────────────────────────────────────────┘                      │ owns
                                                         ~/share, ~/.config/share,
                                                         launchd foundation.d.share
```

### ADR link(s)

- `docs/decisions/ADR-0003-menu-bar-reads-through-cli.md`
