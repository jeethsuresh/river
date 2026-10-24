# River 0.5.2

- Remove the configured 32-participant call ceiling from the Go broker and SFU configuration. Usable call capacity still depends on media, devices and server resources.
- Restore live updates by accepting Gravitas’s JSON API negotiation before its SSE stream.
- Wait for queued refreshes after membership, channel and content actions so an in-flight older read cannot leave the shared web/Android client using stale state.
- Add repeatable, opt-in production-account journey tests and a tracked verification ledger for the remaining physical-device, network, load, storage and accessibility checks.

Uses River’s existing permanent Android signing certificate and minimum Android
7.0 (API 24). Gravitas handles accounts; password recovery remains deferred.
Backend/web deployment follows the current tested main-only workflow. See docs/VERIFICATION_GAPS.md for
the bounded admission check and the precise verification limits.

Preserves 0.5.1's username/domain sign-in and the current verified signed Android
release workflow. GitHub publishes the signed APK after its release tests pass;
backend/web deployment runs automatically after the required main-branch tests.
