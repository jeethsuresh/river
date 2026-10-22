# River

River is a Go backend serving **one Flutter frontend shared by web and Android**.
It follows Orbit's home experience: a blue workspace sidebar, a welcome view,
recent posts/discussions, spaces and conversations. This replaces the previous
Next.js River code; Git history retains that implementation.

## Initial vertical slice

- Gravitas PKCE sign-in with explicit scopes and group selection.
- Spaces and DM/group conversations backed by real Gravitas groups/Matrix rooms.
- Owner invitations, invitation acceptance/decline, rename and leaving.
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
- Currently each space has a single root timeline. Separate channels are not yet
  implemented. The next slice should create one room/group per channel, link it via
  `m.space.child`/`m.space.parent`, and atomically maintain child membership with
  parent membership. Matrix space links alone do not grant access. Never approximate
  this by trusting a client-supplied parent ID.
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
`PUT /:id/events/:type/:txn_id`. They use opaque, revocable app tokens, not IAM JWTs.
The additive server change is in `jeethsuresh/iam-server` branch
`codex/river-groups-events`, based on the existing Gravitas deployment branch.

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

The Android identifier is `cool.gravitas.river`. Debug builds are development
artifacts; a stable signing identity and distribution policy are needed before
publishing an upgradeable release. Never reuse Orbit's identity or signing key.

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

1. Separate text/RTC channel rooms, standard space hierarchy and atomic ACL
   propagation/removal, with cross-channel/parent membership tests.
2. Persisted read positions, unread counts, pagination and event-driven updates.
   Current views show the latest 100 events and refresh every 15 seconds while
   foregrounded; home inspects 12 groups and 30 recent events per group.
3. Friend requests, acceptance/removal, blocking and a private friends list.
   The current People view lists group members and makes no friendship claim.
4. Deploy TURN (UDP/TCP/TLS, ephemeral credentials, quotas) and a MatrixRTC-compatible
   SFU/focus, then implement MatrixRTC membership, signaling, voice/video/screen
   sharing and cleanup. STUN discovers addresses; **TURN relays media**.
   `/api/rtc` currently reports `enabled=false`, even when credential config exists.
5. Standard-client interoperability tests, complete Matrix discovery/capabilities,
   account data, event relations/pagination, moderation, encryption and federation
   where required. Standard replies/reactions alone do not imply full compatibility.
6. App token refresh and durable single-use native handoffs; Android release signing,
   browser-to-phone media/network tests, accessibility and background/lifecycle work.

Protocol references: [Matrix events and spaces](https://spec.matrix.org/v1.16/client-server-api/),
[MatrixRTC](https://github.com/matrix-org/matrix-spec-proposals/pull/4143).
