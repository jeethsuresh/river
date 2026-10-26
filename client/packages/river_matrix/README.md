# River Matrix adapter

River's local adapter uses Matrix Rust SDK 0.19.1 and Flutter Rust Bridge 2.13.0. It supplies the standard Matrix account/device, room, sync, timeline and encryption paths while River retains its Flutter UI and Gravitas contacts, publishing and calls.

Android, iOS, macOS, Windows and Linux bundle the native Rust library through Cargokit. Flutter web loads the same core as WebAssembly and uses IndexedDB. CI builds each platform. Rust is pinned to 1.96.0; the application and package Dart lockfiles and Rust Cargo.lock are tracked.

The bridge exposes asynchronous operations and an opaque session handle. Browser Matrix/IndexedDB objects stay on the browser event loop. No unsafe Send/Sync implementation is used. Native clients use the encrypted SQLite store; browsers use the encrypted IndexedDB store. The per-account store passphrase and Matrix session are held by Flutter secure storage. River's Go relay only brokers a one-use, proof-bound SSO login token, and receives no Matrix access token or encryption secret.

QR verification advertises `m.qr_code.show.v1`, `m.qr_code.scan.v1` and `m.reciprocate.v1`, with SAS number comparison as a fallback. The SDK validates binary QR transaction/device/master keys and requires confirmation on the displaying device before it trusts the other device. Cross-signing, encrypted secret sharing, secret storage and encrypted room-key backups use the SDK implementations. Verification is restricted to the current user's own devices. Image scanning works on all six platforms; camera availability depends on the device and browser. Native camera capture removes the plugin's temporary frame immediately after reading it.

Build web assets from the locked sources before building the Flutter application:

```sh
bash scripts/matrix-toolchain.sh
rustup target add wasm32-unknown-unknown --toolchain 1.96.0
cargo install --locked wasm-bindgen-cli --version 0.2.129
bash scripts/build-matrix-web.sh
cd client
flutter pub get --enforce-lockfile
flutter build web --release --no-pub --no-web-resources-cdn
```

Run Rust tests with `cargo test --locked --manifest-path client/packages/river_matrix/rust/Cargo.toml --lib`. The real two-device QR/backup/attachment test runs separately in the private-CA Gravitas fixture using `integration/matrix/run.sh`, and is an explicit CI prerequisite for shipping. Its test trust root and test password exist only in test code.

Cargokit retains its upstream MIT license. Local patches pin the numbered Rust toolchain and recognize numbered installed toolchains. The adapter is Apache-2.0; see LICENSE and NOTICE.
