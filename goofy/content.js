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
        // Skip screen-reader-only elements
        if (node.classList && node.classList.contains("x1i1rx1s")) continue;
        if (node.getAttribute && node.getAttribute("aria-hidden") === "true" && node.tagName !== "IMG") {
          // still allow images with alts
        }
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

  log: function (message) {
    const timestamp = new Date().toISOString();
    const logEntry = `[${timestamp}] ${message}`;
    console.log(`[Goofy] ${logEntry}`);
    this.postToNative({ type: "log", message: logEntry });
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

  // --- Resilient selectors (aria/role first, class-hash fallback) ---

  getThreadLinks: function () {
    return Array.from(
      document.querySelectorAll('[role="navigation"] [role="row"] a[href*="/messages/"]'),
    );
  },

  getThreadName: function (anchor) {
    // Prefer aria-label on the row/link, then span with visible text
    const aria =
      anchor.getAttribute("aria-label") ||
      anchor.closest('[role="row"]')?.getAttribute("aria-label");
    if (aria) {
      // aria-label often includes snippet; take first line-ish chunk
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
    // Prefer last text-ish span under the link (preview line)
    const candidates = anchor.querySelectorAll('div[dir="auto"] span, span[dir="auto"], div.xi81zsa span');
    if (candidates.length > 0) {
      return candidates[candidates.length - 1];
    }
    return null;
  },

  isUnreadThread: function (anchor) {
    // Unread indicator: role=status, or aria-label containing unread, or legacy class
    if (
      anchor.querySelector(
        '[role="button"] [aria-label*="unread" i], [role="button"] [aria-label*="Unread"], [role="status"]',
      )
    ) {
      return true;
    }
    if (anchor.querySelector('[role="button"] .x1spa7qu')) return true;
    // Bold/strong weight on name often means unread
    const nameEl =
      anchor.querySelector('span[dir="auto"]') || anchor.querySelector("span.xlyipyv");
    if (nameEl) {
      const weight = parseInt(getComputedStyle(nameEl).fontWeight, 10);
      if (weight >= 600) return true;
    }
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
      retryInterval = 3000,
      onSetup = null,
      onRemove = null,
    } = options;

    let contentObserver = null;
    let removalObserver = null;
    let disposed = false;
    const self = this;

    const handle = {
      disconnect: function () {
        disposed = true;
        contentObserver?.disconnect();
        removalObserver?.disconnect();
      },
      pause: function () {
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
        setTimeout(setup, retryInterval);
        return;
      }

      self.log(`observe(${selector}): attached`);
      if (onSetup) onSetup(element);

      contentObserver?.disconnect();
      contentObserver = new MutationObserver(() => {
        if (!self._observersPaused) callback(element);
      });
      contentObserver.observe(element, { subtree, childList, characterData });

      removalObserver?.disconnect();
      removalObserver = new MutationObserver(() => {
        if (!document.contains(element)) {
          self.log(`observe(${selector}): removed, re-attaching`);
          contentObserver?.disconnect();
          removalObserver?.disconnect();
          if (onRemove) onRemove();
          setup();
        }
      });
      removalObserver.observe(document.body, {
        childList: true,
        subtree: true,
      });
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
      this._activeObservers.forEach((o) => o.pause && o.pause());
    } else {
      this._observersPaused = false;
      this._activeObservers.forEach((o) => o.resume && o.resume());
      // Catch up once after resume
      this.debounce("messages", () => {
        this.checkForNewMessages();
        this.updateBadgeCount();
      }, 100);
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

    // Fallback: count unread via isUnreadThread
    let count = unreadDots.length;
    if (count === 0) {
      count = this.getThreadLinks().filter((a) => this.isUnreadThread(a)).length;
    }

    this.postToNative({ type: "badge", count });
    this.log(`Badge count: ${count}`);
  },

  // --- Current thread ---

  getCurrentThreadKey: function () {
    try {
      const path = window.location.pathname || "";
      // /messages/t/<id>/ or /messages/e/<id>/
      const match = path.match(/\/messages\/(?:t|e)\/([^/]+)/);
      if (match) {
        return window.location.pathname + (window.location.search || "");
      }
      // Selected row
      const selected =
        document.querySelector('[role="navigation"] [role="row"][aria-selected="true"] a') ||
        document.querySelector('[role="navigation"] a[aria-current="page"]');
      if (selected) return selected.getAttribute("href");
    } catch (_) {}
    return null;
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

    // Always publish current thread for native suppression logic
    this.postToNative({
      type: "currentThread",
      threadKey: currentKey,
    });
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
      this.log(`jumpToThread(${index})`);
    }
  },

  prevThread: function () {
    const links = this.getThreadLinks();
    if (links.length === 0) return;
    const current = this.getCurrentThreadKey();
    let idx = links.findIndex((a) => a.getAttribute("href") === current);
    if (idx < 0) {
      // Match by path prefix
      const path = window.location.pathname;
      idx = links.findIndex((a) => {
        const href = a.getAttribute("href") || "";
        return path.includes(href.replace(/\/$/, "")) || href.includes(path);
      });
    }
    const next = idx <= 0 ? links.length - 1 : idx - 1;
    links[next].click();
    this.log(`prevThread -> ${next}`);
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
    this.log(`nextThread -> ${next}`);
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

  setChatOnly: function (enabled) {
    document.documentElement.classList.toggle("goofy-chat-only", !!enabled);
  },

  // Optional privacy stubs — only active when prefs are on (injected from Swift too)
  applyPrivacyHooks: function (blockTyping, blockSeen) {
    if (!blockTyping && !blockSeen) return;
    try {
      const originalFetch = window.fetch;
      if (originalFetch && !window.__GOOFY_PRIVACY_FETCH__) {
        window.__GOOFY_PRIVACY_FETCH__ = true;
        const self = this;
        window.fetch = function () {
          try {
            const arg = arguments[0];
            const url = typeof arg === "string" ? arg : arg && arg.url;
            if (typeof url === "string") {
              if (blockTyping && /typ|typing|comet_typing/i.test(url)) {
                self.log("Blocked typing request (fetch)");
                return Promise.resolve(new Response("{}", { status: 200 }));
              }
              if (blockSeen && /mark_seen|delivery_receipt|read_receipt|seen/i.test(url)) {
                self.log("Blocked seen request (fetch)");
                return Promise.resolve(new Response("{}", { status: 200 }));
              }
            }
          } catch (_) {}
          return originalFetch.apply(this, arguments);
        };
      }
    } catch (e) {
      this.log("applyPrivacyHooks error: " + e);
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
          350,
        );
      },
      {
        onSetup: () => this.updateBadgeCount(),
        onRemove: () => {
          this.threadSnapshots = null;
        },
      },
    );
  },
};

window.__GOOFY.init();
