# Android message notifications

River receives background alerts through Private Store's `appstore/1.0.0` protocol. Install the signed River release, sign in to River and Private Store with the same Gravitas account, enable **App notifications** in Private Store, then enable **Settings → Message notifications** in River and approve Android's notification permission. Open Private Store after updating so it refreshes its supporting-app catalog. Private Store's optional **Allow screen-off notifications** setting controls delivery during Doze.

Gravitas applies Matrix push rules to both local and federated events. It queues an alert in the event's database transaction, then rechecks read receipts, membership, ignored users, account state and River/Store grants before handing it to the protocol relay. Muted events do not create alerts. Committed database notifications wake both workers promptly; lease recovery and bounded backoff handle failures. Pending payloads expire after seven days.

The relay sends one `push.broadcast` invocation per recipient/event. Private Store owns installed devices, certificate checks, durable replay and acknowledgements. River acknowledges authenticated Store provider reconciliation without maintaining a second device registry. The protocol receipt confirms durable acceptance, not Android display.

Native payload fields are `kind: "matrix.event"`, `issuer`, `subject`, `room_id`, `event_id` and a positive monotonic `sequence`. They contain no message body, sender, room title, ciphertext or access token. The native receiver checks the actual Binder UID and Private Store's permanent signing certificate. It binds the cached subject to River's encrypted saved-session fingerprint, respects notification permission/channel and per-account opt-in, and suppresses replay or older alerts. Sign-out clears displayed alerts and the binding. Tapping an alert opens only a joined or invited conversation belonging to the current account. Decryption happens when River opens normally.

The receiver uses `android.app.Application` and does not start Flutter, sync or a second network connection to display an alert. Private Store's shared foreground listener handles background networking. These notifications currently support Android; the Store protocol does not provide desktop or browser push delivery.

## Hosted configuration

Configure one distinct random credential of at least 32 characters in:

- River Secret `river/river-notifications`, key `provider-key` (`NOTIFICATION_PROVIDER_KEY`).
- Private Store's `appstore-notifications/app-keys`, adding `river=THE_CREDENTIAL` while preserving existing apps.
- IAM's `PROTOCOL_SERVICES`, adding `https://chat.gravitas.cool` with that key and `protocols.read`, `appstore.push`, `appstore.push.broadcast` permissions.

IAM's hosted overlay sets `MATRIX_APPSTORE_PUSH_ORIGIN=https://chat.gravitas.cool`. Independent homeservers leave it unset to disable this integration. Private Store's catalog pins River's package, permanent certificate, notification authority and backend origin. No user-supplied callback URL is accepted.

Run Flutter analysis/tests and Go race tests/vet. The Android CI emulator runs `StoreNotificationDeliveryTest` against the real OS notification manager, covering native display, replay/order, account/session changes, explicit disable, denied notification permission and unsigned Binder calls. IAM's Matrix/Store integration test checks the real encrypted-event outbox, protocol relay, Store stream and acknowledgement.
