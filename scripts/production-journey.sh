#!/usr/bin/env bash
set -euo pipefail
: "${RUNNER_TEMP:?Run in the opt-in GitHub job}"
: "${JOURNEY_CONFIG:?Provide only short-lived recorded disposable actors}"
root="$(pwd)"
config="$RUNNER_TEMP/river-production-journey.json"
umask 077
printf '%s' "$JOURNEY_CONFIG" > "$config"
unset JOURNEY_CONFIG
bridge_pid=''
driver_pid=''
cleanup() {
  curl -fsS -X POST http://127.0.0.1:57910/test/stop >/dev/null 2>&1 || true
  if [[ -n "$bridge_pid" ]]; then kill "$bridge_pid" 2>/dev/null || true; fi
  if [[ -n "$driver_pid" ]]; then kill "$driver_pid" 2>/dev/null || true; fi
  rm -f "$config"
}
trap cleanup EXIT
python3 - <<'PY'
import json,urllib.request
with urllib.request.urlopen('https://chat.gravitas.cool/version.json',timeout=20) as r:
    assert json.load(r)['version']=='0.5.2'
with urllib.request.urlopen('https://gravitas.cool/readyz',timeout=20) as r:
    assert r.status==200
PY
(
  cd backend
  RIVER_PRODUCTION_JOURNEY_CONFIG="$config" go test -run '^TestProductionJourneyBridge$' -v -timeout 47m
) > "$RUNNER_TEMP/journey-bridge.log" 2>&1 &
bridge_pid=$!
"$RUNNER_TEMP/browser/chromedriver-linux64/chromedriver" --port=4444 --allowed-ips=127.0.0.1 > "$RUNNER_TEMP/journey-driver.log" 2>&1 &
driver_pid=$!
ready=0
for attempt in $(seq 1 180); do
  if curl -fsS http://127.0.0.1:57910/alice/api/session >/dev/null 2>&1; then ready=1; break; fi
  sleep 1
done
[[ "$ready" == 1 ]] || { tail -n 40 "$RUNNER_TEMP/journey-bridge.log"; exit 1; }
args=(--debug --no-pub -d web-server --web-hostname=127.0.0.1 --web-port=57920
  --driver test_driver/production_journey.dart --target integration_test/production_journey_test.dart
  "--chrome-binary=$RUNNER_TEMP/browser/chrome-linux64/chrome"
  --web-browser-flag=--use-fake-device-for-media-stream
  --web-browser-flag=--use-fake-ui-for-media-stream
  --web-browser-flag=--autoplay-policy=no-user-gesture-required
  --web-browser-flag=--disable-renderer-backgrounding
  --web-browser-flag=--disable-backgrounding-occluded-windows
  --web-browser-flag=--disable-background-timer-throttling
  --browser-dimension=1100x900 --no-web-resources-cdn
  --dart-define=RIVER_JOURNEY_BRIDGE=http://127.0.0.1:57910 --timeout=1200)
if [[ "${MEDIA_ONLY:-false}" == true ]]; then args+=(--dart-define=RIVER_JOURNEY_MEDIA_ONLY=true); fi
cd "$root/client"
result=0
flutter drive "${args[@]}" > "$RUNNER_TEMP/journey.log" 2>&1 || result=$?
tail -n 100 "$RUNNER_TEMP/journey.log"
[[ "$result" == 0 ]] || exit "$result"
rg -q 'All tests passed\.' "$RUNNER_TEMP/journey.log"
