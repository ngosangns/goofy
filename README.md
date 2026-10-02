# Goofy (ngosangns fork)

Desktop Facebook Messenger for macOS — a lightweight native `WKWebView` shell (not Electron).

**This repository is a fork of [danielbuechele/goofy](https://github.com/danielbuechele/goofy)** maintained at [ngosangns/goofy](https://github.com/ngosangns/goofy).

Display name and bundle id stay **`Goofy` / `cc.buechele.Goofy`** so replacing `/Applications/Goofy.app` keeps Dock identity, cookies, and preferences compatible with upstream installs.

See **[PLAN.md](./PLAN.md)** for the optimization roadmap and checklist.

## Features vs upstream

Everything upstream has, plus (this fork) — **speed-first**:

| Area | Fork additions |
|------|----------------|
| Perf | Debounced + narrowed observers; soft-reload + wake health probe; App Nap-friendly timers; optional force reduce-motion / suspend-when-hidden (default off); tracker content rules; Release LTO/strip; delayed updater |
| Smooth cache | 512MB/2GB `URLCache`; cache-friendly Messenger load; wake/network reload only if broken; `loadMessenger` on `viewDidLoad`; keep-process-warm (default ON); coalesced badge IPC |
| Upstream ports (4.0.160) | Hidden-window keep-alive; i18n own-snippet ignore; Now Playing clear for noti pings; Save Image… context menu; reopen harden after close/minimize |
| Warm UX | Badge/noti observers stay live while backgrounded (unless Suspend When Hidden); Dock badge trusted with menu bar off; video-only media gesture gate (audio/voice OK); Always on Top + global `⌘⇧Y` show/hide |
| Notifications | Suppress banner when the window is key on the same thread; modes Banner / Badge-only / Off; optional hide message preview |
| Keyboard | `⌘1`–`⌘9` jump conversations; `⌘[` / `⌘]` previous/next; `⌘⇧Y` show/hide window |
| Window | Always on Top; optional menu bar status item (**off by default**) |
| Links | Unwrap `l.facebook.com` tracking redirects |
| Updates | Auto-updater points at **ngosangns/goofy** (checks ~5 min after launch, or via Check for Updates) |

**Phase warm-ux + smooth-cache:** priority speed/UX over idle CPU (user accepts higher RAM / larger disk cache). Not carried: Hide Dock, chat-only CSS mode, block typing/seen inject.

## Installation (this fork)

Build from source (Release) or copy a Release build to `/Applications/Goofy.app`.

```bash
xcodebuild -project goofy.xcodeproj -scheme goofy -configuration Release \
  -derivedDataPath /tmp/goofy-build clean build \
  CODE_SIGN_IDENTITY="-" CODE_SIGNING_ALLOWED=YES
```

Then replace `/Applications/Goofy.app` with the built product (quit Goofy first).

Upstream binary releases: [danielbuechele/goofy releases](https://github.com/danielbuechele/goofy/releases/latest).

## Releases (this fork)

Installed copies of this fork check [ngosangns/goofy releases](https://github.com/ngosangns/goofy/releases). AppUpdater looks for a published release (not a draft or prerelease) tagged `MAJOR.MINOR.PATCH` with an asset named `Goofy-<version>.zip`.

```bash
bash scripts/increment_build.sh   # prints: Build NNN, version X.Y.Z
git add goofy.xcodeproj/project.pbxproj
git commit -m "vX.Y.Z"
git tag X.Y.Z
git push origin HEAD
git push origin X.Y.Z
```

Pushing the tag runs the Release workflow. A `vX.Y.Z` tag is accepted and published as `X.Y.Z`, which is the form AppUpdater parses. You can also run the workflow by hand (Actions → Release) and pass a version.

With no Apple secrets, CI uploads an ad-hoc zip. Gatekeeper may block it. AppUpdater installs an update when both copies share a Developer ID authority, so an ad-hoc zip is a manual download. Secret names and the notarized path are in [docs/RELEASE.md](docs/RELEASE.md).

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

### Menu bar icon
Off by default. Enable via **Goofy → Menu Bar Icon** or Preferences.

### Keep process warm
On by default (`goofy.keepProcessWarm`). Holds an `NSActivity` so App Nap does not starve WebKit while the window is hidden — smoother reopen at a small battery cost. Toggle via **Goofy → Keep Process Warm**.
