# Talk to Me: plan

A macOS menu bar app that reads text aloud with local TTS models on Apple
Silicon (Metal). Agents (Claude Code, OpenCode, Codex, herdr), the browser,
Finder, and a global hotkey all send text to it, and it speaks the text through
one shared queue.

Status: planning. Nothing is built yet.

---

## 1. What we learned from the references

**kokoro-reader** (`~/dev/kokoro-reader`)
- Runs Kokoro-82M through llama.cpp's `llama-server` (`/tts` endpoint, port 9931).
- Its Chrome extension (MV3) already handles text extraction, "read last reply"
  for Claude and ChatGPT, element picking, sentence highlighting, and
  prev/pause/next/stop. All of that is in `extension/lib/text.js`, and it
  carries over to this project almost unchanged.
- Chunks by sentence (about 220 chars max) and prefetches the next chunk. It
  measured roughly 2-3 s per 20-word sentence on Metal through `llama-server`.
  That number needs re-measuring in-process (see Phase 0).

**local-tts** (saghul, Python)
- Uses an ElevenLabs-compatible HTTP API, outputs PCM 24 kHz s16 mono, and
  lazy-loads models.
- Exposes an MCP endpoint (`POST /mcp`, one tool `text_to_speech`) that plays
  audio on the server's output device.
- Shows that people want "agent says something, and the machine speaks it."
  It has no queue, no menu bar, and no hooks.

**llama.cpp** (`~/llama.cpp`, at `41d8297fe`). This is the key finding.
- `libmtmd` has a C API for generating audio
  (`mtmd_gen_audio_*`, `mtmd_helper_gen_audio_*`). It covers 13 pipelines,
  including Kokoro, tiny-voca, Soprano, Chatterbox, ZONOS3, Qwen3-TTS and
  VoxCPM2.
- `tools/tts/tts.cpp` (261 lines) is a generic driver loop that works for every
  one of those models. We port it into one engine shim.
- English text-to-phoneme conversion for Kokoro and tiny-voca lives in the
  model's `tts` chat template. The template is applied by
  `common_chat_get_tts_prompt()`, which is **C++ in `common/`**, not C. That is
  why we need a small C++ shim with an `extern "C"` surface.
- The audio generation API is marked **EXPERIMENTAL, subject to breaking
  changes**, so we pin llama.cpp to a specific commit.

The conclusion: we do not write a TTS runtime. We embed llama.cpp with Metal
in-process and spend our effort on the app.

---

## 2. Architecture

```
┌─────────────────────────── TalkToMe.app (arm64, LSUIElement) ───────────────────────────┐
│                                                                                         │
│  macOS shell (Swift / SwiftUI)            ← thin: only what needs AppKit                 │
│   • NSStatusItem menu        • Settings window (VoiceInk-style sidebar)                  │
│   • NSServices provider      • Global hotkeys + AX selection grab                         │
│   • "Open With" for .md/.txt • Launch at login (SMAppService), permissions                │
│                    │  C ABI: include/talk.h (JSON in/out + event callback)                │
│  ┌─────────────────▼───────────────────────── libtalk (Zig) ──────────────────────────┐  │
│  │ server/   HTTP on 127.0.0.1:9932 · SSE events · MCP (streamable HTTP) · token auth │  │
│  │ queue/    jobs, sources, policies (queue / interrupt / replace), history           │  │
│  │ text/     markdown → speakable text (md4c) · sentence chunker with char offsets    │  │
│  │ engine/   one worker thread owns the Metal context; synthesize chunk N+1 during N  │  │
│  │ audio/    AudioToolbox AudioQueue, float32 PCM, pause/resume/seek by chunk         │  │
│  │ models/   catalog.json · HF downloader (resume, sha256) · lazy load / idle unload  │  │
│  │ config/   ~/Library/Application Support/TalkToMe/settings.json                     │  │
│  └─────────────────┬──────────────────────────────────────────────────────────────────┘  │
│                    │  C ABI: engine/talk_engine.h                                         │
│  engine shim (C++, built by CMake with llama.cpp) → libllama + libmtmd + ggml-metal       │
└─────────────────────────────────────────────────────────────────────────────────────────┘
        ▲ HTTP + token                  ▲ HTTP + token            ▲ Services / hotkey / Open With
  `talktome` CLI (Zig) ◄── hooks: Claude Code, Codex, OpenCode       Finder, any app's selection
  herdr mod · Chrome extension (fork of kokoro-reader)
```

