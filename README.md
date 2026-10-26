# River

River is a Go backend serving **one Flutter frontend shared by web and Android**.
It follows Orbit's home experience: a blue workspace sidebar, a welcome view,
recent posts/discussions, spaces and conversations. This replaces the previous
Next.js River code; Git history retains that implementation.

## Current capabilities

- Gravitas PKCE sign-in with explicit scopes and group selection.
- Spaces and DM/group conversations backed by real Gravitas groups/Matrix rooms.
- Owner invitations, invitation acceptance/decline, rename, member removal and leaving.
- Separate text/drop-in channel rooms with standard Matrix parent/child links;
  new spaces start with a lobby and lounge. Space membership changes update all
  channel memberships atomically, including through legacy Matrix membership APIs.
- Shared Gravitas contact requests, incoming/outgoing lists, acceptance, ignore/cancel,
  removal/block/unblock, and a canonical direct conversation per friend pair.
  Accepted contacts who approve River contacts access appear as friends on login
  and refresh, without creating another request or a copied friendship.
- Private saved read positions, unread counts and earlier-message pagination.
- Persistent messages, posts, discussions, replies and reactions, stored centrally.
- A responsive home and chat UI for phones, tablets and desktop.
- Browser cookies are encrypted, Secure, HttpOnly, host-only and SameSite=Lax.
  Android stores the same encrypted app-session envelope in platform secure storage.
- Android uses the system browser and an explicit device-link confirmation with a
  verifier challenge and five-minute, single-use exchange. Matrix device sign-in uses the same browser approval model. Initial encryption setup may require a password, sent directly from the SDK to Gravitas.
- Every protected request validates the central session proof; central logout and
  consent revocation deny subsequent access. IAM outages fail closed.

The backend has **no independent message database**. It relays a fixed allowlist of
routes to the configured HTTPS IAM origin, using a confidential delegated token.
No admin, IAM signing key or Matrix password is deployed to River.

The shared client also includes live updates/presence, friend-selected group
conversations, catch-up and participating threads, public posts/blogs with independent
comment policies, peer file attachments and calling. The Go process brokers
centrally authorized MatrixRTC memberships with a LiveKit SFU and Coturn relay.
See [the parity contract](docs/ORBIT_PARITY.md) and [media setup](deploy/media/README.md).
Gravitas implements native Matrix client/server and room federation APIs. River connects a local Matrix device through its Apache-2.0 adapter, using native Sliding Sync when advertised and classic sync otherwise. It sends standard messages, threads, reactions, edits and encrypted attachments through that device. Existing Gravitas contacts, delegated space tools, publishing and calls retain their app permissions.

Device security in Account supports showing a Matrix QR code, reading a QR image, camera capture where supported, SAS number comparison, cross-signing and encrypted key recovery. Confirming a QR scan is required before granting trust. Matrix sessions and private encryption keys stay in the client's encrypted store; the Go server receives only the one-use SSO login token. Encrypted messages never fall back to a clear-text send when the Matrix connection fails.

The adapter has native plugin builds for Android, iOS, macOS, Windows and Linux and a WebAssembly/IndexedDB implementation for Flutter web. River currently distributes web and Android applications; platform CI links the adapter on the other Flutter targets. See [the adapter](client/packages/river_matrix/README.md) for pinned dependencies and build/test instructions. Standard encrypted file uploads are limited to 32 MiB by River.

## Exact current mapping and event contract

Delegated Gravitas groups retain their internal UUIDs and membership records. Their canonical Matrix `room_id` comes from the signed room graph, and River uses that ID for Matrix traffic. A Matrix-only or remote room keeps its full `!room:server` ID. River merges these room lists by canonical ID, preserving local app permissions for calls and publishing.

- A River space maps 1:1 to that group and its canonical Matrix room ID, with
  `m.room.create.content.type = m.space`.
