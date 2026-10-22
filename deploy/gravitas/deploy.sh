#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")"
: "${1:?Pass the ghcr.io image digest}"
server="$(kubectl config view --minify -o jsonpath='{.clusters[0].cluster.server}')"
[[ "$server" == 'https://02fe9a55-8048-421e-a03f-eae9a4a60472.k8s.ondigitalocean.com' ]] || { echo 'Refusing an unexpected cluster' >&2; exit 1; }
python3 render.py "$1" | kubectl apply --server-side --field-manager=gravitas-deploy -f -
kubectl -n river rollout status deployment/river --timeout=300s
# Certificate validation stays enabled. An untrusted certificate fails release verification.
curl --fail --silent --show-error --retry 5 --retry-delay 5 https://chat.gravitas.cool/healthz

