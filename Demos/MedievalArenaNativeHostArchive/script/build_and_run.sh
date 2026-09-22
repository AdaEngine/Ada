#!/usr/bin/env bash
set -euo pipefail

MODE="${1:-run}"
APP_NAME="MedievalArena"
ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
BUILD_DIR="${MEDIEVAL_ARENA_BUILD_DIR:-$ROOT_DIR/.build-codex}"
DIST_DIR="$ROOT_DIR/dist"
APP_BUNDLE="$DIST_DIR/$APP_NAME.app"
APP_CONTENTS="$APP_BUNDLE/Contents"
APP_MACOS="$APP_CONTENTS/MacOS"
APP_RESOURCES="$APP_CONTENTS/Resources"
APP_BINARY="$APP_MACOS/$APP_NAME"
PORT="${MEDIEVAL_ARENA_PORT:-37777}"
HOST_LOG="/tmp/medieval-arena-host.log"
PEER_LOG="/tmp/medieval-arena-peer.log"

export CLANG_MODULE_CACHE_PATH="${CLANG_MODULE_CACHE_PATH:-/tmp/medieval-arena-module-cache}"
export SWIFT_MODULE_CACHE_PATH="${SWIFT_MODULE_CACHE_PATH:-/tmp/medieval-arena-module-cache}"

pkill -x "$APP_NAME" >/dev/null 2>&1 || true
rm -f "$HOST_LOG" "$PEER_LOG"

swift build --package-path "$ROOT_DIR" --scratch-path "$BUILD_DIR"
BIN_DIR="$(swift build --package-path "$ROOT_DIR" --scratch-path "$BUILD_DIR" --show-bin-path)"

rm -rf "$APP_BUNDLE"
mkdir -p "$APP_MACOS" "$APP_RESOURCES"
cp "$BIN_DIR/$APP_NAME" "$APP_BINARY"
chmod +x "$APP_BINARY"
cp "$ROOT_DIR/Support-Info.plist" "$APP_CONTENTS/Info.plist"
for resource_bundle in "$BIN_DIR"/*.bundle; do
  if [[ -d "$resource_bundle" ]]; then
    cp -R "$resource_bundle" "$APP_BUNDLE/"
    cp -R "$resource_bundle" "$APP_RESOURCES/"
  fi
done

open_host() {
  /usr/bin/open -n "$APP_BUNDLE" --args --host --port "$PORT" --diagnostics "$HOST_LOG"
}

open_peer() {
  /usr/bin/open -n "$APP_BUNDLE" --args --join ::1 --port "$PORT" --peer-index 1 --diagnostics "$PEER_LOG" "$@"
}

wait_for_host() {
  for _ in {1..40}; do
    if grep -q "listener ready" "$HOST_LOG" 2>/dev/null; then
      return 0
    fi
    sleep 0.25
  done
  echo "Medieval Arena host did not become ready." >&2
  return 1
}

case "$MODE" in
  run)
    open_host
    wait_for_host
    open_peer
    ;;
  --debug|debug)
    lldb -- "$APP_BINARY" --host --port "$PORT" --diagnostics "$HOST_LOG"
    ;;
  --logs|logs|--telemetry|telemetry)
    open_host
    wait_for_host
    open_peer
    tail -f "$HOST_LOG" "$PEER_LOG"
    ;;
  --verify|verify)
    open_host
    wait_for_host
    open_peer --bot
    for _ in {1..60}; do
      if grep -q "connected peer" "$HOST_LOG" 2>/dev/null \
        && grep -q "connected host" "$PEER_LOG" 2>/dev/null \
        && grep -q "damage target=" "$HOST_LOG" 2>/dev/null; then
        break
      fi
      sleep 0.25
    done
    test "$(pgrep -x "$APP_NAME" | wc -l | tr -d ' ')" -ge 2
    grep -q "connected peer" "$HOST_LOG"
    grep -q "connected host" "$PEER_LOG"
    grep -q "damage target=" "$HOST_LOG"
    echo "Medieval Arena verified: two processes, handshake, authoritative damage."
    ;;
  *)
    echo "usage: $0 [run|--debug|--logs|--telemetry|--verify]" >&2
    exit 2
    ;;
esac
