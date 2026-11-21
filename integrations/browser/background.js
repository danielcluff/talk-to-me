// Talk to Me browser extension: service worker.
//
// The app does the speaking. This worker pairs with the app (once), sends the
// sentences the content script extracted to POST /v1/speak, maps the in-page
// transport to /v1/player/*, and follows the app's event stream (held by the
// offscreen document) to highlight the sentence being spoken.
importScripts("lib/text.js");

const DEFAULTS = {
  api: "http://127.0.0.1:9932",
  showPill: true
};

const IDLE = { status: "idle", index: -1, total: 0, label: "", tabId: null, jobId: null, error: "" };
let state = Object.assign({}, IDLE);

// ---------- settings, token, API ----------

async function getSettings() {
  return chrome.storage.sync.get(DEFAULTS);
}

async function getToken() {
  const got = await chrome.storage.local.get({ token: "" });
  return got.token || "";
}

async function api(method, path, body) {
  const settings = await getSettings();
  const token = await getToken();
  const headers = { "content-type": "application/json" };
  if (token) headers.authorization = "Bearer " + token;
  let res;
  try {
    res = await fetch(settings.api.replace(/\/+$/, "") + path, {
      method: method,
      headers: headers,
      body: method === "GET" ? undefined : JSON.stringify(body || {})
    });
  } catch (err) {
    return { ok: false, status: 0, error: "Talk to Me is not running" };
  }
  let json = {};
  try {
    json = await res.json();
  } catch (err) {
    // empty body
  }
  if (!res.ok) {
    const error = res.status === 401 || res.status === 403 ? "Not connected to Talk to Me" : (json.error || "HTTP " + res.status);
    return { ok: false, status: res.status, error: error, json: json };
  }
  return { ok: true, status: res.status, json: json };
}

async function connection() {
  const health = await api("GET", "/v1/health");
  if (!health.ok) return { running: false, paired: false };
  const token = await getToken();
  if (!token) return { running: true, paired: false };
  const player = await api("GET", "/v1/player");
  return { running: true, paired: player.ok, player: player.json };
}

// ---------- pairing ----------

let pairing = null; // { id, secret, code }

async function startPairing() {
  if (pairing) return { ok: true, code: pairing.code };
  const res = await api("POST", "/v1/pair", {});
  if (!res.ok) return { ok: false, error: res.error };
  pairing = { id: res.json.pair_id, secret: res.json.secret, code: res.json.code };
  pollPairing(pairing);
  return { ok: true, code: pairing.code };
}

async function pollPairing(p) {
  const settings = await getSettings();
  const deadline = Date.now() + 120000;
  while (Date.now() < deadline && pairing === p) {
    await new Promise((r) => setTimeout(r, 1000));
    let json = {};
    try {
      const res = await fetch(settings.api.replace(/\/+$/, "") + "/v1/pair/" + p.id + "?secret=" + p.secret);
      json = await res.json();
    } catch (err) {
      continue;
    }
    if (json.status === "approved" && json.token) {
      await chrome.storage.local.set({ token: json.token });
      pairing = null;
      notify({ t: "paired", ok: true });
      return;
    }
    if (json.status === "denied" || json.status === "unknown") {
      pairing = null;
      notify({ t: "paired", ok: false, error: json.status === "denied" ? "Talk to Me denied the request" : "The request expired" });
      return;
    }
  }
  if (pairing === p) {
    pairing = null;
    notify({ t: "paired", ok: false, error: "No answer from Talk to Me" });
  }
}

function notify(msg) {
  chrome.runtime.sendMessage(msg).catch(() => {});
}

// ---------- state broadcast ----------

function saveState() {
  try {
    chrome.storage.session.set({ readerState: state });
  } catch (err) {
    // best effort
  }
}

function broadcast() {
  notify({ t: "state", state: state });
  if (state.tabId != null) {
    chrome.tabs.sendMessage(state.tabId, { t: "state", state: state }).catch(() => {});
  }
}

function toTab(tabId, msg) {
  if (tabId == null) return Promise.resolve();
  return chrome.tabs.sendMessage(tabId, msg).catch(() => {});
}

function toastTab(tabId, text) {
  if (tabId != null) toTab(tabId, { t: "toast", text: text });
}

