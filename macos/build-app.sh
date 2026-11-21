#!/bin/sh
# Assemble zig-out/TalkToMe.app from the SwiftPM build. Run via `zig build app`,
# which builds zig-out/lib (libtalk.a, engine archive) and zig-out/bin first.
set -eu

ROOT=$(cd "$(dirname "$0")/.." && pwd)
OUT="$ROOT/zig-out"
APP="$OUT/TalkToMe.app"

BIN=$(swift build -c release --package-path "$ROOT/macos" --arch arm64 --show-bin-path)
# SwiftPM doesn't track libtalk.a (linked with -L/-l), so a rebuilt core
# would never reach the app: drop the old executable to force a relink
rm -f "$BIN/TalkToMe"
swift build -c release --package-path "$ROOT/macos" --arch arm64

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
# agent integrations, found by `talktome install` next to the CLI
cp -R "$ROOT/integrations" "$APP/Contents/Resources/integrations"

# Signing. macOS keys Accessibility (and other privacy) permissions to the
# code signature. An ad-hoc signature changes on every build, so macOS treats
# each build as a new app and the permission stops matching. A stable
# identity keeps it across rebuilds. Order: $TALKTOME_SIGN_IDENTITY, a
# "Talk to Me Dev" self-signed certificate, an "Apple Development"
# certificate (free with an Apple ID in Xcode), else ad hoc.
IDENTITY="${TALKTOME_SIGN_IDENTITY:-}"
if [ -z "$IDENTITY" ]; then
    IDS=$(security find-identity -v -p codesigning 2>/dev/null || true)
    for name in "Talk to Me Dev" "Apple Development"; do
        line=$(printf '%s\n' "$IDS" | grep -m1 "\"$name" || true)
        if [ -n "$line" ]; then
            IDENTITY=$(printf '%s\n' "$line" | awk '{print $2}')
            break
        fi
    done
fi
if [ -n "$IDENTITY" ]; then
    codesign --force --deep --sign "$IDENTITY" "$APP" >/dev/null
    echo "built $APP (signed with $IDENTITY)"
else
    codesign --force --deep --sign - "$APP" >/dev/null
    echo "built $APP (ad hoc: macOS may ask for Accessibility again after each build)"
fi
