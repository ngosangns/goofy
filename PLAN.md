# Goofy fork — kế hoạch tối ưu

Fork: https://github.com/ngosangns/goofy  
Upstream: https://github.com/danielbuechele/goofy  
Local: `~/Github/ngosangns/goofy`

Mục tiêu: giữ shell WKWebView nhẹ, thêm tối ưu pin/UX/privacy theo từng phase. Không rewrite Electron.

## Nguyên tắc

- Mỗi phase 1 branch + 1 PR nhỏ, build/chạy được trên Mac.
- Ưu tiên thay đổi ít đụng DOM Meta; selector FB dễ gãy → luôn có fallback.
- Không thu thập telemetry; Settings lưu `UserDefaults`.
- Sync upstream định kỳ: `git fetch upstream && git merge upstream/main`.

---

## Phase 0 — Nền tảng fork (½ ngày)

- [x] Đổi display name / bundle id nếu muốn tách app khỏi upstream (vd. `vn.sang.goofy` hoặc giữ Goofy khi dev). → **Kept** `Goofy` / `cc.buechele.Goofy`.
- [x] README fork: ghi rõ khác gì upstream + link PLAN.
- [x] Xcode scheme chạy Debug ổn; script build/notarize giữ nguyên hoặc document.
- [x] Branch strategy: `main` = ổn định; feature branches `feat/...` (this work on `feat/optimizations`).

**Done when:** mở Xcode → Run → login Messenger bình thường.

---

## Phase 1 — Hiệu năng / pin (1–2 ngày) ⭐ làm trước

**Status: done** (on `feat/optimizations`)

Branch: `feat/perf-throttle`

| # | Việc | File chính | Ghi chú |
|---|------|------------|---------|
| 1.1 | Debounce `checkForNewMessages` + `updateBadgeCount` 250–500ms | `content.js` | Giảm spam MutationObserver |
| 1.2 | Selector resilient: ưu tiên `aria-*` / `[role]` trước class hash `.x…` | `content.js` | Giữ class hash làm fallback |
| 1.3 | Soft-reload: wake/network chỉ `reload()` nếu idle ≥ N phút hoặc document ẩn lỗi | `ViewController.swift` | Tránh full reload khi vừa chat |
| 1.4 | Throttle khi nền: tạm pause observer / giảm polling khi `didResignActive` | `content.js` + Swift bridge | Message `appState: background\|foreground` |
| 1.5 | User-Agent Safari động (version thật) | `ViewController.swift`, `SafariLoginController.swift` | Bỏ cứng `Version/17.0` |
| 1.6 | Dark/light: `window.backgroundColor` theo `effectiveAppearance` | `ViewController.swift` | Observe `NSApp` appearance |

**Done when:** Activity Monitor idle nền thấp hơn baseline; wake không làm mất draft cảm nhận; dark mode cửa sổ khớp hệ thống.

---

## Phase 2 — Noti thông minh + keyboard (2–3 ngày)

**Status: done** (mute-from-noti skipped as nice-to-have)

Branch: `feat/noti-keyboard`

| # | Việc | File chính |
|---|------|------------|
| 2.1 | Không hiện banner nếu window key + đang đúng thread | `ViewController.swift` (`willPresent`) |
| 2.2 | Settings: Off / Banner / Badge-only; Hide message preview | Settings UI + UserDefaults |
| 2.3 | `⌘1`–`⌘9` nhảy hội thoại; `⌘[` / `⌘]` prev/next | Menu + `content.js` |
| 2.4 | Always on Top toggle | `AppDelegate` / Window menu |
| 2.5 | Mute thread từ noti actions (optional) | UNNotificationCategory |

**Done when:** chat đang mở không spam banner; nhảy thread bằng phím ổn định.

---

## Phase 3 — Menu bar + tray UX (2 ngày)

**Status: done**

Branch: `feat/menu-bar`

