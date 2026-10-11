#!/usr/bin/env bash
set -euo pipefail
MODE="${1:-run}"
ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT_DIR"
pkill -x HermesMac >/dev/null 2>&1 || true
xcodebuild -project HermesMac.xcodeproj -scheme HermesMac -configuration Debug -derivedDataPath DerivedData CODE_SIGN_IDENTITY=- build > /tmp/hermes-mac-build.log 2>&1 || { tail -80 /tmp/hermes-mac-build.log; exit 1; }
APP_BUNDLE="$ROOT_DIR/DerivedData/Build/Products/Debug/HermesMac.app"
case "$MODE" in
  --build) exit 0 ;;
  run) /usr/bin/open -n "$APP_BUNDLE" ;;
  --verify) /usr/bin/open -n "$APP_BUNDLE"; sleep 1; pgrep -x HermesMac >/dev/null ;;
  --debug) lldb -- "$APP_BUNDLE/Contents/MacOS/HermesMac" ;;
  --logs) /usr/bin/open -n "$APP_BUNDLE"; /usr/bin/log stream --info --style compact --predicate 'process == "HermesMac"' ;;
  --telemetry) /usr/bin/open -n "$APP_BUNDLE"; /usr/bin/log stream --info --style compact --predicate 'subsystem == "com.hermes.mac"' ;;
  *) echo "usage: $0 [run|--build|--verify|--debug|--logs|--telemetry]" >&2; exit 2 ;;
esac
