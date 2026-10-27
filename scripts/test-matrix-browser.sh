#!/usr/bin/env bash
set -euo pipefail
root=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
output=$(mktemp -d)
cleanup() {
  if [[ -n ${server_pid:-} ]]; then kill "$server_pid" 2>/dev/null || true; fi
  rm -rf "$output"
}
trap cleanup EXIT
cd "$root/client"
bash "$root/scripts/build-river-web.sh" --release --no-pub --no-web-resources-cdn --target tool/matrix_web_smoke.dart --output "$output/web"
# Only a local test page is served. The browser never connects to production.
python3 -m http.server 18791 --bind 127.0.0.1 --directory "$output/web" > "$output/http.log" 2>&1 &
server_pid=$!
for attempt in $(seq 1 30); do
  if curl -fsS http://127.0.0.1:18791/ > /dev/null; then break; fi
  sleep 0.1
done
MATRIX_OFFLINE_SERVER_PID="$server_pid" "${DART_EXECUTABLE:-dart}" "$root/client/tool/matrix_browser_driver.dart" \
  "${CHROME_EXECUTABLE:-chromium}" '' http://127.0.0.1:18791/ smoke