### Why Zig core plus a Swift shell (decided 2026-11-19)

This is the Ghostty model: a Zig library does the real work, and a thin
Swift/SwiftUI app wraps it on macOS.
- About 85% of the code (engine, queue, text, audio, server, downloader, CLI)
  is Zig.
- The settings window you described (VoiceInk's sidebar, model cards with
  download progress, voice grid, shortcut recorder) is a few hundred lines of
  SwiftUI. Building the same window through `objc_msgSend` from Zig would be
  thousands of lines and slow to iterate on.
- **Rejected alternative:** pure Zig with `zig-objc`. One language, but the
  menu bar and NSServices would be hand-rolled Objective-C runtime calls, and
  the settings window would be painful.
- **Rule:** the Swift side holds no app logic. It renders state that comes from
  libtalk and sends commands back through `talk.h`. Anything the CLI or HTTP API
  can also do lives in Zig.

### Process model
- One process. The menu bar app hosts the engine and the HTTP server.
- `talktome` (the CLI, also used by hooks) is a small HTTP client. If the server
  doesn't answer, it runs `open -g -a TalkToMe`, waits for `/v1/health`, then
  retries.
- Models are lazy-loaded on the first job and unloaded after N minutes idle
  (setting, default 15). Kokoro holds about 270 MB resident.

### Threads
- **engine:** the only thread that touches llama/mtmd. Synthesis requests are
  serialized here.
- **audio:** the AudioQueue callback pulls from a PCM ring buffer.
- **server:** the HTTP accept loop and per-connection handlers. SSE fan-out
  runs from an event bus.
- **queue:** coordinates work. It keeps the engine at most one chunk ahead of
  playback (configurable), so pausing never wastes GPU time.

### Build
- `vendor/llama.cpp` is a git submodule pinned to `41d8297fe`.
- `engine/CMakeLists.txt` builds llama.cpp static with `GGML_METAL=ON`,
  `GGML_METAL_EMBED_LIBRARY=ON`, `BUILD_SHARED_LIBS=OFF`, `LLAMA_OPENSSL=OFF`,
  and with tools, server and tests off.
  - The **engine shim is built by the same CMake and compiler (Apple clang)**,
    so every C++ object shares the system libc++.
  - `libtool` merges the shim, mtmd, llama-common, llama, the ggml backends and
    vendor-hash into one archive, `libtalk_engine_all.a` (27 MB).
  - Zig only ever sees the C ABI in `engine/talk_engine.h`, through
    `addTranslateC`.
- **Final links use Apple's `clang++`/ld, not Zig's linker.** Zig 0.17's Mach-O
  linker fails on the llama.cpp archive ("failed to resolve relocations and
  write atoms: Overflow") in both debug and release. So Zig emits an object (or
  `libtalk.a`), and `xcrun clang++` links it with the engine archive and
  Foundation, Metal, MetalKit and Accelerate. Xcode will do the same for the
  app.
- `zig build` runs CMake, compiles the Zig code, and links through `appleLink()`
  in `build.zig`.
- `zig build app` (later) runs `xcodebuild` for the Swift shell, which links
  `libtalk.a` plus the engine archive.
- Pins: Zig 0.17.0, macOS 14.0 minimum (set in both CMake and `build.zig`), arm64
  only.
- Before shipping, set `GGML_NATIVE=OFF` with an explicit Apple Silicon
  baseline. It currently builds with `-mcpu=native`, tuned to whichever M-chip
  runs the build.

---