| # | Việc |
|---|------|
| 3.1 | Status item unread badge / chấm đỏ |
| 3.2 | Click icon → show/hide cửa sổ; global hotkey show (vd. `⌘⇧Y`) |
| 3.3 | Option: Hide Dock icon khi dùng menu bar (như Caprine) |
| 3.4 | Quit chỉ từ menu “Quit Goofy” |

**Done when:** đóng cửa sổ vẫn chạy; menu bar phản ánh unread.

---

## Phase 4 — Chat-only + privacy (2–3 ngày)

**Status: done**

Branch: `feat/focus-privacy`

| # | Việc |
|---|------|
| 4.1 | CSS/JS mạnh hơn: ẩn chrome ngoài messages (Feed/Reels hints) | `style.css` |
| 4.2 | Strip `l.facebook.com` / tracking redirects khi mở link ngoài | navigation delegate |
| 4.3 | Toggle block typing indicator / seen (inject + preference) | Caprine-style, brittle |
| 4.4 | Whitelist navigation tinh: calls, attachment, blob download không bị cancel nhầm | `decidePolicyFor` |

**Done when:** cửa sổ cảm giác “chỉ chat”; link ngoài không qua redirect tracker (best-effort).

---

## Phase 5 — Polish sản phẩm (backlog)

- Share Extension “Send to Messenger” (cần App Group + extension target).
- Nhiều cửa sổ thread (phức tạp với 1 WKWebView).
- Spotlight / search tin nhắn offline (không khả thi tốt khi chỉ wrap web).
- Continuity / Handoff (ưu tiên thấp).
- CI: `xcodebuild` trên GitHub Actions macOS runner.

---

## Thứ tự đề xuất

```
Phase 0 → Phase 1 → Phase 2 → Phase 3 → Phase 4 → Phase 5
         (ROI cao)   (UX rõ)    (Mac-feel) (khác biệt)
```

Ước lượng tổng Phase 0–4: ~8–12 ngày làm part-time nếu một người.

## Rủi ro

- DOM Facebook đổi → gãy badge/noti/selector → cần monitor + fallback nhanh.
- Block typing/seen có thể vi phạm ToS cảm nhận / dễ break → làm optional, mặc định off.
- Hide Dock + menu bar cần test carefully với `LSUIElement` / activation policy.
- Notarize/signing: fork cần Apple ID + cert riêng nếu phân phối ngoài máy bạn.

## Metric thành công (Phase 1–2)

- RAM idle (đã login, 1 cửa sổ) không tăng so upstream ±10%.
- CPU nền ≤ vài % khi không có tin mới (sau debounce).
- Noti: 0 banner khi đang xem đúng thread; badge vẫn đúng.
- Keyboard jump hoạt động với ≥ 9 thread đầu trong list.


---

## Phase 6 — Speed trim (aggressive) ⭐

**Status: done** (branch `feat/speed-trim`)

Goal: drop features that do not help speed; cut CPU/RAM/battery hotspots.

| # | Việc | Kết quả |
|---|------|---------|
| 6.1 | Remove Always on Top, Hide Dock, global ⌘⇧Y hotkey | No continuous global event monitor |
| 6.2 | Menu bar default OFF | Status item not on hot path |
| 6.3 | Remove chat-only CSS mode + block typing/seen | No fetch hooks / extra CSS class work |
| 6.4 | Delay AppUpdater 5 min; drop launch noti auth duplicate | Less launch network/CPU |
| 6.5 | JS: no postToNative logs; skip unchanged badge/currentThread | Less WK bridge IPC |
| 6.6 | Observer removal watch scoped to parent (not body subtree) | Big MutationObserver CPU win |
| 6.7 | Soft-reload idle 30 min + 10 min anti-storm; debounce network 3s | Fewer full reloads |
| 6.8 | Pause observers on window hide + visibilitychange | Idle when closed-to-tray |
| 6.9 | `developerExtras` / `isInspectable` Debug-only; `drawsBackground=false` | Release leaner |
| 6.10 | Drop `getComputedStyle` unread heuristic | Avoid forced layout |

