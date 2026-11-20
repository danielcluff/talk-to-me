// Talk to Me extension popup: connection and pairing, read this tab, pick an element.
const $ = (sel) => document.querySelector(sel);

init();

async function init() {
  const settings = await chrome.storage.sync.get({ showPill: true });
  $("#show-pill").checked = settings.showPill !== false;
  for (const button of document.querySelectorAll(".actions button")) {
    button.addEventListener("click", () => {
      chrome.runtime.sendMessage({ t: "read-tab", scope: button.dataset.scope });
      window.close();
    });
  }
  $("#show-pill").addEventListener("change", (ev) => chrome.storage.sync.set({ showPill: ev.target.checked }));
  $("#connect-btn").addEventListener("click", connect);
  refreshConnection();
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

chrome.runtime.onMessage.addListener((msg) => {
  if (msg && msg.t === "paired") {
    $("#connect-btn").disabled = false;
    $("#code").textContent = msg.ok ? "" : msg.error;
    refreshConnection();
  }
});
