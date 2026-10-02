# Goofy (ngosangns fork)

Desktop Facebook Messenger for macOS — a lightweight native `WKWebView` shell (not Electron).

**This repository is a fork of [danielbuechele/goofy](https://github.com/danielbuechele/goofy)** maintained at [ngosangns/goofy](https://github.com/ngosangns/goofy).

Display name and bundle id stay **`Goofy` / `cc.buechele.Goofy`** so replacing `/Applications/Goofy.app` keeps Dock identity, cookies, and preferences compatible with upstream installs.

See **[PLAN.md](./PLAN.md)** for the optimization roadmap and checklist.

## Features vs upstream

Everything upstream has, plus (this fork):

| Area | Fork additions |
|------|----------------|
| Perf | Debounced badge/message observers; pause work when app is backgrounded; soft-reload on wake/network (skips if you were just typing); dynamic Safari user-agent; system light/dark window chrome |
| Notifications | Suppress banner when the window is key on the same thread; modes Banner / Badge-only / Off; optional hide message preview |
| Keyboard | `⌘1`–`⌘9` jump conversations; `⌘[` / `⌘]` previous/next |
| Window | Always on Top; menu bar status item with unread count; `⌘⇧Y` show/hide; optional Hide Dock (quit from menu bar) |
| Focus / privacy | Chat-only CSS mode; unwrap `l.facebook.com` tracking redirects; optional block typing / seen (off by default, experimental) |
| Updates | Auto-updater points at **ngosangns/goofy** (not upstream), so upstream releases do not overwrite this fork |

## Installation (this fork)

Build from source (Release) or copy a Release build to `/Applications/Goofy.app`.

```bash
xcodebuild -project goofy.xcodeproj -scheme goofy -configuration Release \
  -derivedDataPath /tmp/goofy-build clean build \
  CODE_SIGN_IDENTITY="-" CODE_SIGNING_ALLOWED=YES
```

Then replace `/Applications/Goofy.app` with the built product (quit Goofy first).

Upstream binary releases: [danielbuechele/goofy releases](https://github.com/danielbuechele/goofy/releases/latest).

## Syncing upstream

```bash
git fetch upstream
git merge upstream/main
```

## Questions

### Is Goofy an Electron app?
No — native macOS WebKit via Swift. Smaller and lighter than Electron wrappers.

### Can Goofy access my Facebook data?
It injects a small script for notifications and badge counting. Source is open; no telemetry is collected. Settings live in `UserDefaults` under `goofy.*` keys.

### Hide Dock icon
Enable **Goofy → Hide Dock Icon** (also turns on the menu bar icon if needed). Quit from the status menu or **Quit Goofy**.

### Block typing / seen
Optional and brittle (Facebook DOM/API changes often). Default **off**. Use at your own risk.
