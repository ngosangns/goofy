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
    // Longer debounce while backgrounded (observers should already be paused;
    // this covers residual/resume catch-up).
    return this.appState === "background" ? 1200 : 400;
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
      retryInterval = 5000,
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
      contentObserver.observe(element, { subtree, childList, characterData });

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

  setAppState: function (state) {
    const next = state === "background" ? "background" : "foreground";
    if (this.appState === next) return;
    this.appState = next;
    this.log(`appState -> ${next}`);

    if (next === "background") {
      this._observersPaused = true;
      // Clear pending debounces so background catch-up doesn't fire from stale work
      Object.keys(this._debounceTimers).forEach((k) => {
        clearTimeout(this._debounceTimers[k]);
        delete this._debounceTimers[k];
      });
      this._activeObservers.forEach((o) => o.pause && o.pause());
    } else {
      this._observersPaused = false;
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

  // --- Badge count ---

  updateBadgeCount: function () {
    if (this.appState === "background") return;

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
    if (this.appState === "background") return;

    const threads = this.getThreadLinks()
      .map((a, index) => ({
        threadKey: a.getAttribute("href"),
        threadName: this.getThreadName(a),
        snippet: this.getTextWithImageAlts(this.getSnippetElement(a)),
        isUnread: this.isUnreadThread(a),
        isMuted: this.isMutedThread(a),
        position: index,
      }))
      .filter((t) => Boolean(t.threadKey));

    let firstRun = false;
    if (threads.length > 0 && this.threadSnapshots == null) {
      this.threadSnapshots = new Map();
      firstRun = true;
    }

    const currentKey = this.getCurrentThreadKey();

    threads.forEach((thread) => {
      const prev = this.threadSnapshots.get(thread.threadKey);
      this.threadSnapshots.set(thread.threadKey, thread);

      if (!thread.isUnread) return;
      if (thread.isMuted) return;

      let shouldNotify = false;

      if (prev) {
        if (!prev.isUnread) {
          shouldNotify = true;
        } else if (thread.snippet !== prev.snippet) {
          shouldNotify = true;
        }
      } else {
        if (thread.position === 0 && !firstRun) {
          shouldNotify = true;
        }
      }

      if (shouldNotify) {
        const hasIgnoredPrefix = this.IGNORED_SNIPPET_PREFIXES.some((prefix) =>
          (thread.snippet || "").startsWith(prefix),
        );
        if (hasIgnoredPrefix) return;

        this.postToNative({
          type: "notification",
          title: thread.threadName || "Messenger",
          body: thread.snippet || "",
          threadKey: thread.threadKey,
          currentThreadKey: currentKey,
        });
      }
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

  // --- Init ---

  init: function () {
    this.log("Initializing Goofy");

    this.observe(
      '[role="navigation"] [role="grid"]',
      () => {
        this.debounce(
          "messages",
          () => {
            this.checkForNewMessages();
            this.updateBadgeCount();
          },
          this.debounceMs(),
        );
      },
      {
        onSetup: () => this.updateBadgeCount(),
        onRemove: () => {
          this.threadSnapshots = null;
          this._lastBadgeCount = -1;
        },
      },
    );

    // Pause when the page is hidden (window ordered out / tab-like hide)
    document.addEventListener("visibilitychange", () => {
      if (document.hidden) {
        this.setAppState("background");
      } else if (this.appState === "background") {
        // Native will also send foreground when app becomes active;
        // only resume here if we were paused solely by visibility.
        this.setAppState("foreground");
      }
    });
  },
};

window.__GOOFY.init();
