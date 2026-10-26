Cargokit is vendored from Flutter Rust Bridge 2.13.0's integration template.

River changes:
- `build_tool/lib/src/builder.dart`: default Rust toolchain is `1.96.0`.
- `build_tool/lib/src/rustup.dart`: numbered toolchains count as installed official toolchains, alongside stable/beta/nightly.

The native build passes `--locked` through `rust/cargokit.yaml`. The original MIT license is retained unchanged in `LICENSE`.