- A River DM/group conversation maps 1:1 to a normal Matrix room and group. Its
  `cool.gravitas.river.group.v1` state identifies `kind=dm` or `kind=group`. Invitations use
  `m.room.member` with `is_direct=true`. Private Matrix `m.direct` account data is
  maintained by Gravitas and the SDK lets other Matrix clients recognize direct rooms.
- Each channel is a separate room/group linked by `m.space.child` and canonical
  `m.space.parent`. A `river_channels` row is the authoritative parent link.
  The root timeline is retained for existing content and space posts/discussions.
  Membership changes and child creation take the same space row lock; accepting,
  leaving or removing a member propagates to every channel in the transaction.
  Independent child joins/invites/leaves are denied. Child writes recheck the
  current parent and child memberships while holding the root lock.
- `spaces.channels` explicitly authorizes access to current/future channels of an
  approved space, still subject to chat scopes and membership. A directly selected
  child also requires parent membership. `groups.join` permits invitation metadata
  and extends selected access only upon acceptance. Existing tokens need renewed
  consent; no existing selected grant is silently broadened.
- Contacts are private Gravitas account data, not a group's public roster.
  `contacts.read` / `contacts.manage` separately authorize reading/actions across
  apps. River requests these explicit scopes at sign-in; old sessions need one
  reconnect. Old `friends.read/manage` credentials cannot inherit contacts access.
  River's `/app/v1/friends` response is a projection over the same central graph:
  accepted contacts with current River `contacts.read` consent become `friends`;
  other accepted people appear in `other_contacts`. Requests still need acceptance.
  Both people must approve River contacts access. App logout does not remove a
  contact; revoking app consent removes their River participation on refresh.
  The shared Flutter client only reads this list during login, with no automatic
  request/accept writes or separate app friendship store. Removals and blocks are
  global across apps, as explained in the UI and consent screen. Unblocking does
  not restore a relationship. Existing friendship/request/block rows and IDs are
  preserved in place. New immutable actions use `cool.gravitas.contact.v1` with
  version, actor, target, originating app and action. Historical River friend events
  retain their types. App event queries expose only the calling app's actions and
  hide another person's block events. These remain delegated private contact APIs;
  standard Matrix account-data endpoints are used separately by the Matrix SDK.
  Blocks stop contact requests and direct messages, while shared space channels
  retain their normal group ACL. Creating a canonical DM additionally checks the
  contact's current app consent. Reopening an already-joined DM still requires
  that room in the app's approved selection.
- Drop-in channels and DM/group calls use their existing room/group for MatrixRTC
  `m.rtc.slot` and sticky `m.rtc.member` events. Each overlapping call session also
  has a separate call-chat room/group, readable only with a current valid lease.
  Leases are bound to the delegated token, user, app, room and individual device.
  Public comments use a separate related room/group and a standard thread anchor;
  prior member-only comments never become public after a policy change.
- Standard chat messages and replies are separate `m.room.message` events, with
  `m.in_reply_to` and `cool.gravitas.river={version:1,kind:message|reply}`.
- Posts and discussions are separate `cool.gravitas.river.post.v1` and
  `cool.gravitas.river.discussion.v1` events with `version=1`, `title` and `body`.
  Generic clients may ignore these custom types. No duplicate fallback event is sent.
- Reactions are standard `m.reaction` with `m.annotation`, target event ID and key.
- Group actions emit immutable `cool.gravitas.delegation.v1` audit events containing
  actor (sender), app origin, action and target. Every relayed content event records
  its delegated app origin. No credential appears in an event.
- Relation targets must exist in the same room. Event transaction IDs are scoped to
  user, app origin and room; retries return the same event and conflicting reuse
  returns 409. Group creation also accepts a stable transaction ID.

