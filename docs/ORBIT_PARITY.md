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
Visual rich-text editing, Markdown source and preview modes work in every shared
composer, including undo/redo, link editing and keyboard formatting. Extended
Markdown that the visual document model cannot represent stays in source mode;
opening or switching modes never rewrites an existing draft. Mail and relative
links use the same validated navigation path as web links.
Public posts and paginated space blogs have shareable links and independent
comment policies. Public comment threads own separate access-control rooms;
existing private comments never become public. Captured draft audiences survive
policy changes. API tests cover privacy across Matrix sync/messages as well as River.
Home reads are durable and independent per entry/room/user. Opening a post or
discussion acknowledges that entry from every route. Catch-up has independently
bounded 20-post/20-discussion sections and 300-character previews, excludes history
before the current membership, and keeps channel activity and conversations
separate from entry and thread activity. Published posts use one canonical public
reaction anchor across feed and detail; pre-publication reactions remain private. Posts/discussions have
separate paginated feeds. Recent thread participation includes root authors and
reply authors, retains 72 hours of activity, and caps each room at five plus two
threads active within 24 hours. Channel navigation has independently collapsible
text/voice sections and per-channel thread shortcuts, live voice occupancy, and
conversation search by name or member. Live updates use authenticated SSE invalidation,
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


## Source audit for 0.5.0

Orbit main was checked again against the remote and remains
`f8abebcb407bc8a4d4e4920a6862e549f7ec3e00`. This audit uses its web and mobile
implementations, rather than a product wishlist or full Matrix specification.

- Workspace: `app/orbit-shell.tsx`, `app/space-navigation.tsx`, `app/orbit-ui.tsx`,
  `mobile/lib/ui/workspace.dart`, `lib/social.ts`, `lib/discovery.ts` and the rooms,
  channels, conversations, invitations, home, contacts and presence routes map to
  River's shell/workspace/friends widgets, delegated groups, central contacts and
  RiverWorkspace. Spaces, descriptions, channel navigation, direct/group chats,
  invitations/acceptance/ignore, members, requests/cancel/remove, online presence,
  unread sections, conversation search and recent thread shortcuts are present.
- Editing/content: `components/rich-editor-core.tsx`, `components/markdown.tsx`,
  `app/space-content.tsx`, public post/blog pages, `lib/content.ts` and mobile
  content/chat/reactions map to RichComposer, RichBody, ContentCard, EntryFeed,
  ThreadScreen, PostScreen, BlogScreen, RiverContent and RiverPublishing. The
  audit found and fixed the visual editor, link handling, feed reaction target,
  entry acknowledgement, unread crowding and channel-thread navigation gaps.
- Files: Orbit's files/file exchange/storage and peer mesh map to PeerFiles,
  PeerMesh and account-isolated FileCache. Selection, scope checks, immutable
  metadata, peer chunks/backpressure, hash verification, progress, retries, retained
  copies and cache eviction remain covered by 0.4 media tests and unit regressions.
- Calls: Orbit's web call controls, mobile core/calls and call screen map to
  RiverCalls, call widgets/chat, the native ongoing-call service, Gravitas leases
  and Go's LiveKit/TURN broker. Voice, camera, simultaneous screen sharing,
  participants, mute/deafen, speaker/flip, mini controls, switching calls and
  participant-only call chat are present. Permission errors now preserve the
  Gravitas reason and offer reconnect; media revocation remains server-enforced.
- Account routes map to Gravitas's account lifecycle and app authorization. River
  does not duplicate passwords or recovery. Recovery/email-for-recovery remains
  explicitly deferred. Orbit's three-owned-space product limit is not an enabled
  capability missing from River; Gravitas authorizes space creation centrally.

Verification evidence is recorded with the release. Functional coverage of the
reference is distinct from exhaustive device/network/load assurance: physical
Bluetooth, network handoff and high-participant call capacity remain unverified.
No claim of flawless operation, full Matrix conformance, federation or E2EE is made.

## Verification ledger

[VERIFICATION_GAPS.md](VERIFICATION_GAPS.md) records the remaining physical-device,
network, capacity, storage, accessibility and complete production journey checks.
The configured call participant ceiling has been removed from both the broker
and media configuration; a bounded 64-participant signaling admission check is
not a media capacity guarantee.
