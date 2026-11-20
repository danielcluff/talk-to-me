// Talk to Me extension popup: connection and pairing, now playing, read actions, toggles.
const DEFAULTS = { showPill: true, autoReadChatGPT: false, autoReadClaude: false };
const $ = (sel) => document.querySelector(sel);
let state = { status: "idle", index: -1, total: 0, label: "" };

init();

async function init() {
  const settings = await chrome.storage.sync.get(DEFAULTS);
  $("#show-pill").checked = settings.showPill !== false;
  $("#auto-chatgpt").checked = !!settings.autoReadChatGPT;
  $("#auto-claude").checked = !!settings.autoReadClaude;
  bind();
  refreshConnection();
  chrome.runtime.sendMessage({ t: "get-state" }, (res) => {
    if (res && res.state) render(res.state);
  });
}

function bind() {
  for (const button of document.querySelectorAll(".actions button")) {
    button.addEventListener("click", () => {
      chrome.runtime.sendMessage({ t: "read-tab", scope: button.dataset.scope });
      window.close();
    });
  }
  $("#show-pill").addEventListener("change", (ev) => chrome.storage.sync.set({ showPill: ev.target.checked }));
  $("#auto-chatgpt").addEventListener("change", (ev) => chrome.storage.sync.set({ autoReadChatGPT: ev.target.checked }));
  $("#auto-claude").addEventListener("change", (ev) => chrome.storage.sync.set({ autoReadClaude: ev.target.checked }));
  $("#toggle").addEventListener("click", () => {
    chrome.runtime.sendMessage({ t: "control", action: state.status === "paused" ? "resume" : "pause" });
  });
  $("#stop").addEventListener("click", () => chrome.runtime.sendMessage({ t: "control", action: "stop" }));
  $("#connect-btn").addEventListener("click", connect);
  $("#speak").addEventListener("click", () => {
    const text = $("#text").value.trim();
    if (text) speak(text, "Text");
  });
  $("#file").addEventListener("change", (ev) => {
    const file = ev.target.files && ev.target.files[0];
    if (file) speakFile(file);
  });
  const text = $("#text");
  text.addEventListener("dragover", (ev) => ev.preventDefault());
  text.addEventListener("drop", (ev) => {
    ev.preventDefault();
    const file = ev.dataTransfer.files && ev.dataTransfer.files[0];
    if (file) speakFile(file);
  });
}

function refreshConnection() {
  chrome.runtime.sendMessage({ t: "connection" }, (c) => {
    const el = $("#status");
    if (!c || !c.running) {
      el.className = "status bad";
      el.textContent = "Talk to Me isn't running";
      $("#connect").hidden = true;
      return;
    }
    if (!c.paired) {
      el.className = "status bad";
      el.textContent = "not connected";
      $("#connect").hidden = false;
      if (c.pairing) showCode(c.pairing);
      return;
    }
    el.className = "status ok";
    el.textContent = "connected";
    $("#connect").hidden = true;
  });
}

function showCode(code) {
  $("#connect-btn").disabled = true;
  $("#code").textContent = "Code " + code + ": approve it in Talk to Me";
}

function connect() {
  chrome.runtime.sendMessage({ t: "pair" }, (res) => {
    if (!res || !res.ok) {
      $("#code").textContent = (res && res.error) || "Could not reach Talk to Me";
      return;
    }
    showCode(res.code);
  });
}

function speak(text, label) {
  chrome.runtime.sendMessage({ t: "speak", text: text, label: label });
}

async function speakFile(file) {
  const text = await file.text();
  speak(text, file.name);
}

function render(s) {
  state = s;
  const active = s.status === "playing" || s.status === "paused" || s.status === "loading" || s.status === "queued";
  $("#now").hidden = !active;
  if (active) {
    $("#now-label").textContent = s.label || "Reading";
    $("#now-meta").textContent = s.status === "queued" ? "queued" : s.status === "loading" ? "starting…" : (s.index + 1) + " / " + s.total;
    $("#toggle").textContent = s.status === "paused" ? "Resume" : "Pause";
  }
  if (s.error) {
    $("#status").className = "status bad";
    $("#status").textContent = s.error;
  }
}

chrome.runtime.onMessage.addListener((msg) => {
  if (!msg) return;
  if (msg.t === "state") render(msg.state);
  if (msg.t === "paired") {
    $("#connect-btn").disabled = false;
    $("#code").textContent = msg.ok ? "" : msg.error;
    refreshConnection();
  }
});
