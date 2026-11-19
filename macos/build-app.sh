#!/bin/sh
# Assemble zig-out/TalkToMe.app from the SwiftPM build. Run via `zig build app`,
# which builds zig-out/lib (libtalk.a, engine archive) and zig-out/bin first.
set -eu

ROOT=$(cd "$(dirname "$0")/.." && pwd)
OUT="$ROOT/zig-out"
APP="$OUT/TalkToMe.app"

swift build -c release --package-path "$ROOT/macos" --arch arm64
BIN=$(swift build -c release --package-path "$ROOT/macos" --arch arm64 --show-bin-path)

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN/TalkToMe" "$APP/Contents/MacOS/TalkToMe"
cp "$ROOT/macos/Resources/Info.plist" "$APP/Contents/Info.plist"
# precompiled Metal shaders: ggml finds them through the main bundle
cp "$OUT/bin/default.metallib" "$OUT/bin/ggml-tensor.metallib" "$APP/Contents/Resources/"
# SwiftPM resource bundles (KeyboardShortcuts localizations); Bundle.module
# looks for them in Contents/Resources
for b in "$BIN"/*.bundle; do [ -e "$b" ] && cp -R "$b" "$APP/Contents/Resources/"; done
# the CLI ships inside the app; Settings → General links it into ~/.local/bin
cp "$OUT/bin/talktome" "$APP/Contents/Resources/talktome"

# ad-hoc signature (Developer ID signing and notarization come in Phase 6)
codesign --force --deep --sign - "$APP" >/dev/null
echo "built $APP"
