River 0.4.0 brings Orbit's conversations, publishing, files and calling to the shared Flutter web and Android app.

- Create separate channels, invite contacts to spaces, and start private or friend-selected group conversations.
- See live activity and online friends, catch up on unread posts/discussions/channels, and return to recent participating threads.
- Format messages, replies, posts and discussions with Markdown tools, keyboard shortcuts and previews. Edit your posts and discussions.
- Publish shareable posts and space blogs with independent member/public/disabled comment policies. Earlier member comments stay private.
- Share files directly between connected peers, with verified local copies, progress, retry and retained-copy retrieval. Files have no cloud backup.
- Join voice/video calls in conversations and drop-in rooms, share your screen, and use call-only chat, mute/deafen, speaker and camera controls.
- Keep shared contacts, account consent and access decisions in Gravitas. Existing users must reconnect to approve calling/publication permissions.

The matching Gravitas API migration and River web/backend must be rolled out before the new features are available. Calling additionally requires the configured SFU/TURN media service. Automatic GitHub deployments remain disabled.

Android 7.0 or newer is required by the updated Flutter runtime. Android uses River's existing package and permanent signing certificate. Physical-device Bluetooth, network handoff and large-call capacity have not been verified. Gravitas supplies a Matrix API subset, without federation or end-to-end encryption.
