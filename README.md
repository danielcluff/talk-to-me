# Talk to Me

Local text-to-speech for macOS on Apple Silicon. Agents, the browser, Finder
and the command line send text to one queue, and it's read aloud with Kokoro
running in-process on Metal through llama.cpp. Nothing leaves the machine.

Status: Phase 2 (menu bar app, Settings with Models and Voices). Phase 3
(Services, hotkeys) is next. See [docs/PLAN.md](docs/PLAN.md).

## Build

Requirements: Apple Silicon, macOS 14+, Zig 0.17.0, CMake, Ninja, Xcode 26.3
(the last release for Sequoia) with the Metal toolchain
(`xcodebuild -downloadComponent MetalToolchain`).

```sh
git submodule update --init
zig build --release        # builds llama.cpp (first time: a few minutes) and zig-out/bin/talktome
zig build test             # unit tests (markdown, chunker)
zig build app --release    # zig-out/TalkToMe.app (menu bar app)
open zig-out/TalkToMe.app
```

## Use

```sh
zig-out/bin/talktome models download kokoro   # 270 MB, verified by sha256
zig-out/bin/talktome README.md                # read a .md or .txt file
zig-out/bin/talktome "Hello there."           # read text
pbpaste | zig-out/bin/talktome                # read stdin (queued)
zig-out/bin/talktome pause | resume | next | previous | skip | stop
zig-out/bin/talktome status | jobs | voices | models | config
zig-out/bin/talktome config set voice bm_george
```

The first command starts the server (`talktome serve`) in the background if
it isn't running. Its log goes to `~/Library/Logs/TalkToMe/server.log`. Data
lives in `~/Library/Application Support/TalkToMe` (settings, API token,
models).

When the app is installed, the CLI launches it and talks to its server instead
of starting its own.

## API

`http://127.0.0.1:9932`, with `Authorization: Bearer $(cat ~/Library/Application\ Support/TalkToMe/token)`.

```sh
curl -s -X POST http://127.0.0.1:9932/v1/speak -H "Authorization: Bearer $TOKEN" \
  -d '{"text": "Build finished.", "source": {"app": "claude-code", "label": "my-repo"}, "policy": "queue"}'
```

Routes: `/v1/speak`, `/v1/speak/file`, `/v1/jobs`, `/v1/player[/cmd]`,
`/v1/events` (SSE), `/v1/models[/id/download|activate|cancel]`, `/v1/voices`,
`/v1/settings`, `/v1/health`. See §3 of the plan.
