#!/usr/bin/env bash
set -euo pipefail
# Shared by Android CI and local/native builds. Cargokit uses this same pin.
rustup toolchain install 1.96.0 --profile minimal
rustup default 1.96.0
rustc --version | grep -q '^rustc 1.96.0 '
