# River 0.8.0 (Android build 13)

- Conversations are single Matrix rooms and show chat only. Posts and discussions belong to spaces, which can contain multiple conversation rooms.
- Space posts and discussions use custom Matrix event objects with an explicit owning space ID. Conversation and channel targets are rejected by the server as well as the client.
- River requests full Matrix access to current and future spaces and conversations at sign-in. Existing accounts must approve this new permission; membership and account permissions still apply.
- Space feeds and authored edits use the space content API. Existing immutable Matrix history is retained.
- Reopen existing direct conversations using the Matrix SDK's encryption state and permissions. Preserve encrypted rooms, require encryption for new direct rooms, and avoid an unauthorized encryption change when opening an existing unencrypted room.

Requires the matching Gravitas Matrix server update before deploying River. Uses the existing permanent River Android signing certificate and package.
