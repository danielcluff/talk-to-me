// Talk to Me extension: offscreen document that holds the app's event stream.
//
// EventSource can't send the Authorization header, so this reads
// GET /v1/events with fetch and forwards each event to the service worker,
// which would otherwise be suspended between messages.
let controller = null;

async function listen(api, token) {
  if (controller) controller.abort();
  controller = new AbortController();
  const signal = controller.signal;
  for (let attempt = 0; !signal.aborted; attempt++) {
    try {
      const res = await fetch(api.replace(/\/+$/, "") + "/v1/events", {
        headers: { authorization: "Bearer " + token },
        signal: signal
      });
      if (!res.ok || !res.body) throw new Error("HTTP " + res.status);
      const reader = res.body.getReader();
      const decoder = new TextDecoder();
      let buf = "";
      for (;;) {
        const { value, done } = await reader.read();
        if (done) break;
        buf += decoder.decode(value, { stream: true });
        let cut;
        while ((cut = buf.indexOf("\n\n")) >= 0) {
          const block = buf.slice(0, cut);
          buf = buf.slice(cut + 2);
          for (const line of block.split("\n")) {
            if (!line.startsWith("data: ")) continue;
            try {
              const event = JSON.parse(line.slice(6));
              chrome.runtime.sendMessage({ from: "offscreen", t: "event", event: event }).catch(() => {});
            } catch (err) {
              // malformed line
            }
          }
        }
      }
    } catch (err) {
      if (signal.aborted) return;
    }
    // reconnect with a short backoff (the app may be restarting)
    await new Promise((r) => setTimeout(r, Math.min(5000, 500 * (attempt + 1))));
  }
}

chrome.runtime.onMessage.addListener((msg) => {
  if (!msg || msg.target !== "offscreen") return;
  if (msg.t === "listen") listen(msg.api, msg.token);
});

// ask for the connection details in case "listen" was sent before this loaded
chrome.runtime.sendMessage({ from: "offscreen", t: "ready" }).catch(() => {});