New groups are invitation-only, with owner membership management. Existing legacy
Matrix join/state routes also enforce the River group's owner/invitation rules.
Room membership, app room selection and operation scope must all permit access.
`groups.create` adds **only the newly created group** to a selected app grant.
`groups.manage` grants no global administration or authority over another owner's group.
History is `shared`: a joined member can read prior retained group events; removed
members cannot read through River. Encrypted-room messages and standard attachments use client-side Matrix encryption; public publishing and room state remain server-readable.

Delegated endpoints live on the main Gravitas server at `/app/v1/groups`:
`GET/POST`, `PATCH /:id`, `POST /:id/membership`, `GET /:id/events`, and
`PUT /:id/events/:type/:txn_id`, `GET/POST /:id/channels` and `POST /:id/read`.
`GET /app/v1/overview` batches accessible groups and the latest 200 content events.
`GET/POST /app/v1/friends`, `GET /app/v1/friends/events`, and `POST /app/v1/direct`
handle the River contacts projection and canonical direct conversations. Generic
`GET/POST /app/v1/contacts` and `GET /app/v1/contacts/events` are owned by Gravitas.
They use opaque,
revocable app tokens. The additive API migration creates channel links, direct
pairs, private social state/events and read positions; it must release before this
client. Event pagination uses a same-room event ID cursor with a stable database
(timestamp, UUID) ordering. Private read positions cannot move backwards.

## Build and test

The Dockerfile and Android CI pin Flutter 3.47.7 at
`abaf9c523780a608bd46686fd5e53740a07077f8`.
Go is pinned to 1.25.2 for the image. Rust 1.96.0 and wasm-bindgen 0.2.129 build the Matrix core. Flutter and Rust dependencies are locked in their tracked lockfiles. Run `bash scripts/matrix-toolchain.sh` and the web asset build from the adapter README before building Flutter locally; the production Dockerfile does this automatically.

```
cd backend
go test -race ./...
go vet ./...
cd ../client
flutter pub get --enforce-lockfile
flutter analyze
flutter test
cd ..
bash scripts/build-matrix-web.sh
cd client
flutter build web --release --no-web-resources-cdn
flutter build apk --debug --target-platform android-arm64,android-x64
```

The Android identifier is `cool.gravitas.river`; the pinned Flutter runtime requires Android 7.0/API 24 or newer. The permanent public certificate
is pinned in `client/android/release-certificate.sha256`; preserve the original
private key for updates. Never reuse Orbit's identity or signing key. Debug APKs
use a different certificate and are development artifacts.

Set `RIVER_SIGNING_CONFIG` to the protected original `signing.json`, then run
`python3 scripts/build-android.py`. The helper builds a non-debuggable APK and
verifies the package, version, minimum Android version, v2/v3 signature and
permanent certificate. A new independent app can create its first key with
`scripts/create-signing-key.py --directory /private/path`; it refuses an existing
directory or certificate pin. Back up the private key and passwords securely.
Signing material is excluded from Git and container builds and is never uploaded
as a release asset. Release builds fail when signing configuration is absent.

After increasing the version name and Android build number, push or merge to `main`. GitHub's **Signed Android release** workflow automatically tests, signs with the original River key, verifies the APK and publishes it for Private Store ingestion. Existing versions and tags are never overwritten. See [signed Android releases](ANDROID_RELEASES.md) for verification-only builds and secret maintenance.

Configure the Go process with `GRAVITAS_SESSION_KEY` (32 random bytes, base64url),
`GRAVITAS_ISSUER=https://gravitas.cool`, `APP_URL=https://chat.gravitas.cool`,
`STATIC_DIR=/app/web` and `ADDR=:8080`. The session key belongs in a Kubernetes
Secret. New sign-ins retain the delegated refresh token only inside the encrypted app-session
envelope. River renews expired access automatically, persists the replacement in the
HttpOnly browser cookie or Android secure storage, and preserves the linked Matrix
device and keys. The envelope lasts only until the original central login family
expires (at most 30 days); logout and consent revocation still deny access immediately.
Temporary IAM failures return 503 without deleting credentials. Older installations
need one sign-in after updating because their envelopes never contained refresh tokens.
Native device approval transfers that login to the app and clears the browser handoff
cookie, so the browser and app do not share a rotating refresh token. Concurrent
renewals and immediate response retries share a bounded two-minute result cache in
the current single-replica backend; successful clients persist the replacement so
normal backend restarts do not end their sessions.
Pending Android links are bounded and in memory; restart requires starting a new link.

