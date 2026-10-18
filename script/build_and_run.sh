#!/usr/bin/env bash
set -euo pipefail
MODE="${1:-run}"
ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT_DIR"
SIGNING_IDENTITY="${HERMES_SIGNING_IDENTITY:-HermesMac Local Development}"
if [ "$SIGNING_IDENTITY" = "-" ]; then
  echo "Ad hoc signing cannot preserve credential access. Run ./script/setup_local_signing.sh and use HermesMac Local Development." >&2
  exit 1
fi
if [ "$SIGNING_IDENTITY" != "-" ] && ! security find-identity -v -p codesigning | grep -Fq "\"$SIGNING_IDENTITY\""; then
  echo "Signing identity '$SIGNING_IDENTITY' not found. Run ./script/setup_local_signing.sh once, or set HERMES_SIGNING_IDENTITY to a certificate name." >&2
  exit 1
fi
pkill -x HermesMacDev >/dev/null 2>&1 || true
xcodebuild -project HermesMac.xcodeproj -scheme HermesMac -configuration Debug -derivedDataPath DerivedData CODE_SIGN_STYLE=Manual "CODE_SIGN_IDENTITY=$SIGNING_IDENTITY" build > /tmp/hermes-mac-build.log 2>&1 || { tail -80 /tmp/hermes-mac-build.log; exit 1; }
APP_BUNDLE="$ROOT_DIR/DerivedData/Build/Products/Debug/HermesMac.app"
if [ ! -x "$APP_BUNDLE/Contents/MacOS/HermesCredentialHelper" ]; then
  echo "Build produced an app without HermesCredentialHelper. Regenerate the project with python3 script/generate_project.py and rebuild." >&2
  exit 1
fi
if [ "$MODE" != "--build" ]; then
  # Notifications resolve icons by bundle ID; old builds can shadow this bundle.
  python3 "$ROOT_DIR/script/register_app.py" "$APP_BUNDLE"
fi
case "$MODE" in
  --build) exit 0 ;;
  run) /usr/bin/open "$APP_BUNDLE" ;;
  --verify) /usr/bin/open "$APP_BUNDLE"; sleep 1; pgrep -x HermesMacDev >/dev/null ;;
  --debug) lldb -- "$APP_BUNDLE/Contents/MacOS/HermesMacDev" ;;
  --logs) /usr/bin/open "$APP_BUNDLE"; /usr/bin/log stream --info --style compact --predicate 'process == "HermesMacDev"' ;;
  --telemetry) /usr/bin/open "$APP_BUNDLE"; /usr/bin/log stream --info --style compact --predicate 'subsystem == "HermesMac" OR subsystem == "com.hermes.mac" OR subsystem == "com.hermes.mac.dev"' ;;
  *) echo "usage: $0 [run|--build|--verify|--debug|--logs|--telemetry]" >&2; exit 2 ;;
esac