function setIdle() {
  const tabId = state.tabId;
  state = Object.assign({}, IDLE);
  broadcast();
  saveState();
  if (tabId != null) toTab(tabId, { t: "clear" });
  chrome.action.setBadgeText({ text: "" });
  closeEvents();
}

function fail(tabId, message) {
  state = Object.assign({}, IDLE, { error: String(message || "Error") });
  broadcast();
  saveState();
  chrome.action.setBadgeText({ text: "!" });
  chrome.action.setBadgeBackgroundColor({ color: "#dc2626" });
  setTimeout(() => chrome.action.setBadgeText({ text: "" }), 4000);
  toastTab(tabId, String(message || "Error"));
}

// ---------- event stream (held by the offscreen document) ----------

async function hasOffscreen() {
  try {
    if (chrome.offscreen && chrome.offscreen.hasDocument) return await chrome.offscreen.hasDocument();
    const contexts = await chrome.runtime.getContexts({ contextTypes: ["OFFSCREEN_DOCUMENT"] });
    return contexts.length > 0;
  } catch (err) {
    return false;
  }
}

async function openEvents() {
  const settings = await getSettings();
  const token = await getToken();
  if (!(await hasOffscreen())) {
    try {
      await chrome.offscreen.createDocument({
        url: "offscreen.html",
        reasons: ["WORKERS"],
        justification: "Keep a streaming connection to the local Talk to Me app to follow reading progress"
      });
    } catch (err) {
      if (!String(err && err.message).includes("Only a single offscreen")) throw err;
    }
  }
  chrome.runtime.sendMessage({ target: "offscreen", t: "listen", api: settings.api, token: token }).catch(() => {});
}

async function closeEvents() {
  if (await hasOffscreen()) {
    try {
      await chrome.offscreen.closeDocument();
    } catch (err) {
      // already gone
    }
  }
}

function onCoreEvent(e) {
  if (!state.jobId) return;
  if (e.type === "chunk_started" && e.job === state.jobId) {
    state.status = "playing";
    state.index = e.index;
    broadcast();
    saveState();
    toTab(state.tabId, { t: "highlight", index: e.index });
    chrome.action.setBadgeText({ text: (e.index + 1) + "/" + state.total });
  } else if (e.type === "job_finished" && e.job === state.jobId) {
    setIdle();
  } else if (e.type === "player_state") {
    state.status = e.state === "paused" ? "paused" : "playing";
    broadcast();
    saveState();
  }
}

/// The event stream just (re)connected: anything that happened before it
/// (a short read can start and finish in that gap) was missed, so ask the
/// player where things stand.
async function reconcile() {
  if (!state.jobId) return;
  const res = await api("GET", "/v1/player");
  if (!res.ok || !state.jobId) return;
  const p = res.json;
  if (p.job != null && "j_" + p.job === state.jobId) {
    state.status = p.state === "paused" ? "paused" : "playing";
    state.index = p.index;
    broadcast();
    saveState();
    toTab(state.tabId, { t: "highlight", index: p.index });
    chrome.action.setBadgeText({ text: (p.index + 1) + "/" + state.total });
  } else if (!p.queued) {
    // not playing and nothing waiting: ours already finished
    setIdle();
  }
}

// ---------- reading ----------

async function startReading(opts) {
  const chunks = (opts.chunks || []).filter((c) => String(c || "").trim());
  const text = String(opts.text || "").trim();
  if (!chunks.length && !text) {
    toastTab(opts.tabId, "Nothing to read here");
    return;
  }
  const res = await api("POST", "/v1/speak", {
    chunks: chunks.length ? chunks : undefined,
    text: chunks.length ? undefined : text,
    format: "text",
    source: { app: "browser", label: opts.label || "", session: "tab-" + opts.tabId },
    policy: opts.policy || "interrupt",
    kind: opts.kind || "read"
  });
  if (!res.ok) {
    fail(opts.tabId, res.status === 0 ? "Talk to Me is not running" : res.error + (res.status === 401 || res.status === 403 ? ": open the extension and click Connect" : ""));
    return;
  }
  if (res.json.dropped) {
    toastTab(opts.tabId, "Not read: " + res.json.dropped);
    return;
  }
  // a new read in another tab replaces the highlight there
  if (state.tabId != null && state.tabId !== opts.tabId) toTab(state.tabId, { t: "clear" });
  state = {
    status: res.json.position > 0 ? "queued" : "loading",
    index: -1,
    total: res.json.chunks || chunks.length,
    label: opts.label || "",
    tabId: opts.tabId == null ? null : opts.tabId,
    jobId: res.json.job_id,
    error: ""
  };
  broadcast();
  saveState();
  chrome.action.setBadgeText({ text: String(chunks.length) });
  chrome.action.setBadgeBackgroundColor({ color: "#ffbe0b" });
  openEvents();
}

