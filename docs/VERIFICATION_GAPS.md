# River verification gaps

Baseline: River 0.5.1 (`cd78a0d`), 2026-10-24. This is a verification ledger,
not a claim that untested behavior is broken or that feature parity proves
reliability on every device. Password recovery remains explicitly deferred.

## 1. Physical audio and camera

Bluetooth connect/disconnect/reconnect, speaker/earpiece/microphone routing,
physical camera switching/orientation, echo cancellation and perceived sound
quality need two physical devices. Synthetic media decoding and emulator camera
coverage do not establish those outcomes.

## 2. Android background and lifecycle

Test lock/unlock, switching apps, battery saver, OEM process restrictions,
incoming telephone calls, OS screen-capture stop, and permission revocation.
Existing emulator coverage includes projection capture and continued decoded
frames during forced ICE refresh, but not all of these lifecycle transitions.

## 3. Network transitions and long calls

Test Wi-Fi/cellular transitions, intermittent loss, restrictive networks, and
multi-hour calls across natural credential expiration. Forced TURN refresh and
ICE restart have passed; these do not substitute for physical handoffs or hours
of continuous operation.

## 4. Capacity and resilience

The previous 32-participant setting existed in both the Go CreateRoom request and
the generated SFU configuration. The broker now omits it and generated LiveKit
configuration uses `max_participants: 0` (no configured room limit).

A bounded, isolated LiveKit 1.13.10 admission test passed on 2026-10-24: the control
room admitted 32 and rejected participant 33; the uncapped room admitted 64
simultaneous signaling participants. Admission phases took 223ms on this machine.
No WebRTC media was negotiated and no TURN allocations were made. This proves
admission beyond 32, **not a supported media-call capacity of 64**. Reproduce with
`RIVER_TEST_LIVEKIT_BINARY=/absolute/path/to/livekit-server go test -run TestLocalCallParticipantAdmission -v` in `backend/`.

LiveKit's zero setting has no finite application-imposed participant maximum.
The uint32 configuration field is not a promise that billions of participants
can connect. CPU, memory, bandwidth, subscriptions, browser/device decode limits,
leases, and relay allocations determine actual capacity. Gravitas retains four
active device leases per user and a 512-lease bound on the call directory read
across visible rooms; the directory bound can truncate occupancy/name metadata
and is not a room admission limit. Production currently
reserves 300m/512Mi for one SFU and 50m/128Mi for one TURN relay. TURN retains its
8-per-user/128-total allocation quotas and bandwidth safeguards; allocation count
is not a fixed participant count. No production stress test or failover guarantee
has been established. Multiple rooms, many video/screen streams, concurrent file
transfers, latency, and resource exhaustion remain unverified.

Existing LiveKit rooms keep their previously stored maximum; CreateRoom with
zero cannot clear a positive maximum in LiveKit 1.13.10. A configuration rollout
must check for active rooms, let existing calls finish, and restart the SFU only
when idle, rather than interrupt users. Verify newly created rooms report zero.