## 3. Core concepts and API shape

### Job
```jsonc
{
  "text": "…",                        // or "chunks": ["…","…"] (browser sends pre-split text so highlight indexes match)
  "format": "markdown",               // "markdown" | "text"
  "source": {
    "app": "claude-code",             // claude-code | opencode | codex | herdr | browser | file | selection | cli
    "label": "talk-to-me",            // shown in menu, optionally announced ("Claude, in talk-to-me")
    "session": "8f2c…"                // used by the "replace" policy
  },
  "voice": "af_heart",                // optional: falls back to the source override, then the global default
  "model": "kokoro",                  // optional
  "speed": 1.0,                       // optional
  "policy": "queue"                   // queue | interrupt | replace | drop_if_busy
}
```

**Policies**
- `queue`: default for agents. Several agents finishing at once take turns.
- `interrupt`: default for things you start yourself (hotkey, Services, file,
  CLI). Stops the current item and plays now. The interrupted item can stay
  resumable as "paused" in the queue (setting).
- `replace`: drops pending, unstarted jobs with the same `source.session`. A
  new reply supersedes a stale one from the same agent session.
- `drop_if_busy`: skipped if anything is playing. Meant for status chatter.

**Dedupe.** Identical text from the same source within 30 s is dropped. This
covers herdr and a native hook both firing for the same reply.

### HTTP API (`http://127.0.0.1:9932`)

| Method | Path | Purpose |
|---|---|---|
| GET | `/v1/health` | version, model loaded, queue depth |
| POST | `/v1/speak` | enqueue a Job → `202 {job_id}` |
| POST | `/v1/speak/file` | `{path, policy?}`: only `.md` `.markdown` `.txt`, size cap (default 2 MB) |
| GET | `/v1/jobs` · `/v1/jobs/{id}` | queue and history |
| DELETE | `/v1/jobs/{id}` | remove a pending job |
| GET | `/v1/player` | state: idle / playing / paused, current job, chunk i/n |
| POST | `/v1/player/{pause,resume,toggle,stop,next,previous,skip}` | transport (`next`/`previous` = sentence, `skip` = whole job) |
| GET | `/v1/events` | SSE: `job.queued` `job.started` `chunk.started{job,index,range}` `job.finished` `player.state` `model.progress` |
| GET | `/v1/models` | catalog plus installed/active state |
| POST | `/v1/models/{id}/download` · DELETE `/v1/models/{id}` · POST `/v1/models/{id}/activate` | model management |
| GET | `/v1/voices?model=` | voices with tags (accent, gender), default marked |
| POST | `/v1/audio/speech` | OpenAI-compatible: returns WAV and does **not** play. Lets other tools use us as a TTS backend. |
| POST | `/mcp` | MCP (streamable HTTP): tools `speak{text, voice?, policy?}`, `stop`, `list_voices` |

**Security.** Any web page can POST to localhost, so we lock this down.
- Bind to `127.0.0.1` only.
- Check that the `Host` header is `127.0.0.1:9932` or `localhost:9932`. This
  blocks DNS rebinding.
- Require `Authorization: Bearer <token>`. The token lives in
  `~/Library/Application Support/TalkToMe/token`, mode 0600, created on first
  run. The CLI and hooks read the file. The browser extension gets the token
  through a pairing step that you approve from the menu bar.
- Reject any `Origin` that isn't the paired extension ID.

**MCP vs hooks.** MCP only runs when the model decides to call the tool, which
costs tokens and isn't reliable for "always read the reply." Hooks are the
primary, deterministic path for end-of-turn reading. MCP is for an agent
deliberately saying something, like "tell me when the build finishes."

