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
  verifier challenge and five-minute, single-use exchange. Passwords never enter River.
- Every protected request validates the central session proof; central logout and
  consent revocation deny subsequent access. IAM outages fail closed.

The backend has **no independent message database**. It relays a fixed allowlist of
routes to the configured HTTPS IAM origin, using a confidential delegated token.
No admin, IAM signing key or Matrix password is deployed to River.

This is an initial slice. It is not the full Orbit feature set or a fully conformant
Matrix homeserver. The existing Gravitas server implements a Matrix API subset.

## Exact current mapping and event contract

A Gravitas group already **is** a `rooms` UUID with `room_memberships`; there is no
second group table. River preserves that single source of access decisions.

- A River space maps 1:1 to that group and `!<uuid>:gravitas.cool`, with
  `m.room.create.content.type = m.space`.
- A River DM/group conversation maps 1:1 to a normal Matrix room and group. Its
  `cool.gravitas.river.group.v1` state identifies `kind=dm`. Invitations use
  `m.room.member` with `is_direct=true`. Private Matrix `m.direct` account data is
  not yet implemented, so automatic DM recognition by other clients is incomplete.
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
  hide another person's block events. These are delegated private account APIs;
  full standard Matrix account-data endpoints remain pending.
  Blocks stop contact requests and direct messages, while shared space channels
  retain their normal group ACL. Creating a canonical DM additionally checks the
  contact's current app consent. Reopening an already-joined DM still requires
  that room in the app's approved selection.
- A future RTC channel also needs its own room/group. MatrixRTC membership/signaling
  and media authorization must bind to that room and the current membership.
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
members cannot read through River. End-to-end encryption is not implemented.

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

The Dockerfile pins the same Flutter SDK revision used by the existing Spacetime
service: `d3abd00e69a89a615e13969c02832ef1e0119639` (3.32.0-0.2.pre).
Go is pinned to 1.25.2 for the image. Dependencies are locked in `client/pubspec.lock`.

```
cd backend
go test -race ./...
go vet ./...
cd ../client
flutter pub get --enforce-lockfile
flutter analyze
flutter test
flutter build web --release --no-web-resources-cdn
flutter build apk --debug --target-platform android-arm64,android-x64
```

The Android identifier is `cool.gravitas.river`. The permanent public certificate
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

After tests pass and source merges to `main`, `scripts/release.py` creates a draft
stable GitHub release with only `River-vVERSION-android.apk` and `SHA256SUMS`.
`--publish` publishes that verified release for Private Store ingestion. Existing
versions/tags are never overwritten. The store pins the same package/certificate.

Configure the Go process with `GRAVITAS_SESSION_KEY` (32 random bytes, base64url),
`GRAVITAS_ISSUER=https://gravitas.cool`, `APP_URL=https://chat.gravitas.cool`,
`STATIC_DIR=/app/web` and `ADDR=:8080`. The session key belongs in a Kubernetes
Secret. Session envelopes deliberately expire before their delegated access token
(one hour); sign in again using existing IAM consent. Token refresh is a next task.
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
namespaced resources. CI tests and publishes branch images. Main-branch deployment
is opt-in through `GRAVITAS_DEPLOY_ENABLED=true` and an environment-scoped,
namespace-limited `GRAVITAS_KUBECONFIG`, following RSS/Office/Spacetime patterns.

## Next implementation tasks

1. Extend the implemented threaded replies, reversible reactions, authored edits
   and Markdown previews with public posts/comment policies, shareable links and discovery.
2. Event-driven updates and private presence. The current frontend refreshes every
   five seconds while foregrounded; timelines paginate beyond the latest 100 events,
   and home uses a single batched feed across all accessible groups (latest 200).
3. Friend-selected multi-person conversations and attachments/file exchange.
4. Deploy TURN (UDP/TCP/TLS, ephemeral credentials, quotas) and a MatrixRTC-compatible
   SFU/focus, then implement MatrixRTC membership, signaling, voice/video/screen
   sharing and cleanup. STUN discovers addresses; **TURN relays media**.
   `/api/rtc` currently reports `enabled=false`, even when credential config exists.
5. Standard-client interoperability tests, complete Matrix discovery/capabilities,
   account data, event relations/pagination, moderation, encryption and federation
   where required. Standard replies/reactions alone do not imply full compatibility.
6. App token refresh and durable single-use native handoffs;
   browser-to-phone media/network tests, accessibility and background/lifecycle work.

Protocol references: [Matrix events and spaces](https://spec.matrix.org/v1.16/client-server-api/),
[MatrixRTC](https://github.com/matrix-org/matrix-spec-proposals/pull/4143).

## Contacts release compatibility

Install IAM contacts API/migration `20261023120000` before this client/backend.
The migration adds a persisted event type while preserving existing social data.
Follow the main server's contacts contract in `jeethsuresh/iam-server/docs/contacts.md`.
River's permanent package/certificate are unchanged; the existing Private Store
catalog can ingest a verified stable 0.3.0 release after manual release approval.
Publish the stable APK after the matching API and web release is verified.