## Deploy

The image bundles the compiled Flutter web assets. The existing DOKS cluster,
Traefik ingress, wildcard DNS and wildcard TLS are reused. No new load balancer,
public database or cloud VM is required. The Go pod requests/limits 100m CPU and
128Mi memory (with a 96MiB Go heap target), runs without root or Linux capabilities, uses a read-only filesystem,
and has no Kubernetes API token. Network policy permits ingress only from Traefik.

```
deploy/gravitas/deploy.sh ghcr.io/jeethsuresh/river@sha256:<verified-image-digest>
```

The deploy script pins the existing cluster, requires a digest, and checks rollout
and public trusted HTTPS. Provision namespace `river` and Secret `river-runtime`
with `GRAVITAS_SESSION_KEY` before initial deployment. The tracked Namespace document
is applied during initial provisioning; ongoing namespace-scoped CI uses only
namespaced resources. CI tests and publishes branch images. Successful pushes to `main` deploy automatically after the checks pass, using an environment-scoped, namespace-limited `GRAVITAS_KUBECONFIG`, following RSS/Office/Spacetime patterns.

## Release verification and limits

See [the parity contract](docs/ORBIT_PARITY.md) for the source baseline and feature
coverage. Run the Go race/vet checks, Flutter analysis/widget tests, web release
build and signed Android build before publishing. CI also builds Android from
the pinned SDK; PRs never receive release signing material. The opt-in local media
fixture and shared browser/Android scenarios check real SFU media, TURN relay and
peer-file bytes without production accounts or real microphone/camera data.

Production media needs the separate manual [media setup](deploy/media/README.md).
Backend and web changes merged to `main` deploy automatically after CI passes; complete the relevant tests before merging.
An APK upload alone does not install its API migration, web image or media pods.
Physical-device Bluetooth, mobile-network handoff and large-call capacity require
separate device/load verification. Password recovery remains outside this River
release at the user's request; registration/password/settings/logout use Gravitas.
Matrix-only rooms support messaging and device encryption. Gravitas-specific publishing, contacts and SFU calling continue to use their delegated app APIs. Matrix QR verification synchronizes message encryption keys; it does not imply that a LiveKit call is end-to-end encrypted. Public posts cannot be made private retroactively by enabling room encryption. Generic Matrix clients may ignore River-specific post and discussion events.

Protocol references: [Matrix events and spaces](https://spec.matrix.org/v1.19/client-server-api/),
[MatrixRTC](https://github.com/matrix-org/matrix-spec-proposals/pull/4143).

## Contacts release compatibility

Install IAM contacts API/migration `20261023120000` before this client/backend.
The migration adds a persisted event type while preserving existing social data.
Follow the main server's contacts contract in `jeethsuresh/iam-server/docs/contacts.md`.
River's permanent package/certificate are unchanged; the existing Private Store
catalog can ingest a verified stable 0.3.0 release after manual release approval.
Publish the stable APK after the matching API and web release is verified.

### Username sign-in

Sign in by entering your username and pressing **🔥** (or Enter). A bare name
such as `alice` uses the identity server configured by `GRAVITAS_ISSUER`, which
also owns the registration button. The Gravitas deployment uses `gravitas.cool`.
`alice@example.org`, `alice:example.org` and `@alice:example.org` select that
public domain's compatible IAM service over HTTPS. Registration always stays on
the configured default server. Login transactions and app sessions retain the
selected issuer, including subsequent session-revocation checks.
