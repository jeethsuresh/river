# Orbit behavior implemented in River

Reference: jeethsuresh/orbit main f8abebcb407bc8a4d4e4920a6862e549f7ec3e00.
The reference web home, mobile workspace, social/content/discovery/files code,
peer mesh, call screen and Android foreground service define this release.

## Workspace and people

Spaces have descriptions and separate text/drop-in channel rooms with lobby/lounge
defaults. Owner actions, invitations, acceptance/ignore, rename, remove and leave
are protected by Gravitas ACLs. Space membership propagates to child groups.
Contacts/friend requests are the central Gravitas graph, subject to mutual app
consent. Search/select up to 24 contacts for a group, or reuse a canonical pair DM.
Conversation space-invitation cards keep membership acceptance explicit.

## Content and discovery

Messages, posts, discussions, replies, reactions, edits, invitation cards,
publication policies, file metadata and call memberships remain distinct events.
Replies use canonical Matrix thread roots with quote metadata; reactions use
annotations/redactions and edits retain immutable replacement history.
Markdown tools/preview and keyboard formatting work in shared composers.
Public posts and paginated space blogs have shareable links and independent
comment policies. Public comment threads own separate access-control rooms;
existing private comments never become public. Captured draft audiences survive
policy changes. API tests cover privacy across Matrix sync/messages as well as River.
Home reads are durable and independent per entry/room/user. Posts/discussions have
separate paginated feeds. Recent thread participation includes root authors and
reply authors, retains 72 hours of activity, and caps each room at five plus two
threads active within 24 hours. Live updates use authenticated SSE invalidation,
PostgreSQL notifications and authorized refresh instead of idle polling.

## Peer files and calls

Peer attachments permit five files, 25MiB each/50MiB per message. SHA-256-verified
account-isolated local caches retain 256MiB with eviction. Data channels implement
chunking, backpressure, progress/retry and returning-peer retrieval from retained
copies. The server carries metadata/signaling; no file backup is promised.
Calls use separate device leases, sticky MatrixRTC slot/member events and a
LiveKit transport with standard encrypted WebRTC media. Voice/video/screen share,
mini call controls, active participants, mute/deafen, speaker/camera switching and
current-call-only chat share one Flutter implementation. Android carries an
ongoing-call foreground service and explicit OS permissions. TURN credentials
are scope-checked and refreshed before expiry; revocation/expiry removes media
participants, including after the Go coordinator restarts.

## Account and release boundaries

Gravitas handles registration, login, password changes, app permissions and central
logout; River never collects account passwords. Password recovery is explicitly
deferred by the user. Full Matrix homeserver conformance, federation, E2EE and
standard focus discovery are outside Orbit feature parity. Native physical-device
Bluetooth/network handoff and large-call load testing remain verification limits,
not claimed passes. See deploy/media/README.md for the separately applied media
resources and private TURN-only networking.