### C ABI for the Swift shell (`include/talk.h`)
```c
talk_t *talk_init(const char *support_dir, talk_event_cb cb, void *user);
void    talk_deinit(talk_t *);
int     talk_speak(talk_t *, const char *job_json, char *job_id_out, size_t n);
int     talk_player(talk_t *, const char *cmd);              // "pause", "stop", …
char   *talk_get(talk_t *, const char *what);                // "models" | "voices" | "queue" | "settings" → JSON, free with talk_free
int     talk_set_settings(talk_t *, const char *patch_json);
int     talk_model_download(talk_t *, const char *id);       // progress arrives through cb
int     talk_preview_voice(talk_t *, const char *model, const char *voice);
void    talk_free(char *);
```
The events delivered to `cb` are the same JSON events SSE sends, so there is one
event schema.

### CLI `talktome`
```
talktome "Hello"                 talktome notes.md               pbpaste | talktome
talktome --voice am_michael --speed 1.2 --policy queue chapter.md
talktome stop | pause | resume | skip | next | previous | status
talktome voices [--model kokoro] | talktome models
talktome hook claude|codex|opencode    # adapters: read the agent's payload, extract the reply, POST /v1/speak
```
Settings → General has a button to install `~/.local/bin/talktome` as a symlink to
the binary inside the app bundle.

---

## 4. Text pipeline

1. **Markdown → speakable text** with md4c (C, vendored), walking the AST:
   - Headings, paragraphs and list items each become a sentence, followed by a
     pause.
   - Fenced code: **skip and say "code block"** (default). Options: skip
     silently, or read it.
   - Inline code: read the text inside the backticks.
   - Links: read the link text. A bare URL is spoken as its domain.
   - Images: read the alt text, or skip.
   - Tables: "table with N rows" (default), or read the rows.
   - Emoji and box-drawing characters are stripped. File paths are read as
     their basename (option).
2. **Pronunciation dictionary:** user-defined regex/word → replacement, applied
   before phonemization (for example `kubectl → cube control`). tiny-voca also
   supports inline phonemes.
3. **Chunker:** sentence split, up to about 220 chars or under 510 phonemes,
   with long sentences split at commas or spaces. Each chunk keeps its character
   range into the original text so the browser can highlight.
4. **Agent reply limits:** speak at most N sentences or M chars of an agent
   reply (setting per source, default unlimited), then say "…and more."

The engine shim applies the model's `tts` template (text normalization and
grapheme-to-phoneme) per chunk.

---

## 5. Inputs

| Input | How |
|---|---|
| Agents | Hooks and plugins call `talktome hook …` (§6) |
| Browser | Forked kokoro-reader extension → `/v1/speak` + `/v1/events` (§6) |
| Right-click selected text in any app | **NSServices** "Read Aloud with Talk to Me" (accepts text) |
| Right-click a `.md`/`.txt` in Finder | **NSServices** for file URLs filtered to `public.plain-text` and `net.daringfireball.markdown`. Shows under Quick Actions / Services. A top-level Finder Sync extension item is a later option. |
| Open With / drag onto icon | Register as an *Alternate* viewer for `.md`/`.txt` (`CFBundleDocumentTypes`) |
| **Global hotkey: Read Selection** | One key does both. If Finder is frontmost and files are selected (Apple Events: `tell application "Finder" to get selection`), read the `.md`/`.txt` files in order. Otherwise read the focused element's `AXSelectedText`, falling back to a synthetic ⌘C with the clipboard saved and restored. Needs Accessibility and Automation→Finder permission (Permissions page). |
| Other hotkeys | Pause/Resume, Stop, Read Clipboard, Skip |

**Global hotkey defaults** (decided). None of them use Space.

| Keys | Action |
|---|---|
| **⌥⇧R** | Read selection: selected files in Finder, selected text anywhere else |
| **⌥⇧P** | Pause / resume |
| **⌥⇧X** | Stop |
| (unset) | Read clipboard, skip to next item |

All of them can be rebound with the `KeyboardShortcuts` package, the same one
VoiceInk uses.

**What this means for the browser extension.** A global hotkey wins over a
Chrome command on the same keys. kokoro-reader uses ⌥⇧S/R/A/X, so the fork
changes:
- **Drops** its read-selection (⌥⇧S) and stop (⌥⇧X) commands. With one queue,
  the global ⌥⇧R and ⌥⇧X already do those in the browser.
