window.__GOOFY = {
  ALT_TEXT_TO_EMOJI: {
    "(Y)": "👍",
    "❤": "❤️",
  },

  IGNORED_SNIPPET_PREFIXES: ["You sent an attachment.", "You: "],

  threadSnapshots: null,
  appState: "foreground",
  _debounceTimers: {},
  _observersPaused: false,
  _activeObservers: [],
  _lastCurrentThreadKey: undefined,
  _lastBadgeCount: -1,
  _mediaDecorateBusy: false,
  _debug: false,

  postToNative: function (message) {
    if (
      window.webkit &&
      window.webkit.messageHandlers &&
      window.webkit.messageHandlers.goofy
    ) {
      window.webkit.messageHandlers.goofy.postMessage(message);
    }
  },

  getTextWithImageAlts: function (element) {
    if (!element) return "";

    let result = "";
    for (const node of element.childNodes) {
      if (node.nodeType === Node.TEXT_NODE) {
        result += node.textContent;
      } else if (node.nodeType === Node.ELEMENT_NODE) {
        if (node.classList && node.classList.contains("x1i1rx1s")) continue;
        if (node.tagName === "IMG") {
          const alt = node.alt || "";
          result += this.ALT_TEXT_TO_EMOJI[alt] || alt;
        } else {
          result += this.getTextWithImageAlts(node);
        }
      }
    }
    return result;
  },

  // Local console only — never bridge to native (was a hot-path IPC storm).
  log: function (message) {
    if (!this._debug) return;
    console.log(`[Goofy] ${message}`);
  },

  debounce: function (key, fn, waitMs) {
    if (this._debounceTimers[key]) {
      clearTimeout(this._debounceTimers[key]);
    }
    this._debounceTimers[key] = setTimeout(() => {
      delete this._debounceTimers[key];
      fn();
    }, waitMs);
  },

  debounceMs: function () {
    // Warm UX: keep badge/noti snappy in foreground; slightly longer when
    // backgrounded (observers stay live unless suspended).
    return this.appState === "background" ? 800 : 250;
  },

  // --- Resilient selectors (aria/role first, class-hash fallback) ---

  getThreadLinks: function () {
    return Array.from(
      document.querySelectorAll('[role="navigation"] [role="row"] a[href*="/messages/"]'),
    );
  },

  getThreadName: function (anchor) {
    const aria =
      anchor.getAttribute("aria-label") ||
      anchor.closest('[role="row"]')?.getAttribute("aria-label");
    if (aria) {
      const name = aria.split(/[,.]/)[0]?.trim();
      if (name && name.length < 80) return name;
    }
    const span =
      anchor.querySelector('span[dir="auto"]') ||
      anchor.querySelector("span.xlyipyv") ||
      anchor.querySelector("span");
    return span?.textContent?.trim() || null;
  },

  getSnippetElement: function (anchor) {
    const candidates = anchor.querySelectorAll(
      'div[dir="auto"] span, span[dir="auto"], div.xi81zsa span',
    );
    if (candidates.length > 0) {
      return candidates[candidates.length - 1];
    }
    return null;
  },

  isUnreadThread: function (anchor) {
    // Prefer cheap DOM attribute checks — avoid getComputedStyle (forces layout).
    if (
      anchor.querySelector(
        '[role="button"] [aria-label*="unread" i], [role="button"] [aria-label*="Unread"], [role="status"]',
      )
    ) {
      return true;
    }
    if (anchor.querySelector('[role="button"] .x1spa7qu')) return true;
    return false;
  },

  isMutedThread: function (anchor) {
    if (
      anchor.querySelector(
        'svg[aria-label*="mute" i], svg[aria-label*="Mute"], [aria-label*="muted" i]',
      )
    ) {
      return true;
    }
    return !!anchor.querySelector("svg.x14rh7hd");
  },

  // --- Observer ---

  observe: function (selector, callback, options = {}) {
    const {
      subtree = true,
      childList = true,
      characterData = false,
      attributes = false,
      attributeFilter = undefined,
      retryInterval = 8000,
      onSetup = null,
      onRemove = null,
    } = options;

    let contentObserver = null;
    let removalObserver = null;
    let disposed = false;
    let retryTimer = null;
    const self = this;

    const handle = {
      disconnect: function () {
        disposed = true;
        if (retryTimer) clearTimeout(retryTimer);
        contentObserver?.disconnect();
        removalObserver?.disconnect();
      },
      pause: function () {
        if (retryTimer) {
          clearTimeout(retryTimer);
          retryTimer = null;
        }
        contentObserver?.disconnect();
        removalObserver?.disconnect();
      },
      resume: function () {
        if (!disposed) setup();
      },
    };

    const setup = () => {
      if (disposed || self._observersPaused) return;
      const element = document.querySelector(selector);
      if (!element) {
        self.log(`observe(${selector}): not found, retrying`);
        retryTimer = setTimeout(setup, retryInterval);
        return;
      }

      self.log(`observe(${selector}): attached`);
      if (onSetup) onSetup(element);

      contentObserver?.disconnect();
      contentObserver = new MutationObserver(() => {
        if (!self._observersPaused) callback(element);
      });
      const obsOpts = { subtree, childList, characterData, attributes };
      if (attributes && attributeFilter && attributeFilter.length) {
        obsOpts.attributeFilter = attributeFilter;
      }
      contentObserver.observe(element, obsOpts);

      // Scope removal watch to the parent only — never document.body subtree
      // (that was a major CPU hotspot on Messenger's busy DOM).
      removalObserver?.disconnect();
      const parent = element.parentNode;
      if (parent) {
        removalObserver = new MutationObserver(() => {
          if (!document.contains(element)) {
            self.log(`observe(${selector}): removed, re-attaching`);
            contentObserver?.disconnect();
            removalObserver?.disconnect();
            if (onRemove) onRemove();
            setup();
          }
        });
        removalObserver.observe(parent, { childList: true, subtree: false });
      }
    };

    setup();
    this._activeObservers.push(handle);
    return handle;
  },

  // App foreground/background — does NOT pause observers (warm badge/noti).
  // Observers pause only via setSuspended(true) when native suspendWhenHidden is ON.
  setAppState: function (state) {
    const next = state === "background" ? "background" : "foreground";
    if (this.appState === next) return;
    this.appState = next;
    this.log(`appState -> ${next}`);

    if (next === "foreground" && !this._observersPaused) {
      this.debounce(
        "messages",
        () => {
          this.checkForNewMessages();
          this.updateBadgeCount();
        },
        200,
      );
    }
  },

  // Native calls this only when suspendWhenHidden is enabled.
  setSuspended: function (suspended) {
    const next = !!suspended;
    if (this._observersPaused === next) return;
    this._observersPaused = next;
    this.log(`suspended -> ${next}`);

    if (next) {
      Object.keys(this._debounceTimers).forEach((k) => {
        clearTimeout(this._debounceTimers[k]);
        delete this._debounceTimers[k];
      });
      this._activeObservers.forEach((o) => o.pause && o.pause());
    } else {
      this._activeObservers.forEach((o) => o.resume && o.resume());
      this.debounce(
        "messages",
        () => {
          this.checkForNewMessages();
          this.updateBadgeCount();
        },
        200,
      );
    }
  },

  setForceReduceMotion: function (enabled) {
    try {
      document.documentElement.classList.toggle("goofy-force-reduce-motion", !!enabled);
    } catch (_) {}
  },

  // Pause in-page media without touching storage/cookies (used when suspend-when-hidden is on).
  pauseMedia: function () {
    try {
      document.querySelectorAll("video, audio").forEach((el) => {
        try {
          el.pause();
        } catch (_) {}
      });
    } catch (_) {}
  },

  // Used by native soft-reload health probe.
  isPageLikelyBroken: function () {
    try {
      if (!document.body || document.body.childElementCount === 0) return true;
      if (document.readyState === "loading") return true;
      if (!document.querySelector('[role="navigation"]')) return true;
      return false;
    } catch (_) {
      return true;
    }
  },

  // --- Badge count ---

  updateBadgeCount: function () {
    // Keep counting while backgrounded so Dock badge/noti stay warm.
    const firstTab = document.querySelector('[role="tablist"] [role="tab"]');
    if (firstTab?.getAttribute("aria-selected") !== "true") return;

    let unreadDots = document.querySelectorAll(
      '[role="navigation"] [role="row"] [role="button"] [aria-label*="unread" i], [role="navigation"] [role="row"] [role="status"]',
    );
    if (unreadDots.length === 0) {
      unreadDots = document.querySelectorAll(
        '[role="navigation"] [role="row"] [role="button"] .x1spa7qu',
      );
    }

    let count = unreadDots.length;
    if (count === 0) {
      // Cheap fallback — no getComputedStyle
      count = this.getThreadLinks().filter((a) => this.isUnreadThread(a)).length;
    }

    if (count === this._lastBadgeCount) return;
    this._lastBadgeCount = count;
    this.postToNative({ type: "badge", count });
  },

  // --- Current thread ---

  getCurrentThreadKey: function () {
    try {
      const path = window.location.pathname || "";
      const match = path.match(/\/messages\/(?:t|e)\/([^/]+)/);
      if (match) {
        return window.location.pathname + (window.location.search || "");
      }
      const selected =
        document.querySelector('[role="navigation"] [role="row"][aria-selected="true"] a') ||
        document.querySelector('[role="navigation"] a[aria-current="page"]');
      if (selected) return selected.getAttribute("href");
    } catch (_) {}
    return null;
  },

  publishCurrentThread: function (currentKey) {
    if (currentKey === this._lastCurrentThreadKey) return;
    this._lastCurrentThreadKey = currentKey;
    this.postToNative({
      type: "currentThread",
      threadKey: currentKey,
    });
  },

  // --- New message detection ---

  checkForNewMessages: function () {
    // Keep scanning while backgrounded so notifications stay warm.
    const links = this.getThreadLinks();
    let firstRun = false;
    if (links.length > 0 && this.threadSnapshots == null) {
      this.threadSnapshots = new Map();
      firstRun = true;
    }

    const currentKey = this.getCurrentThreadKey();

    links.forEach((a, index) => {
      const threadKey = a.getAttribute("href");
      if (!threadKey) return;

      // Cheap flags first — avoid snippet/name DOM walks for read/muted rows.
      const isUnread = this.isUnreadThread(a);
      const isMuted = this.isMutedThread(a);
      const prev = this.threadSnapshots.get(threadKey);

      let snippet = prev ? prev.snippet || "" : "";
      let threadName = prev ? prev.threadName || null : null;

      let shouldNotify = false;
      if (isUnread && !isMuted) {
        // Only walk snippet DOM when unread+unmuted (notify candidates).
        snippet = this.getTextWithImageAlts(this.getSnippetElement(a));
        if (prev) {
          if (!prev.isUnread) {
            shouldNotify = true;
          } else if (snippet !== prev.snippet) {
            shouldNotify = true;
          }
        } else if (index === 0 && !firstRun) {
          shouldNotify = true;
        }
      }

      if (shouldNotify) {
        threadName = this.getThreadName(a);
        const hasIgnoredPrefix = this.IGNORED_SNIPPET_PREFIXES.some((prefix) =>
          (snippet || "").startsWith(prefix),
        );
        if (!hasIgnoredPrefix) {
          this.postToNative({
            type: "notification",
            title: threadName || "Messenger",
            body: snippet || "",
            threadKey,
            currentThreadKey: currentKey,
          });
        }
      }

      this.threadSnapshots.set(threadKey, {
        threadKey,
        threadName,
        snippet,
        isUnread,
        isMuted,
        position: index,
      });
    });

    this.publishCurrentThread(currentKey);
  },

  // --- Actions called from Swift ---

  navigateToThread: function (threadKey) {
    const link = document.querySelector(`a[href="${threadKey}"]`);
    if (link) {
      link.click();
    } else {
      window.location.href = threadKey;
    }
  },

  jumpToThread: function (index) {
    const links = this.getThreadLinks();
    if (index >= 0 && index < links.length) {
      links[index].click();
    }
  },

  prevThread: function () {
    const links = this.getThreadLinks();
    if (links.length === 0) return;
    const current = this.getCurrentThreadKey();
    let idx = links.findIndex((a) => a.getAttribute("href") === current);
    if (idx < 0) {
      const path = window.location.pathname;
      idx = links.findIndex((a) => {
        const href = a.getAttribute("href") || "";
        return path.includes(href.replace(/\/$/, "")) || href.includes(path);
      });
    }
    const next = idx <= 0 ? links.length - 1 : idx - 1;
    links[next].click();
  },

  nextThread: function () {
    const links = this.getThreadLinks();
    if (links.length === 0) return;
    const current = this.getCurrentThreadKey();
    let idx = links.findIndex((a) => a.getAttribute("href") === current);
    if (idx < 0) {
      const path = window.location.pathname;
      idx = links.findIndex((a) => {
        const href = a.getAttribute("href") || "";
        return path.includes(href.replace(/\/$/, "")) || href.includes(path);
      });
    }
    const next = idx < 0 || idx >= links.length - 1 ? 0 : idx + 1;
    links[next].click();
  },

  newMessage: function () {
    const link = document.querySelector('a[href="/messages/new/"]');
    if (link) {
      link.click();
    } else {
      window.location.href = "/messages/new/";
    }
  },

  focusSearch: function () {
    const input = document.querySelector(
      '[role="navigation"] input[type="search"], [role="navigation"] input[aria-label*="Search" i]',
    );
    if (input) {
      input.click();
      input.focus();
    }
  },

  scheduleMessageCheck: function () {
    this.debounce(
      "messages",
      () => {
        // One rAF so badge + thread IPC land in the same frame (less main-thread churn).
        requestAnimationFrame(() => {
          this.checkForNewMessages();
          this.updateBadgeCount();
          this.decorateMediaLazy();
        });
      },
      this.debounceMs(),
    );
  },

  // Hint async image decode — avoid layout thrash; no getComputedStyle.
  decorateMediaLazy: function () {
    if (this._mediaDecorateBusy) return;
    this._mediaDecorateBusy = true;
    try {
      const imgs = document.querySelectorAll("img:not([data-goofy-decode])");
      const limit = Math.min(imgs.length, 40);
      for (let i = 0; i < limit; i++) {
        const img = imgs[i];
        img.setAttribute("data-goofy-decode", "1");
        if (!img.getAttribute("decoding")) img.decoding = "async";
      }
    } catch (_) {
    } finally {
      this._mediaDecorateBusy = false;
    }
  },

  // --- Init ---

  init: function () {
    this.log("Initializing Goofy");

    const gridSelector = '[role="navigation"] [role="grid"]';
    const onRemove = () => {
      this.threadSnapshots = null;
      this._lastBadgeCount = -1;
    };

    // Narrow MutationObserver vs prior whole-grid subtree childList storm:
    // 1) Structural: direct children of the grid only (row add/remove/reorder).
    // 2) Status: deep attributeFilter on unread/selection aria — no childList.
    this.observe(
      gridSelector,
      () => this.scheduleMessageCheck(),
      {
        subtree: false,
        childList: true,
        attributes: false,
        characterData: false,
        onSetup: () => this.updateBadgeCount(),
        onRemove,
      },
    );

    this.observe(
      gridSelector,
      () => this.scheduleMessageCheck(),
      {
        subtree: true,
        childList: false,
        attributes: true,
        attributeFilter: ["aria-label", "aria-selected", "aria-current", "class"],
        characterData: false,
        onRemove,
      },
    );

    // Track visibility for debounce timing only — do not pause observers here.
    // Native suspendWhenHidden drives setSuspended via pauseMedia/hide path.
    document.addEventListener("visibilitychange", () => {
      if (document.hidden) {
        this.setAppState("background");
      } else if (this.appState === "background") {
        this.setAppState("foreground");
      }
    });

    // One-shot media decorate after first paint (does not pause observers).
    requestAnimationFrame(() => this.decorateMediaLazy());
  },
};

window.__GOOFY.init();
