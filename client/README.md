# Shared River client

The same `lib/` builds for Flutter web and Android. See the repository README for
authentication, verification and current scope. Web uses same-origin HttpOnly
cookies. Android links a session through the system browser and stores it in secure
platform storage. Production API origin is `https://chat.gravitas.cool`.

Android builds here are debug-signed development artifacts. Release signing and
physical-device call tests are outstanding.