async function control(action) {
  const map = { stop: "stop", pause: "pause", resume: "resume", next: "next", prev: "previous", toggle: "toggle" };
  const cmd = map[action];
  if (!cmd) return;
  const res = await api("POST", "/v1/player/" + cmd, {});
  if (action === "stop") setIdle();
  else if (!res.ok) fail(state.tabId, res.error);
}

// ---------- tab helpers ----------

async function sendOrInject(tabId, msg) {
  try {
    return await chrome.tabs.sendMessage(tabId, msg);
  } catch (err) {
    await chrome.scripting.executeScript({ target: { tabId: tabId }, files: ["lib/text.js", "content.js"] });
    return await chrome.tabs.sendMessage(tabId, msg);
  }
}

async function readInActiveTab(scope) {
  const tabs = await chrome.tabs.query({ active: true, currentWindow: true });
  const tab = tabs[0];
  if (!tab || tab.id == null) return;
  try {
    await sendOrInject(tab.id, { t: "read", scope: scope || "page" });
  } catch (err) {
    chrome.action.setBadgeText({ text: "!" });
    setTimeout(() => chrome.action.setBadgeText({ text: "" }), 3000);
  }
}

// ---------- messages ----------

chrome.runtime.onMessage.addListener((msg, sender, respond) => {
  if (!msg) return false;
  if (msg.from === "offscreen") {
    if (msg.t === "event") onCoreEvent(msg.event);
    if (msg.t === "connected") reconcile();
    if (msg.t === "ready") openEvents();
    return false;
  }
  switch (msg.t) {
    case "start":
      startReading({
        chunks: msg.chunks,
        label: msg.label,
        policy: msg.policy,
        kind: msg.kind,
        tabId: sender.tab ? sender.tab.id : null
      });
      respond({ ok: true });
      return false;
    case "control":
      control(msg.action);
      respond({ ok: true });
      return false;
    case "get-state":
      respond({ ok: true, state: state });
      return false;
    case "read-tab":
      readInActiveTab(msg.scope);
      respond({ ok: true });
      return false;
    case "connection":
      connection().then((c) => respond(Object.assign({ ok: true, pairing: pairing ? pairing.code : null }, c)));
      return true;
    case "pair":
      startPairing().then(respond);
      return true;
    case "unpair":
      chrome.storage.local.remove("token").then(() => respond({ ok: true }));
      return true;
    default:
      return false;
  }
});

// ---------- commands, menus, lifecycle ----------

// Read Selection and Stop are Talk to Me's global hotkeys (⌥⇧R, ⌥⇧X), which
// work in the browser too. The right-click menu has one item per context, so
// Chrome shows it directly instead of a submenu.
chrome.runtime.onInstalled.addListener(() => {
  chrome.contextMenus.removeAll(() => {
    chrome.contextMenus.create({ id: "read-selection", title: "Read with Talk to Me", contexts: ["selection"] });
    chrome.contextMenus.create({ id: "read-page", title: "Read this tab with Talk to Me", contexts: ["page"] });
  });
});

chrome.contextMenus.onClicked.addListener((info, tab) => {
  const scope = info.menuItemId === "read-selection" ? "selection" : "page";
  if (tab && tab.id != null) sendOrInject(tab.id, { t: "read", scope: scope }).catch(() => {});
});

// leaving the page drops its highlight; the app keeps reading what it has
chrome.tabs.onRemoved.addListener((tabId) => {
  if (state.tabId === tabId && state.status !== "idle") setIdle();
});

chrome.tabs.onUpdated.addListener((tabId, change) => {
  if (tabId === state.tabId && change.status === "loading" && state.status !== "idle") {
    state.tabId = null;
    broadcast();
  }
});

// restore after a service worker restart
chrome.storage.session.get("readerState").then((got) => {
  if (!got || !got.readerState || got.readerState.status === "idle") return;
  state = got.readerState;
  openEvents();
  broadcast();
});