- **Moves** "read last reply" from ⌥⇧R to **⌥⇧L**.
- **Keeps** "read page" on ⌥⇧A.

**Side effect.** On a US layout, ⌥⇧ plus a letter types a special character
(⌥⇧R types ‰, ⌥⇧P types ∏). Once the hotkeys are registered, those characters
can't be typed. That's rarely a problem, and the Shortcuts page can rebind
any key.

---

## 6. Integrations

All of these live in `integrations/`, and Settings → Sources can install them
and shows whether each is detected.

**Claude Code** is a plugin (`integrations/claude-code/`, published from a
marketplace in this repo).
- A `Stop` hook runs `talktome hook claude`. It reads the hook JSON from stdin, uses
  `last_assistant_message` when present, and otherwise reads the last assistant
  text from `transcript_path`.
- `source.label` is the basename of `cwd`, `source.session` is `session_id`,
  and the policy is `replace`.
- `SubagentStop` is ignored.
- The plugin also declares the MCP server (`http://127.0.0.1:9932/mcp`).

**Codex CLI** uses `notify = ["talktome", "hook", "codex"]` in `~/.codex/config.toml`.
- Codex passes a JSON argument (`type: "agent-turn-complete"`,
  `last-assistant-message`).
- ⚠ Your config already sets `notify` to the Computer Use client, and Codex
  allows only one notify program. `talktome hook codex --chain <previous argv…>`
  runs the old one too, and the installer rewrites the line to preserve it.

**OpenCode** gets a plugin file in `~/.config/opencode/plugin/talk-to-me.ts`.
- On the `session.idle` event, it fetches the session's last assistant message
  through the plugin client and POSTs it.

**herdr** gets a mod (`integrations/herdr/`, gpui-kit JS).
- It watches `agents()` for working → done transitions.
- It adds a small control (speaking indicator, pause and stop) to the
  status/terminals bar through `fetch` to our API.
- For agents without a native hook, it can read the agent's final screen output
  with `hc` and speak it. A per-agent setting covers this, and the server's
  dedupe prevents double reads when both the hook and herdr fire.

**ChatGPT** has two surfaces with different limits.
- ChatGPT web: the extension's "auto-read replies" mode. A MutationObserver
  waits for the reply to finish (the stop button goes away), then reads the
  last reply with the existing `lastReplyClip` selectors.
- ChatGPT desktop app: there is no plugin API, so it's covered by the Read
  Selection hotkey and Services. An Accessibility watcher is possible later but
  fragile.

**Browser extension** (`integrations/chrome/`, a fork of kokoro-reader)
- Replace the offscreen `/tts` fetch with `POST /v1/speak` carrying `chunks`.
  The extension keeps its own extraction and chunking, so its range mapping
  stays valid.
- Playback moves into the app, so browser and agent speech share one queue and
  one pause button.
- Highlighting follows `chunk.started` events from `/v1/events` (SSE).
- Transport buttons call `/v1/player/*`.
- The 20 Hz keep-alive tone hack goes away (no more offscreen audio).
- Pairing: the popup asks the app for a token, and the menu bar shows "Allow
  Chrome extension to connect?"

---

## 7. UI

### Menu bar icon
A waveform SF Symbol that animates while speaking and is dimmed when there's no
model. Clicking it opens:
```
● Speaking: Claude · talk-to-me (3/12)      ← or "Idle", or "No model: Download Kokoro (270 MB)…"
──────────────
Pause                          ⌥⇧P
Stop                           ⌥⇧X
Skip to next item
──────────────
Read Selection                 ⌥⇧R
Read Clipboard
Open File…
──────────────
Queue                          ▸   (pending items; click to remove)
Voice                          ▸   (favorites + default, checkmark)
Speed                          ▸   0.8× 1.0× 1.2× 1.5×
Sources                        ▸   ✓ Claude Code ✓ OpenCode ✓ Codex ✓ Browser · Mute all agents
──────────────
Settings…                      ⌘,
Quit Talk to Me
```

