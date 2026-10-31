# River

River is a Go backend serving **one Flutter frontend shared by web and Android**.
It follows Orbit's home experience: a blue workspace sidebar, a welcome view,
recent posts/discussions, spaces and conversations. This replaces the previous
Next.js River code; Git history retains that implementation.

## Current capabilities

- Gravitas PKCE sign-in with required full Matrix room access and explicit operation scopes.
- Spaces and DM/group conversations backed by real Gravitas groups/Matrix rooms.
- Conversations with selected members of an existing space/group, without
  requiring contact relationships; invitations still require acceptance.
- A group hierarchy view showing authorized containing groups, sub-groups and
  conversations with equal participant sets. Participant changes move a
  conversation's subgroup while preserving its placement, visibility and history.
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
- Linked GIFs and images in every shared composer and content view, plus saved
  stickers with a white contour and emoji/sticker reactions.
- A responsive home and chat UI for phones, tablets and desktop.
- Browser cookies are encrypted, Secure, HttpOnly, host-only and SameSite=Lax.
  Android stores the same encrypted app-session envelope in platform secure storage.
- Android uses the system browser and an explicit device-link confirmation with a
  verifier challenge and five-minute, single-use exchange. Both device linking and
  Matrix approval return to the app automatically, with an Open River fallback
  when the browser requires a tap. Return links contain no credentials. Android
  retains the pending verifier in secure storage so a cold start can finish the
  exchange. Matrix device sign-in is required on a new or unlinked device, using
  the same browser approval model. Conversations remain unavailable until Matrix
  connects. Failed or cancelled approval stays on setup with retry and sign-out
  options. A restored linked device can open its cached conversations offline. Initial
  encryption setup may require a password, sent directly from the SDK to Gravitas.
- Desktop message composers send with Enter by default; Shift+Enter inserts a new
  line. **Settings → Enter sends messages on desktop** turns this off and saves
  the choice per account on the device. Ctrl/Cmd+Enter remains available, and
  mobile Enter inserts a new line. This applies to messages in visual and Markdown
  modes; post and discussion editors keep their multiline behavior.
- Conversation drafts and pending attachments stay with their room while navigating.
  Failed sends retain their transaction ID and offer Retry, including when the
  homeserver accepted a message but its response was lost.
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

## Local storage and offline viewing

The Matrix adapter keeps room state and encryption keys in IndexedDB on web and
SQLite under the application support directory on desktop/mobile. River stores
viewed chat timelines, loaded thread pages, room navigation metadata, composer
drafts, pending attachment references and retry transaction IDs in that same
account/device state database. Generic SDK custom values bypass ordinary store
encryption, so River wraps these records with the SDK storage cipher and the
existing device store secret. Records are bound to their room and scope.

The web build generates a versioned static app-shell service worker so the page
can reload offline after its first successful load. It caches static resources
only, excludes auth/API/Matrix endpoints and preserves account and media stores.
Build web with `bash scripts/build-river-web.sh --release --no-pub --no-web-resources-cdn`
after building the Matrix WebAssembly adapter.

Cached rooms and viewed messages load before network checks finish. Offline
clients show **Network unavailable** in the header, keep drafts editable and
retry synchronization when active. Sending and server mutations require a
connection; this is not an automatic outgoing message queue. Earlier history
and threads that have not been loaded require a connection. Logout or an
explicit session rejection clears the visible profile and its startup identity.

Linked images/GIFs are fetched anonymously, validated and cached beside peer file
attachments: browser Cache API on web, application support files on native.
The image index uses URL hashes and verifies saved bytes. Its separate 128 MiB
budget evicts oldest images without removing peer attachments; the latter retain
their existing 256 MiB budget. Saved stickers remain a separate device library.
Local database/storage errors are shown without discarding the in-memory draft.
A single saved timeline or thread record is limited to 16 MiB; a larger record
reports a local save error while its online view remains usable.

## Exact current mapping and event contract

Delegated Gravitas groups retain their internal UUIDs and membership records. Their canonical Matrix `room_id` comes from the signed room graph, and River uses that ID for Matrix traffic. A Matrix-only or remote room keeps its full `!room:server` ID. River merges these room lists by canonical ID, preserving local app permissions for calls and publishing.

- A River space is a Matrix space (`m.room.create.content.type = m.space`)
  containing multiple conversation rooms. Its root group/room identifies the space
  and transports space-owned custom events. It is not a conversation.
- A River DM/group conversation maps 1:1 to a normal Matrix room and group. Its
  `cool.gravitas.river.group.v1` state identifies `kind=dm` or `kind=group`. Invitations use
  `m.room.member` with `is_direct=true`. Private Matrix `m.direct` account data is
  maintained by Gravitas and the SDK lets other Matrix clients recognize direct rooms.
- Each channel is a separate room/group linked by `m.space.child` and canonical
  `m.space.parent`. A `river_channels` row is the authoritative parent link.
  Posts and discussions belong to the parent space, never to a child room.
  Conversations (including DMs and group chats) are exactly one normal Matrix room.
  Membership changes and child creation take the same space row lock; accepting,
  leaving or removing a member propagates to every channel in the transaction.
  Independent child joins/invites/leaves are denied. Child writes recheck the
  current parent and child memberships while holding the root lock.
- River requests `matrix.full` by default: consent requires access to all current
  and future Matrix spaces/conversations, within membership and account permissions.
  Existing selected-room grants need renewed consent; old credentials are not
  silently expanded. The narrower grant model remains available to other apps.
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
  `cool.gravitas.river.discussion.v1` events with `version=1`, canonical Matrix `space_id`, `title` and `body`.
  River uses `/app/v1/spaces/:id/entries` for their feeds and creation. Both delegated
  and native Matrix writes reject these events in conversations and child rooms.
  Existing immutable events stay in history; River entry views only show space content.
  Generic clients may ignore these custom types. No duplicate fallback event is sent.
- Reactions are standard `m.reaction` with `m.annotation`, target event ID and key.
  Sticker keys use `sticker:<http-or-https-image-url>`; Gravitas validates these
  references, retains idempotent add/remove operations, and requires sign-in for
  public post and comment reactions. Comment targets are checked against the
  current post audience before joining the public comment room.
- Linked images use Markdown image destinations; bare image URLs with supported
  extensions also render inline. Stickers retain the image's original animated
  bytes and use the `river-sticker` Markdown image title. “Make sticker” saves a
  separate sticker on this device; the sticker picker can insert it in messages,
  replies, discussions or posts. There is no reverse conversion action. Saved
  stickers are separate from room file caches, with a 100-item / 128 MiB budget.
  The original host must remain reachable when sharing a saved sticker by URL.
  Web fetches use River's anonymous `/api/public/media` relay to support hosts
  without CORS; native clients load directly. The relay accepts raster images
  up to 25 MiB, retains GIF bytes, strips credentials and upstream headers, bounds
  redirects/concurrency, and rejects private network addresses at connection time.
  The relay sees the external image URL; Matrix encrypted attachments continue
  through the separate device-encrypted attachment transport.
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
The Matrix SDK device session is saved after authenticated operations, including
failed requests that refreshed credentials. Refreshes wake a pending sync so an
idle device also saves its replacement tokens. A temporary secure-storage failure
retains the rotated session in memory for retry while the app remains open; logout
discards it. Reconnecting preserves the device's encrypted store and keys.

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

Native desktop builds, automatic publishing and Private Store updates: [DESKTOP_RELEASES.md](DESKTOP_RELEASES.md).
