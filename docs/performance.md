# River performance measurements

Conversation navigation loads the selected timeline directly. Account overview, home, contacts, calls and presence are independent work. Acknowledged messages enter the local timeline immediately; the next SDK history response reconciles their content and DAG ordering. An attachment history failure after delivery does not report the upload itself as failed.

Matrix restoration publishes the encrypted SDK store's local rooms before starting a remote poll. The offline cache remains available during reconnects. Every credential-changing operation still completes durable credential persistence, including failure paths.

## Local diagnostics

`RiverPerformance` in `client/lib/performance.dart` records the most recent 256 operation durations with fixed labels. Its `snapshot()` returns count, failures, p50, p95 and maximum microseconds per operation. `clear()` resets the samples. Evaluate these methods in that library with Flutter DevTools. Profile builds also expose asynchronous Timeline tasks for boot, conversation open, send, HTTP and Matrix operations.

Samples stay on the device and contain no URLs, account/room IDs, message text, credentials or attachment bytes. No diagnostics are uploaded. `matrix.sync` includes the intentional long-poll wait, so its elapsed duration is not a server processing time.

Proxied HTTP responses include `Server-Timing`: `auth` measures the central session check, `upstream` measures the proxied request, and Gravitas can add SQL execution, connection-queue time and query count. Session revocation continues to be checked on every authenticated HTTP request.

## Repeat the foreground benchmark

Use the pinned Flutter version and revision from `Dockerfile` and run:

```sh
cd client
flutter test test/performance_test.dart
flutter test
flutter analyze
```

The benchmark injects a fixed 40 ms delay per network request. On October 27, 2026, the original code took about 260 ms / six requests to open a known conversation and 315 ms / seven requests to send. Focused reads reduced both operations to one request (roughly 45–60 ms on the audit host). This measures request dependencies with a controlled transport; it is not a production latency percentile or an Android device benchmark.

Regression coverage includes navigation while contacts are blocked, A/B/A navigation with late responses, acknowledgement reconciliation, departure invalidation, credential rotation and failed durable writes, and offline cache restoration.

## Web delivery

`scripts/prepare-web-assets.sh` produces deterministic gzip files and SHA-256 validators at build time. The server negotiates gzip, preserves original MIME types, and uses distinct validators for compressed and identity representations. Unversioned assets revalidate on every navigation; entry HTML and authentication responses retain `no-store`.

On the production bundles sampled during the audit, JavaScript plus Matrix WASM were 26,862,794 bytes uncompressed and 7,179,329 bytes with gzip (73.3% less transfer). Actual release sizes vary. The server spends no request CPU compressing these assets. The web build still runs the existing offline shell-generation script before preparing gzip assets.

Validate the release build with `docker build --target frontend-build .`; run Go race tests and vet through `docker build --target backend-test .`. A rootless Podman host with a narrow UID map may need a local `TAR_OPTIONS=--no-same-owner` environment when extracting Flutter's upstream archives; this does not change the pinned SDK.
