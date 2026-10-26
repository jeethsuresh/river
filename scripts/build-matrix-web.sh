#!/usr/bin/env bash
set -euo pipefail
root=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
manifest="$root/client/packages/river_matrix/rust/Cargo.toml"
rustc --version | grep -q '^rustc 1.96.0 '
wasm-bindgen --version | grep -q '^wasm-bindgen 0.2.129$'
cargo build --manifest-path "$manifest" --locked --release --target wasm32-unknown-unknown
artifact_root=${CARGO_TARGET_DIR:-"$(dirname "$manifest")/target"}
wasm-bindgen "$artifact_root/wasm32-unknown-unknown/release/river_matrix_core.wasm" \
  --target no-modules --no-typescript --out-name river_matrix_core --out-dir "$root/client/web/pkg"
test -s "$root/client/web/pkg/river_matrix_core.js"
test -s "$root/client/web/pkg/river_matrix_core_bg.wasm"