**Done when:** Release build installs; core login/webview/badge/links work; idle CPU lower than Phase 4.

## Speed-trim-2 (post PR #3)

### Implemented
- Defer AppUpdater Combine subscribe + check (lazy; manual Check for Updates still works)
- WKWebView: `mediaTypesRequiringUserActionForPlayback = .all`, AirPlay off
- Skip `getAllCookies` after first successful auth
- Wake soft-reload short-circuit when authenticated + not idle enough
- Network monitor utility QoS; Release silences hot-path `print`
- Defer notification authorization ~2s off cold launch
- Cache Safari UA string
- JS: only walk snippet/name DOM for unread+unmuted rows; observer retry 8s
- CSS: `@media (prefers-reduced-motion: reduce)` animation/transition kill

### Skipped (not safe / low confidence)
- Content Blocker / fbcdn pixel blocking — media + stickers share hosts
- Always-on animation kill (UX); empty toolbar removal (traffic lights)
- Custom WKProcessPool (single webview; default fine)
- Aggressive resource-load cancel via WKNavigationDelegate (breaks FB CDN)

### Measure
- Instruments Time Profiler + Allocations on idle 5 min; Activity Monitor CPU/Energy while scrolled + backgrounded

## Speed-trim-3 (post PR #4)

**Status: done** (branch `feat/speed-trim-3`)

| # | Việc | Kết quả |
|---|------|---------|
| 7.1 | Narrow MutationObserver | Grid: childList without deep subtree + attributeFilter on aria/class for unread |
| 7.2 | Skip badge NotificationCenter | `updateBadge` posts `.goofyBadgeDidChange` only if menu bar enabled |
| 7.3 | App Nap timers | 3h reload `timer.tolerance`; interaction monitor only while `reloadPending` |
| 7.4 | Release LTO/strip | `LLVM_LTO=YES`, `COPY_PHASE_STRIP=YES`, `DEPLOYMENT_POSTPROCESSING=YES`, `SWIFT_OPTIMIZATION_LEVEL=-O` |
| 7.5 | Force reduce motion | Setting + menu (default **OFF**); CSS class kills animations regardless of system pref |
| 7.6 | Curated WKContentRuleList | Block `pixel.facebook.com`, `facebook.com/tr`, `fbevents`; do **not** block fbcdn/fbsbx |
| 7.7 | Suspend when hidden | Opt-in (default **OFF**): pause media + `webView.isHidden`; cookies/session kept |
| 7.8 | Defer first `loadMessenger` | Moved to `viewDidAppear` |
| 7.9 | Deeper `isPageLikelyBroken` | Wake skip runs readyState / `[role=navigation]` JS probe first |

### Defaults (risky flags)
- Menu bar: **OFF**
- Force reduce motion: **OFF**
- Suspend when hidden: **OFF**

---

## Phase warm-ux — speed/UX over idle CPU

**Status: done** (branch `feat/warm-ux`, v4.0.158)

Priority: snappy badge/noti + restored UX; user accepts higher RAM / background CPU vs aggressive idle pause.

| # | Việc | Kết quả |
|---|------|---------|
| W.1 | Warm badge/observers | Do **not** pause MutationObservers or skip badge/noti just because `appState === background`. Pause only when native `suspendWhenHidden` → `setSuspended(true)` |
| W.2 | Native resign/hide | `didResignActive` / `notifyWindowVisibility(false)` only apply pauseMedia + `webView.isHidden` (+ JS suspend) when suspendWhenHidden is ON |
| W.3 | Foreground debounce | ~250ms (was 400); resume catch-up stays ~200ms |
| W.4 | Media | `mediaTypesRequiringUserActionForPlayback = .video` (audio/voice OK); AirPlay off |
| W.5 | Always on Top | UserDefaults + menu/prefs toggle; window `.floating` level |
| W.6 | Global ⌘⇧Y | Local + global key monitors show/hide window (Accessibility may be required for global) |
| W.7 | Menu bar | Default still OFF; Dock badge always updated |

