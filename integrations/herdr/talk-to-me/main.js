// Talk to Me for herdr: a slim bar that shows what Talk to Me is reading, with
// pause/resume and stop, and says "<agent> finished" for agents that have no
// native Talk to Me hook (Claude Code, Codex and OpenCode speak their own
// replies through their hooks, so they are skipped here).
//
// Installed by `talktome install herdr`. Talks to the local API with the
// token in ~/Library/Application Support/TalkToMe/token.

import { View, div } from "gpui-kit";
import { h_flex } from "gpui-base";
import { agents, home, readTextFile, theme } from "herdr";

const HOOKED = new Set(["claude-code", "codex", "opencode"]);
const SUPPORT = "/Library/Application Support/TalkToMe";

export default class TalkToMe extends View {
  init(_props, cx) {
    this.player = null;
    this.error = null;
    this.status = {}; // agent address -> last status
    this.base = null;
    this.token = null;
    cx.spawn(async (cx) => {
      await this.connect();
      await this.poll();
      cx.notify();
    });
    cx.timer.every(1000, (cx) => {
      cx.spawn(async (cx) => {
        await this.watchAgents();
        await this.poll();
        cx.notify();
      });
    });
  }

  async connect() {
    const root = home() + SUPPORT;
    this.token = ((await readTextFile(root + "/token")) ?? "").trim();
    let port = 9932;
    try {
      port = JSON.parse((await readTextFile(root + "/settings.json")) ?? "{}").port ?? 9932;
    } catch (_) {}
    this.base = `http://127.0.0.1:${port}`;
  }

  async api(method, path, body) {
    if (!this.token) await this.connect();
    const res = await fetch(this.base + path, {
      method,
      headers: { authorization: `Bearer ${this.token}`, "content-type": "application/json" },
      body: body ? JSON.stringify(body) : method === "GET" ? undefined : "{}",
    });
    return res.json();
  }

  async poll() {
    try {
      this.player = await this.api("GET", "/v1/player");
      this.error = null;
    } catch (_) {
      this.player = null;
      this.error = "not running";
    }
  }

  // working -> done/idle on an agent without a native hook: announce it
  async watchAgents() {
    for (const a of agents()) {
      const before = this.status[a.address];
      this.status[a.address] = a.status;
      const finished = before === "working" && (a.status === "done" || a.status === "idle");
      if (!finished || HOOKED.has(a.app ?? "")) continue;
      const who = a.app || a.program?.name || "An agent";
      const where = a.tab_name || a.space_name || "";
      try {
        await this.api("POST", "/v1/speak", {
          text: where ? `${who} finished in ${where}.` : `${who} finished.`,
          format: "text",
          policy: "queue",
          source: { app: "herdr", label: where, session: a.address },
        });
      } catch (_) {}
    }
  }

  render(_cx) {
    const t = theme();
    const p = this.player;
    const speaking = p && p.state !== "idle";
    const label = !p
      ? `Talk to Me: ${this.error ?? "connecting…"}`
      : speaking
        ? `${p.state === "paused" ? "Paused" : "Speaking"}: ${[p.app, p.label].filter(Boolean).join(" · ")} (${Math.min(p.index + 1, p.count)}/${p.count})${p.queued ? `, ${p.queued} queued` : ""}`
        : "Talk to Me: idle";
    const button = (id, text, onClick) =>
      div()
        .id(id)
        .px(8)
        .rounded(4)
        .cursor_pointer()
        .text_color(t.foreground)
        .hover((s) => s.bg(t.hover))
        .on_click((_e, cx) => {
          cx.spawn(async (cx) => {
            await onClick();
            await this.poll();
            cx.notify();
          });
        })
        .child(text);
    return h_flex()
      .id("talk-to-me")
      .size_full()
      .px(10)
      .gap(8)
      .items_center()
      .bg(t.chrome)
      .text_size(12)
      .child(div().text_color(speaking ? t.accent : t.dim).child("〰"))
      .child(div().flex_1().truncate().text_color(speaking ? t.foreground : t.muted).child(label))
      .when(Boolean(speaking), (el) =>
        el
          .child(button("toggle", p.state === "paused" ? "▶" : "⏸", () => this.api("POST", "/v1/player/toggle")))
          .child(button("stop", "■", () => this.api("POST", "/v1/player/stop"))),
      );
  }
}
