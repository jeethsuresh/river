#!/usr/bin/env bash
set -euo pipefail
# Compress at build time, never on the request's CPU budget.
root="${1:?web build directory required}"
while IFS= read -r -d '' asset; do
  gzip -n -9 -c "$asset" > "$asset.gz"
  sha256sum "$asset" | cut -d ' ' -f 1 > "$asset.etag"
done < <(find "$root" -type f \( -name '*.js' -o -name '*.wasm' -o -name '*.css' -o -name '*.svg' -o -name '*.json' -o -name '*.ttf' \) -size +1024c -print0)