### Defaults
- Menu bar: **OFF**
- Always on Top: **OFF**
- Force reduce motion: **OFF**
- Suspend when hidden: **OFF**

## Phase smooth-cache — fluid UX / large cache (v4.0.159)

**Status: done** (branch `feat/smooth-cache`)

Priority: perceived smoothness (scroll, thread switch, reopen, media). User accepts high RAM.

| # | Việc | Kết quả |
|---|------|---------|
| S.1 | Large shared `URLCache` | **512 MB** memory + **2 GB** disk under Caches/GoofyURLCache |
| S.2 | WK config | `websiteDataStore.default`, shared `WKProcessPool`, `suppressesIncrementalRendering=false` |
| S.3 | Force-cache friendly load | Initial `URLRequest` `.returnCacheDataElseLoad`; soft-reload less aggressive |
| S.4 | Soft-reload | Idle **45 min**; anti-storm **15 min**; wake/network reload **only if broken** when authenticated |
| S.5 | Prewarm | `loadMessenger` in `viewDidLoad` (not deferred to appear) |
| S.6 | Keep warm | `goofy.keepProcessWarm` default **ON** — `NSActivity` userInitiatedAllowingIdleSystemSleep |
| S.7 | Badge IPC | 50ms coalesce; skip `.goofyBadgeDidChange` when menu bar off |
| S.8 | CSS/JS | Compositing-friendly font smoothing; async `img.decoding`; rAF-batched checks; forceReduceMotion still OFF |
| S.9 | Window close | `orderOut` keeps WKWebView in hierarchy; no aggressive website-data clear |

### New UserDefaults
- `goofy.keepProcessWarm` — Bool, **default ON**

### Cache sizes (hardcoded, not UserDefaults)
- Memory: 512 MB (`GoofySettings.urlCacheMemoryCapacity`)
- Disk: 2 GB (`GoofySettings.urlCacheDiskCapacity`)

### Defaults
- Menu bar: **OFF**
- Always on Top: **OFF**
- Force reduce motion: **OFF**
- Suspend when hidden: **OFF**
- Keep process warm: **ON**

### Risks
- Higher RAM / disk cache footprint (intentional).
- `returnCacheDataElseLoad` may briefly show a stale Messenger shell until soft-reload/broken probe; wake no longer idle-reloads when healthy.
- `WKProcessPool` may warn deprecated on newest SDKs (harmless; process sharing still OK).
- Keep-warm NSActivity reduces App Nap savings (battery tradeoff).

---

## Phase upstream-ports — recommended upstream fixes (v4.0.160)

**Status: done** (branch `feat/upstream-ports`)

Port of recommended items from upstream issues/PRs into this fork only (never push to danielbuechele).

| # | Việc | Kết quả |
|---|------|---------|
| U.1 | Keep-alive (#524 style) | Native `Timer` → `evaluateJS __GOOFY.keepAlive` every ~15s while window hidden and `suspendWhenHidden` OFF; ~60s when visible; disabled when suspend ON |
| U.2 | i18n own-snippet (#519) | Expanded `IGNORED_SNIPPET_PREFIXES` + `OWN_SNIPPET_REGEX` (You/Ty/Bạn/Du/Tu/Vous/…) via `isOwnSnippet` |
| U.3 | Now Playing (#521) | Clear `MPNowPlayingInfoCenter` + page `mediaSession` when no real audio/video; ignore short noti pings |
| U.4 | Image save (#508) | `shouldPerformDownload`, `navigationResponse` → download, sheet `NSSavePanel`, context-menu **Save Image…** via URLSession |
| U.5 | Reopen harden (#520) | Retain main window, `isReleasedWhenClosed=false`, deminiaturize before orderOut, off-screen frame repair, `orderFrontRegardless` fallback |

### Defaults
- Keep-alive: active when hidden + suspend OFF (no new UserDefaults)
- Suspend when hidden: still **OFF**