Sources: [LiveKit room API](https://docs.livekit.io/reference/other/roomservice-api/),
[1.13.10 allocator](https://github.com/livekit/livekit/blob/v1.13.10/pkg/service/roomallocator.go),
[1.13.10 admission check](https://github.com/livekit/livekit/blob/v1.13.10/pkg/rtc/room.go).

## 5. Peer-file stress and storage pressure

Actual 256KiB transfer, hash verification and retained-peer recovery passed.
Exercise the five-file, 25MiB/file, 50MiB/message boundaries over real transport,
poor networks and full storage. Exercise the 256MiB local cache and actual
browser/Android storage eviction. Losing every peer copy has no recovery by
design; River does not promise server file backup.

## 6. Complete production account journeys

Run fresh, disposable accounts through actual Gravitas login and consent, central
contacts/request/accept/projection, space invitations/acceptance, separate text
and voice channels, canonical DMs and group conversations, visual/Markdown
posts and discussions, authored edits, replies/reactions, publication and comment
permissions, unread/read synchronization, and calls with membership/consent
revocation while connected. Use the deployed web build and Android client.
Record the exact version, device/runtime and which steps use UI versus direct
protocol assertions. Mocked widget tests, a signed APK's anonymous welcome screen,
and synthetic-auth media fixtures do not cover this whole journey. Outcomes of
the requested fresh run will be appended below; pending steps are not passes.

## 7. Browser, device, input and accessibility matrix

Chrome and an Android API 36 emulator (36.1 system image) plus 360/768/1440-width layout tests are
not comprehensive Firefox/Safari/mobile-browser coverage. Physical older Android
(minimum API 24), OEM variants, IMEs, TalkBack, keyboard navigation and large text
need explicit coverage. A physical device is needed to close physical-only gaps.

## 8. Private Store fresh installation

0.5.0 catalog import and APK metadata/hash/certificate checks passed, as did a
local signed 0.4.0-to-0.5.0 upgrade preserving installation identity. A new physical
Store sign-in/enrollment/download/install of 0.5.0 was not repeated; the prior
0.4.0 authenticated download was verified. Check the current release rather than
assuming these historical results establish a newer artifact's complete journey.

## Protocol boundaries

Gravitas provides a Matrix-compatible API subset and versioned River events.
Full homeserver conformance, federation, E2EE, and stock Matrix call-focus
interoperability are not established by Orbit feature coverage. Password recovery
is out of this run's scope by the user's instruction.

## Production journey results

Fresh disposable accounts completed real Gravitas password/PKCE/consent and
one-time native pairing; replay was denied. No personal browser session was used.
The full default Android baseline scenario passed on 2026-10-24 in 8m47s using Flutter
3.47.7 instrumentation on an isolated Android API 36 emulator (36.1 system image).
It exercised the shared widgets and real deployed APIs/SSE/SFU, including decoded
remote video, audio subscription, mute/unmute, call-chat ACLs, membership removal,
rejoin, and live consent revocation.

Final web and Android results for the additional post-save sequencing fix are
recorded in [River PR #11](https://github.com/jeethsuresh/river/pull/11), including
the exact tested client commit and any remaining failures. Earlier failed
attempts are diagnostic evidence, not passes. Creation widgets were exercised on initial attempts; successful retries
reuse only their recorded disposable spaces/channels/conversations. The tests
combine shared-widget interactions with direct API assertions for persistence,
relations, authorization and privacy. They do not establish physical sound
quality or a physical signed-APK login/Store-install journey.

The successful Android run used River source `b839d79` (0.5.2+7), image
`sha256:66bce6b6387672238ee1cd6cbbc9df74af5a1d9b1faeca55d42c26af19aedf89`,
and Gravitas source `9f9b789`, image
`sha256:b82a9a3f85d5dc3eea718cf29480a18ab8453c906356a01c6cacecfb3bed2006`.
The combined Gravitas CI passed 75 + 27 + 207 tests with no failures.
Go race checks, Flutter analysis and 42 shared unit/widget tests also passed.

Concurrent fixture reads sometimes took 3–11 seconds on the current reserved
resources. This is functional coverage, not a latency SLO or load qualification.
Keep failed steps and reproduction details even when a subsequent fix passes.
Never commit credentials or disposable session envelopes.

### Automated reproduction

The shared scenario is `client/integration_test/production_journey_scenarios.dart`, with
the Android/app entry point at `client/integration_test/production_journey_test.dart`
and the web host driver at `client/test_driver/production_journey.dart`. Production execution
is opt-in; normal CI does not create accounts or contact production.

`backend/production_harness_test.go` supplies a loopback-only bridge using three
fresh disposable users (the third is needed to select a group conversation).
Its protected JSON configuration is outside Git: `actors` maps `alice`, `bob`,
`carol` to `username`, `token` (a normal native envelope), and `iam_cookie` (the
same fixture's Gravitas browser session for consent-revocation testing). Only
fixture usernames matching `rq[abc][a-f0-9]{8}` are accepted. Obtain those sessions
through actual Gravitas password/PKCE/consent and explicit native handoff; do not
substitute personal accounts, fake JWTs or database-created authorization.

The bridge binds three loopback ports (57910–57912), giving the three browser
actors independent HTTP connection pools instead of multiplexing their SSE
streams and API/preflight traffic on one HTTP/1 origin. Only the test harness
uses these origins; the shipped clients continue to use the normal River URL.

Run `go test -run '^TestProductionJourneyBridge$' -v -timeout 47m` with
`RIVER_PRODUCTION_JOURNEY_CONFIG=/absolute/protected/config.json`. Start a
loopback ChromeDriver matching the installed browser, then run from `client/`:

```sh
flutter drive --debug --no-pub -d web-server \
  --web-hostname=127.0.0.1 --web-port=57920 \
  --driver test_driver/production_journey.dart \
  --target integration_test/production_journey_test.dart \
  --web-browser-flag=--use-fake-device-for-media-stream \
  --web-browser-flag=--use-fake-ui-for-media-stream \
  --web-browser-flag=--autoplay-policy=no-user-gesture-required \
  --no-web-resources-cdn \
  --dart-define=RIVER_JOURNEY_BRIDGE=http://127.0.0.1:57910
```

For Android use `flutter test -d <test-emulator>
integration_test/production_journey_test.dart`, adding the same bridge Dart define.
Use a task-only `adb reverse tcp:57910 tcp:57910` and grant microphone/camera/
Bluetooth-connect permissions to the test package on that disposable emulator.
Keep the host awake for the bounded run (for example, macOS `caffeinate -is`
scoped to the runner). macOS sleep logs confirmed interruptions during failed
web attempts; those interrupted attempts are not verification passes.

Test code uses a live integration clock for real SSE/network concurrency and
waits for actual headless widget/dialog mounts. No credentials are Dart defines.
Only the local bridge injects the real native envelopes; API/SSE/media responses
come from production. Peer-file discovery is excluded from this journey and
retains its separate transport coverage. This does not verify a physical
signed-app login UI.

### Bugs reproduced during the fresh run

- Concurrent refreshes: an action requesting a refresh while an older read was
  running returned immediately, leaving stale membership/channel state. A focused
  failing regression now passes with queued callers awaiting their fresh read.
- Live invalidations: River requested upstream SSE with an SSE-only Accept header.
  Gravitas's JSON API negotiation rejected it (500), and River returned 503. The
  broker now accepts SSE plus JSON errors and still requires a text/event-stream
  response. The relay regression reproduces the rejection and verifies the fix.

A diagnostic journey can explicitly disable only the SSE assertion with
`RIVER_JOURNEY_REQUIRE_SSE=false` while the backend fix awaits rollout; it prints
that deferral and uses explicit refresh. Such a run is not an SSE pass. Final
verification must use the default true setting against the fixed deployment.

- Private-to-public publication: the editor saved an initial private policy, but
  updating that existing row to public failed to persist its newly created comment
  room and anchor. Public comments then failed. Gravitas now tracks both IDs in
  the Ecto changeset and tests a saved private draft through outsider comments,
  reactions and preservation of earlier private history.

- Post-save sequencing: an intermediate snapshot delayed the visibility-policy
  write after the post itself had persisted. The editor now completes the ordered
  content/policy writes and then waits for one final refresh. Regressions verify
  policy persistence despite a blocked read and no duplicate post after a policy
  failure/retry.
