// Talk to Me content script: in-page controls, text extraction entry points,
// highlight, and auto-read of new ChatGPT / Claude replies.
(() => {
  if (window.__kokoroReaderLoaded) return;
  window.__kokoroReaderLoaded = true;

  const T = window.KokoroText;
  const HOST_ID = "kokoro-reader-host";
  const HL_NAME = "kokoro-current";

  let chunks = [];
  let state = { status: "idle", index: -1, total: 0, label: "", error: "" };
  let settings = { showPill: true, maxChunk: 150 };
  let ui = null;
  let menuOpen = false;
  let hlStyled = false;
  let toastTimer = 0;

  const ICON = {
    speaker: '<svg viewBox="0 0 24 24" width="20" height="20" fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round" stroke-linejoin="round"><path d="M4 9v6h4l5 4V5L8 9H4z"/><path d="M16.5 8.5a5 5 0 0 1 0 7"/><path d="M19.5 6a9 9 0 0 1 0 12"/></svg>',
    play: '<svg viewBox="0 0 24 24" width="18" height="18" fill="currentColor"><path d="M8 5v14l11-7z"/></svg>',
    pause: '<svg viewBox="0 0 24 24" width="18" height="18" fill="currentColor"><path d="M7 5h4v14H7zM13 5h4v14h-4z"/></svg>',
    prev: '<svg viewBox="0 0 24 24" width="16" height="16" fill="currentColor"><path d="M7 5h2v14H7zM19 5v14l-9-7z"/></svg>',
    next: '<svg viewBox="0 0 24 24" width="16" height="16" fill="currentColor"><path d="M15 5h2v14h-2zM5 5l9 7-9 7z"/></svg>',
    stop: '<svg viewBox="0 0 24 24" width="16" height="16" fill="currentColor"><path d="M6 6h12v12H6z"/></svg>'
  };

  // ---------- UI ----------

  const UI_CSS = [
    ":host{all:initial}",
    ".root{font:13px/1.4 -apple-system,BlinkMacSystemFont,'Segoe UI',sans-serif;color:#f5f5f4}",
    ".root[hidden]{display:none}",
    ".fab{width:42px;height:42px;border-radius:50%;border:1px solid rgba(255,255,255,.14);background:rgba(23,23,23,.86);color:#ffbe0b;display:flex;align-items:center;justify-content:center;cursor:pointer;box-shadow:0 6px 20px rgba(0,0,0,.35);opacity:.62;transition:opacity .15s,transform .15s;backdrop-filter:blur(10px)}",
    ".fab:hover{opacity:1;transform:translateY(-1px)}",
    ".bar{display:flex;align-items:center;gap:6px;padding:6px 8px;border-radius:12px;border:1px solid rgba(255,255,255,.14);background:rgba(23,23,23,.92);box-shadow:0 6px 20px rgba(0,0,0,.35);backdrop-filter:blur(10px)}",
    ".bar button{all:unset;width:26px;height:26px;border-radius:7px;display:flex;align-items:center;justify-content:center;cursor:pointer;color:#e7e5e4}",
    ".bar button:hover{background:rgba(255,255,255,.1);color:#ffbe0b}",
    ".meta{font-variant-numeric:tabular-nums;color:#a8a29e;min-width:52px;text-align:center}",
    ".label{max-width:170px;overflow:hidden;text-overflow:ellipsis;white-space:nowrap;color:#d6d3d1}",
    ".menu{position:absolute;right:0;bottom:52px;min-width:190px;padding:6px;border-radius:12px;border:1px solid rgba(255,255,255,.14);background:rgba(23,23,23,.96);box-shadow:0 10px 30px rgba(0,0,0,.45);backdrop-filter:blur(10px)}",
    ".menu button{all:unset;display:flex;justify-content:space-between;gap:16px;box-sizing:border-box;width:100%;padding:7px 10px;border-radius:8px;cursor:pointer;color:#e7e5e4}",
    ".menu button:hover{background:rgba(255,255,255,.09);color:#ffbe0b}",
    ".menu kbd{font:11px ui-monospace,SFMono-Regular,Menlo,monospace;color:#78716c}",
    ".menu hr{border:0;border-top:1px solid rgba(255,255,255,.1);margin:5px 4px}",
    ".toast{position:absolute;right:0;bottom:52px;max-width:260px;padding:8px 10px;border-radius:10px;background:rgba(23,23,23,.96);border:1px solid rgba(255,255,255,.14);color:#e7e5e4;box-shadow:0 8px 24px rgba(0,0,0,.4)}",
    "[hidden]{display:none!important}"
  ].join("\n");

  // Adopted stylesheets avoid the page CSP, which blocks <style> on many sites.
  function adoptStyle(root, css) {
    try {
      const sheet = new CSSStyleSheet();
      sheet.replaceSync(css);
      root.adoptedStyleSheets = root.adoptedStyleSheets.concat([sheet]);
      return;
    } catch (err) {
      // older engines
    }
    const style = document.createElement("style");
    style.textContent = css;
    root.append(style);
  }

  function buildUI() {
    if (ui || !document.documentElement) return;

    const host = document.createElement("div");
    host.id = HOST_ID;
    host.style.cssText = "all:initial;position:fixed;right:18px;bottom:18px;z-index:2147483647";
    const shadow = host.attachShadow({ mode: "open" });
    adoptStyle(shadow, UI_CSS);
    shadow.innerHTML = [
      '<div class="root">',
      '  <div class="bar" hidden>',
      '    <button data-act="prev" title="Previous sentence">' + ICON.prev + "</button>",
      '    <button data-act="pause" title="Pause">' + ICON.pause + "</button>",
      '    <button data-act="next" title="Next sentence">' + ICON.next + "</button>",
      '    <span class="meta">0 / 0</span>',
      '    <span class="label"></span>',
      '    <button data-act="stop" title="Stop">' + ICON.stop + "</button>",
      "  </div>",
      '  <div class="menu" hidden>',
      '    <button data-scope="page">Read this tab <kbd>Alt+Shift+A</kbd></button>',
      '    <button data-scope="reply">Read last reply <kbd>Alt+Shift+L</kbd></button>',
      '    <button data-scope="selection">Read selection <kbd>⌥⇧R</kbd></button>',
      '    <hr>',
      '    <button data-act="pick">Pick an element...</button>',
      "  </div>",
      '  <div class="toast" hidden></div>',
      '  <button class="fab" title="Talk to Me">' + ICON.speaker + "</button>",
      "</div>"
    ].join("");

    document.documentElement.appendChild(host);

    ui = {
      host: host,
      root: shadow.querySelector(".root"),
      fab: shadow.querySelector(".fab"),
      bar: shadow.querySelector(".bar"),
      menu: shadow.querySelector(".menu"),
      toast: shadow.querySelector(".toast"),
      meta: shadow.querySelector(".meta"),
      label: shadow.querySelector(".label"),
      pause: shadow.querySelector('[data-act="pause"]')
    };

    ui.fab.addEventListener("click", () => {
      menuOpen = !menuOpen;
      render();
    });

    shadow.addEventListener("click", (ev) => {
      const scope = ev.target.closest("[data-scope]");
      if (scope) {
        menuOpen = false;
        render();
        readScope(scope.dataset.scope);
        return;
      }
      const act = ev.target.closest("[data-act]");
      if (!act) return;
      const name = act.dataset.act;
      if (name === "pick") {
        menuOpen = false;
        render();
        pickElement();
      } else if (name === "pause") {
        send({ t: "control", action: state.status === "paused" ? "resume" : "pause" });
      } else if (name === "prev" || name === "next") {
        send({ t: "control", action: name });
      } else if (name === "stop") {
        send({ t: "control", action: "stop" });
      }
    });

    applyVisibility();
  }

  function applyVisibility() {
    if (!ui) return;
    ui.host.style.display = settings.showPill ? "" : "none";
  }

  function render() {
    if (!ui) return;
    const active = state.status === "playing" || state.status === "loading" || state.status === "paused";
    ui.bar.hidden = !active;
    ui.fab.hidden = active;
    ui.menu.hidden = !(menuOpen && !active);
    if (active) {
      ui.meta.textContent = state.status === "loading" ? "..." : (state.index + 1) + " / " + state.total;
      ui.label.textContent = state.label || "";
      ui.pause.innerHTML = state.status === "paused" ? ICON.play : ICON.pause;
      ui.pause.title = state.status === "paused" ? "Resume" : "Pause";
    }
  }

  function toast(text) {
    if (!ui) return;
    ui.toast.textContent = text;
    ui.toast.hidden = false;
    clearTimeout(toastTimer);
    toastTimer = setTimeout(() => {
      ui.toast.hidden = true;
    }, 2600);
  }

  function send(msg) {
    try {
      chrome.runtime.sendMessage(msg, () => void chrome.runtime.lastError);
    } catch (err) {
      // extension reloaded; ignore
    }
  }

  // ---------- reading ----------

  async function getSettings() {
    try {
      const got = await chrome.storage.sync.get({ maxChunk: 150, showPill: true });
      settings.maxChunk = got.maxChunk || 150;
      settings.showPill = got.showPill !== false;
    } catch (err) {
      // keep defaults
    }
    return settings;
  }

  async function readScope(scope) {
    await getSettings();
    if (scope === "pick") {
      pickElement();
      return;
    }
    let result = null;
    if (scope === "selection") result = T.selectionChunks(settings.maxChunk);
    else if (scope === "reply") result = T.replyChunks(settings.maxChunk);
    else result = T.pageChunks(settings.maxChunk);

    if (scope === "reply" && !result) {
      toast("No reply found here. Use Pick an element.");
      return;
    }
    if (!result) {
      toast(scope === "selection" ? "Nothing is selected" : "Nothing to read here");
      return;
    }
    start(result.chunks, scope === "reply" ? siteName() || result.label : result.label, scope === "reply" ? { policy: "interrupt", kind: "reply" } : null);
  }

  // policy: "interrupt" for what you ask for, "queue" for automatic reads.
  // kind: "reply" marks a model reply (briefings in Phase 7 apply to those only).
  function start(list, label, opts) {
    if (!list || !list.length) {
      if (!opts) toast("Nothing to read here");
      return;
    }
    chunks = list;
    clearHighlight();
    send({
      t: "start",
      chunks: list.map((c) => c.text),
      label: label || "",
      policy: (opts && opts.policy) || "interrupt",
      kind: (opts && opts.kind) || "read"
    });
  }

  function pickElement() {
    const box = document.createElement("div");
    box.style.cssText = "position:fixed;border:2px solid #ffbe0b;background:rgba(255,190,11,.12);border-radius:4px;pointer-events:none;z-index:2147483647";
    document.documentElement.append(box);

    let target = null;

    function onMove(ev) {
      const el = document.elementFromPoint(ev.clientX, ev.clientY);
      if (!el || el === box) return;
      target = el;
      const r = el.getBoundingClientRect();
      box.style.left = r.left + "px";
      box.style.top = r.top + "px";
      box.style.width = r.width + "px";
      box.style.height = r.height + "px";
    }

    function cleanup() {
      box.remove();
      document.documentElement.style.cursor = "";
      window.removeEventListener("mousemove", onMove, true);
      window.removeEventListener("click", onClick, true);
      window.removeEventListener("keydown", onKey, true);
    }

    function onClick(ev) {
      ev.preventDefault();
      ev.stopPropagation();
      const el = target;
      cleanup();
      if (!el) return;
      pickRead(el);
    }

    function onKey(ev) {
      if (ev.key !== "Escape") return;
      ev.preventDefault();
      cleanup();
    }

    document.documentElement.style.cursor = "crosshair";
    window.addEventListener("mousemove", onMove, true);
    window.addEventListener("click", onClick, true);
    window.addEventListener("keydown", onKey, true);
  }

  async function pickRead(el) {
    await getSettings();
    let node = el;
    while (node.parentElement && (node.innerText || "").trim().length < 60) node = node.parentElement;
    const list = T.chunksFromRoot(node, settings.maxChunk, null);
    start(list, (node.innerText || "").trim().slice(0, 60) || "Selection");
  }

  // ---------- highlight ----------

  function ensureHighlightStyle() {
    if (hlStyled) return;
    hlStyled = true;
    const css = "::highlight(" + HL_NAME + "){background-color: rgba(255,190,11,.38);}";
    try {
      const sheet = new CSSStyleSheet();
      sheet.replaceSync(css);
      document.adoptedStyleSheets = document.adoptedStyleSheets.concat([sheet]);
      return;
    } catch (err) {
      // fall through to a style element
    }
    const style = document.createElement("style");
    style.textContent = css;
    (document.head || document.documentElement).appendChild(style);
  }

  function highlight(index) {
    if (!window.CSS || !CSS.highlights || typeof Highlight === "undefined") return;
    const chunk = chunks[index];
    if (!chunk || !chunk.range) return;
    try {
      ensureHighlightStyle();
      CSS.highlights.set(HL_NAME, new Highlight(chunk.range));
      const rect = chunk.range.getBoundingClientRect();
      if (rect && (rect.top < 8 || rect.bottom > innerHeight - 8)) {
        const parent = chunk.range.startContainer.parentElement;
        if (parent) parent.scrollIntoView({ block: "center", behavior: "smooth" });
      }
    } catch (err) {
      // the page re-rendered under us; the highlight is cosmetic
    }
  }

  function clearHighlight() {
    try {
      if (window.CSS && CSS.highlights) CSS.highlights.delete(HL_NAME);
    } catch (err) {
      // ignore
    }
  }

  // ---------- messages ----------

  chrome.runtime.onMessage.addListener((msg, sender, respond) => {
    if (!msg) return;
    if (msg.t === "read") {
      readScope(msg.scope || "page");
    } else if (msg.t === "state") {
      state = msg.state || state;
      buildUI();
      render();
    } else if (msg.t === "highlight") {
      highlight(msg.index);
    } else if (msg.t === "clear") {
      clearHighlight();
    } else if (msg.t === "toast") {
      buildUI();
      toast(msg.text);
    }
    try {
      respond({ ok: true });
    } catch (err) {
      // no responder
    }
  });

  chrome.storage.onChanged.addListener((changes) => {
    if (changes.showPill) {
      settings.showPill = changes.showPill.newValue !== false;
      applyVisibility();
    }
    if (changes.maxChunk) settings.maxChunk = changes.maxChunk.newValue || 150;
  });

  // ---------- auto-read new replies (ChatGPT, Claude) ----------

  const SITES = [
    {
      name: "ChatGPT",
      key: "autoReadChatGPT",
      host: /(^|\.)(chatgpt\.com|chat\.openai\.com)$/,
      streaming: () => !!document.querySelector('[data-testid="stop-button"], button[aria-label="Stop streaming"]')
    },
    {
      name: "Claude",
      key: "autoReadClaude",
      host: /(^|\.)claude\.ai$/,
      streaming: () => !!document.querySelector('[data-is-streaming="true"], button[aria-label="Stop response"]')
    }
  ];
  const site = SITES.find((s) => s.host.test(location.hostname)) || null;

  function siteName() {
    return site ? site.name : "";
  }

  const auto = { on: false, observer: null, timer: 0, sawStreaming: false, last: "" };

  function replyFingerprint() {
    const r = T.replyChunks(settings.maxChunk);
    return r ? { result: r, text: r.chunks.map((c) => c.text).join(" ") } : null;
  }

  // Read a reply only after it was seen streaming and then settled, so
  // opening a conversation never reads its history.
  function checkReply() {
    if (!auto.on || !site) return;
    if (site.streaming()) {
      auto.sawStreaming = true;
      return;
    }
    if (!auto.sawStreaming) return;
    const fp = replyFingerprint();
    if (!fp || fp.text === auto.last) return;
    auto.sawStreaming = false;
    auto.last = fp.text;
    start(fp.result.chunks, site.name, { policy: "queue", kind: "reply" });
  }

  function setAutoRead(on) {
    if (!site || on === auto.on) return;
    auto.on = on;
    if (on) {
      const fp = replyFingerprint();
      auto.last = fp ? fp.text : "";
      auto.sawStreaming = site.streaming();
      auto.observer = new MutationObserver(() => {
        if (site.streaming()) auto.sawStreaming = true;
        clearTimeout(auto.timer);
        auto.timer = setTimeout(checkReply, 1500);
      });
      auto.observer.observe(document.body || document.documentElement, { childList: true, subtree: true, characterData: true, attributes: true, attributeFilter: ["data-is-streaming", "data-testid", "aria-label"] });
    } else if (auto.observer) {
      auto.observer.disconnect();
      auto.observer = null;
      clearTimeout(auto.timer);
    }
  }

  if (site) {
    chrome.storage.sync.get({ [site.key]: false }).then((got) => setAutoRead(!!got[site.key])).catch(() => {});
    chrome.storage.onChanged.addListener((changes) => {
      if (changes[site.key]) setAutoRead(!!changes[site.key].newValue);
    });
  }

  getSettings().then(buildUI);
})();
