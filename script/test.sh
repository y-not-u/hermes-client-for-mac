#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
fixture_venv="${HERMES_TEST_VENV:-/tmp/hermes-mac-test-venv}"
if ! "$fixture_venv/bin/python" -c 'import aiohttp' 2>/dev/null; then
  python3 -m venv "$fixture_venv"
  "$fixture_venv/bin/pip" install 'aiohttp==3.13.3'
fi
fixture_ready="$(mktemp)"
"$fixture_venv/bin/python" script/mock_server.py --port 0 --ready-file "$fixture_ready" &
fixture_pid=$!
trap 'kill "$fixture_pid" 2>/dev/null || true; wait "$fixture_pid" 2>/dev/null || true; rm -f "$fixture_ready"' EXIT
for attempt in {1..100}; do
  if [ -s "$fixture_ready" ]; then break; fi
  sleep 0.05
done
if [ ! -s "$fixture_ready" ]; then echo 'Fixture failed to start' >&2; exit 1; fi
export HERMES_TEST_SERVER="$(cat "$fixture_ready")"
swift test "$@"
