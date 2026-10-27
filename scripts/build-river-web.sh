#!/usr/bin/env bash
set -euo pipefail
root=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
cd "$root/client"
output=build/web
previous=
for argument in "$@"; do
  if [[ $previous == --output || $previous == -o ]]; then output=$argument; fi
  case "$argument" in --output=*) output=${argument#--output=} ;; esac
  previous=$argument
done
flutter build web "$@"
dart tool/cache_web_shell.dart "$output"
