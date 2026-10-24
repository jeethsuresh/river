# River 0.5.0

Complete the remaining gaps found against Orbit main f8abebc in the shared Flutter
web and Android client:

- Visual rich-text editing, Markdown and preview modes, undo/redo, safe link editing
  and formatting shortcuts in messages, replies, posts, discussions and call chat.
- Search conversations by name or member. Expand channel-specific recent threads,
  collapse text/voice sections and see voice-room occupancy.
- Separate unread posts, discussions, channel activity and conversations. Long posts
  cannot crowd discussions out of Home, and opening entries clears their markers.
- Keep published-post reactions and comment counts consistent between feed and
  detail while preserving earlier member-only reactions in private event history.
- Preserve permission errors when joining calls, with a direct Gravitas reconnect.

Uses the same permanent Android signing certificate and minimum Android 7.0 (API
24) as 0.4.0. Gravitas handles accounts; password recovery is deferred. Automatic
GitHub deployments remain disabled. Physical-device Bluetooth/network handoff and
large-call capacity are not claimed as verified. See docs/ORBIT_PARITY.md for the
source audit and integration boundaries.
