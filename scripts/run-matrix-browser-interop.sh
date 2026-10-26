#!/usr/bin/env bash
set -euo pipefail
output=$(mktemp -d)
cleanup() {
  if [[ -n ${server_pid:-} ]]; then kill "$server_pid" 2>/dev/null || true; fi
  rm -rf "$output"
}
trap cleanup EXIT
# Trust only this disposable peer certificate in the test browser. The SDK
# retains its production HTTPS checks; no certificate/private key enters it.
spki=$(openssl x509 -in /fixtures/peer.pem -pubkey -noout | openssl pkey -pubin -outform der | openssl dgst -sha256 -binary | openssl base64 -A)
python3 -m http.server 18792 --bind 127.0.0.1 --directory "${MATRIX_BROWSER_WEB:-/opt/river-matrix-browser}" > "$output/http.log" 2>&1 &
server_pid=$!
for attempt in $(seq 1 30); do
  if curl -fsS http://127.0.0.1:18792/ > /dev/null 2>&1; then break; fi
  sleep 0.1
done
"${DART_EXECUTABLE:-dart}" "${MATRIX_BROWSER_DRIVER:-/src/client/tool/matrix_browser_driver.dart}" \
  "${CHROME_EXECUTABLE:-chromium}" "$spki" http://127.0.0.1:18792/