### Settings window
This follows VoiceInk's layout: a `NavigationSplitView` with an SF Symbol
sidebar on the left and a scrolling page of grouped cards on the right.

| Sidebar | Contents |
|---|---|
| **General** | Launch at login, output device, default policy for agents vs. you, announce source name, chime before reading, idle unload minutes, install `talktome` CLI |
| **Models** | One card per model, like VoiceInk's "AI Models" page: name, size, speed and quality meters, **Recommended** badge, languages, Download (progress, cancel) / Set default / Delete. Filter: All · Installed |
| **Voices** | Grid for the selected model: name, accent (US/UK), gender, ▶ preview (sample sentence), ☆ favorite, set default, speed slider |
| **Sources** | One row per integration: installed status and Install button, enabled, voice override (for example Claude = `af_heart`, Codex = `am_michael`, so you know who's talking by ear), announce prefix, policy, reply length cap. Chrome pairing lives here |
| **Reading** | Markdown options (code blocks, tables, links, emoji, paths), pronunciation dictionary |
| **Shortcuts** | Hotkey recorders |
| **History** | Last 200 spoken items: source, time, ▶ replay, copy text |
| **Permissions** | Accessibility and Automation (Finder): status and "Open System Settings" |
| **About** | Version, llama.cpp commit, licenses |

**First run.** No model is downloaded. The menu bar shows a dot, and the
Settings window opens on Models with Kokoro highlighted and the text
"Recommended · 270 MB · Download."

---

## 8. Models

The catalog ships inside the app as `catalog/models.json`. Each entry lists the
HF repo, a pinned revision, the files, sha256 hashes, sizes, the pipeline type
and voice metadata. Files download to
`~/Library/Application Support/TalkToMe/models/<id>/` from
`https://huggingface.co/<repo>/resolve/<rev>/<file>`, with HTTP Range resume
and hash checks. The app never uses `~/.cache/huggingface`.

All of these exist today as `ggml-org` GGUFs:

| Model | Files (size) | Voices | Notes | Ships |
|---|---|---|---|---|
| **Kokoro 82M** ⭐ Recommended | F32 62 MB + mmproj F16 208 MB ≈ **270 MB** | 28 English (20 US `a*`, 8 UK `b*`) | Not autoregressive (fast, deterministic), built-in English G2P | v1 |
| tiny-voca | 12 + 14 MB ≈ **26 MB** | `M2`, `F2` | Fastest. Richest text normalization (numbers, units, URLs). Lower quality | v1.1 |
| Soprano 1.1 80M | Q8_0 85 + 61 MB ≈ **146 MB** | 1 fixed | Needs normalized English text | v1.1 |
| Chatterbox Turbo | Q8_0 482 + 555 MB ≈ **1.0 GB** | `default` (+ cloning later) | Expressive, autoregressive | v1.2 |
| ZONOS3 Mini | Q8_0 855 + 1143 MB ≈ **2.0 GB** | many predefined (US/UK) | Speed and loudness control, cloning | v1.2 |
| Qwen3-TTS 1.7B Base | Q4_K_M 1036 + 446 MB ≈ 1.5 GB | needs a reference clip | Cloning only (Base). Defer | later |

The engine shim ports the generic `tts.cpp` loop, so adding a model means
writing a catalog entry and testing it, not new engine code. English only for
now: the Voices page filters to `a*`/`b*` for Kokoro.

---

## 9. Decisions

All decided 2026-11-19.

1. **UI shell:** a thin Swift/SwiftUI shell over a Zig core (libtalk).
2. **Browser playback:** the app plays everything, so there's a single queue.
   The extension only extracts text, highlights and sends transport commands.
3. **Agent replies:** read the whole reply and skip code blocks (announced as
   "code block"). No length cap by default, though each source can set one.
4. **Several agents finishing at once:** queue them all, in arrival order (the
   `queue` policy).
5. **Global hotkeys:** ⌥⇧R read selection, ⌥⇧P pause/resume, ⌥⇧X stop. Space
   is never used. The extension's keys move to avoid them (§5).
6. **Name:** the app is "Talk to Me" and the CLI is `talktome`. The bundle ID is
   chosen at signing time (Phase 6).

---

## 10. Phases

Each phase ends with something usable.

**Phase 0: engine spike (gate)**
- llama.cpp submodule, CMake static Metal build, and the C++ shim
  `talk_engine_synthesize(text, voice, speed) → float PCM`.
- Called from a Zig test binary that writes a WAV.
- Measure the following for Kokoro on the M4: load time, time to first audio
  for a 20-word sentence, real-time factor, and resident memory.
- *Done when:* Zig produces correct Kokoro audio with Metal and we have the
  numbers. If it really is 2-3 s per sentence in-process, profile it
  (vocoder on GPU vs CPU, template cost) before going further.

**Phase 0 results (done 2026-11-19, Apple M4, macOS 15.7)**

Run with `zig build --release spike -- [--voice V] [--speed S] [--cpu] ["text"]`
(source: `src/spike.zig`). Median of 3 runs, voice `af_heart`:

| Text | Chars | Synthesis | Audio | Faster than real time |
|---|---|---|---|---|
| "Okay, done." | 11 | 0.59 s | 1.6 s | 2.7× |
| short | 34 | 0.89 s | 2.4 s | 2.7× |
| medium (~20 words) | 116 | 2.68 s | 7.3 s | 2.7× |
| long | 204 | 4.69 s | 12.7 s | 2.7× |

- Model load: **0.5–1.0 s** (warm). First synthesis after load: 0.5–0.85 s.
  Peak RSS: **430 MB**. The engine reports 54 voices, 24 kHz mono.
- **The first load after each new build takes 12–14 s.** With
  `GGML_METAL_EMBED_LIBRARY=ON`, ggml embeds the Metal *source* and compiles it
  at runtime. macOS caches the result, so later loads are fast again. An
  installed app would pay this on first launch and after every update. **Fix
  (Phase 2):** build with `GGML_METAL_EMBED_LIBRARY=OFF` so CMake precompiles
  `default.metallib` (plus `ggml-tensor.metallib`), and ship them in the app's
  `Contents/Resources`, where ggml finds them through
  `NSBundle pathForResource`. This needs the `metal` compiler, which comes with
  full Xcode, not the Command Line Tools (this machine has only the CLT).
- Nearly all the time (about 97%) is the vocoder (`GEN_WAV`). The phonemizer
  template and backbone take 10–80 ms.
- CPU-only is 1.9× faster than real time (613 MB RSS), so Metal is only about
  1.4× faster than CPU. The vocoder graph runs entirely on Metal (1 split), so
  it isn't falling back to the CPU. Its kernels are just slow.
- The numbers match kokoro-reader's 2–3 s per sentence. `llama-server` wasn't
  the bottleneck. Kokoro's vocoder in llama.cpp is.
- Voice selection (`bm_george`) and speed (1.3×) work. The audio is clean
  (RMS about 0.05, no clipping).

**What this means for the design**
- **2.7× faster than real time is enough.** With one chunk prefetched, the
  engine stays ahead of playback after the first chunk, so the plan stands.
- **Time to first audio scales with the first chunk's length**, not a fixed
  overhead. The chunker therefore emits a **short first chunk** (the first
  clause, up to about 60 chars, giving about 0.6 s to first sound), then
  normal 220-char chunks.
- The engine thread synthesizes chunk N+1 while N plays. When idle, the model
  stays warm (load costs 1 s).
- Follow-up (not blocking): profile the Kokoro vocoder kernels on Metal
  (`conv_transpose_1d`, `conv_1d`, iSTFT path in `tools/mtmd/models/kokoro.cpp`).
  MLX ports of Kokoro run much faster on the same hardware, so a fix there
  (upstream, ideally) could bring a 5–10× gain.

**Shim notes**
- `te_load` mirrors what `common_params_parse` does after parsing, including
  `postprocess_cpu_params()`. Without it, `n_threads = -1` produces a garbage
  allocation (about 17 PB) at the first decode.
- Synthesis follows the server's order: `reset → set_input → step_prompt… →
  step_gen… → flush → get_output`, in PCM mode. One engine is reused across
  calls.

**Phase 1: core and CLI**
- Engine thread, md4c markdown, chunker, AudioQueue player with one-chunk
  prefetch, queue and policies, settings file, token auth, the HTTP API (without
  MCP), the `talktome` CLI and the model downloader.
- *Done when:* `talktome README.md` reads aloud with stop, pause, resume, next and
  previous, and `talktome models` downloads Kokoro.

**Phase 2: Mac shell**
- Xcode project linking `libtalk.a`, the menu bar menu, and the settings
  window (General, Models, Voices) with first-run onboarding.
- Requires full Xcode (for `xcodebuild` and the `metal` compiler). Switch the
  engine to a precompiled `default.metallib` in `Contents/Resources` so the
  first launch skips the 12–14 s shader compile.
- *Done when:* starting from a fresh install, you can download Kokoro, preview
  voices and pick one, all from the UI.

**Phase 3: system inputs**
- Services for text and files, Open With, global hotkeys (AX selection grab,
  Finder selection), and the Permissions and Shortcuts pages.
- *Done when:* right-clicking selected text or a `.md` reads it, and ⌥⇧R works
  in Safari, Notes and Finder.

**Phase 4: agents**
- `talktome hook claude|codex|opencode`, the Claude Code plugin, the Codex notify
  chain, the OpenCode plugin, the herdr mod, the MCP endpoint, dedupe, and the
  Sources page.
- *Done when:* finishing a turn in each agent speaks the reply with that
  source's voice.

**Phase 5: browser**
- Fork the extension, add pairing, SSE highlighting, and ChatGPT and Claude
  auto-read.
- *Done when:* the kokoro-reader e2e test passes against the new backend.

**Phase 6: more models and polish**
- tiny-voca, Soprano, Chatterbox Turbo and ZONOS3; History; pronunciation
  dictionary; Developer ID signing and notarization; launch at login.

---

## 11. Repo layout

```
talk-to-me/
  build.zig  build.zig.zon
  vendor/llama.cpp            (submodule, pinned)    vendor/md4c
  engine/                     CMakeLists.txt  talk_engine.h  talk_engine.cpp   (C++ shim over mtmd + common)
  include/talk.h              C ABI for the shell
  src/                        Zig core
    lib.zig  cli.zig  engine.zig  queue.zig  config.zig  events.zig
    text/markdown.zig  text/chunk.zig  text/dictionary.zig
    audio/player.zig          (AudioToolbox AudioQueue)
    server/http.zig  server/sse.zig  server/mcp.zig  server/auth.zig
    models/catalog.zig  models/download.zig
  catalog/models.json
  macos/                      Xcode project: App, MenuBar, Settings/*, Services, Hotkeys, Permissions
  integrations/
    claude-code/  codex/  opencode/  herdr/  chrome/
  docs/PLAN.md
```

## 12. Risks

- **llama.cpp audio API churn.** It's marked experimental. Pin the commit,
  confine all contact to `engine/`, and bump deliberately.
- **Kokoro latency.** It's unknown in-process. Phase 0 is a gate for exactly
  this reason.
- **Mixing C++ runtimes.** Avoid it by building every C++ object with Apple
  clang through CMake and exposing only C to Zig.
- **Selection grab reliability.** AX selected text fails in some apps
  (Electron, terminals). The ⌘C fallback covers most of them, at the cost of a
  brief clipboard swap.
- **Zig std HTTP/TLS for HF downloads.** If it's flaky, move downloads to
  `URLSession` in the shell (progress comes through the same event
  callback). The CLI would then download through the app.
