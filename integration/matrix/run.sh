#!/usr/bin/env bash
set -Eeuo pipefail
server_image=${1:?Pass the current Gravitas test image}
client_image=${2:?Pass the River Matrix test image}
server_source=${3:?Pass the pinned Gravitas source directory}
fixtures=$(mktemp -d)
name="river-matrix-qr-$$"
cleanup() {
  status=$?
  if (( status != 0 )); then
    for suffix in native synapse; do docker logs --tail 60 "$name-$suffix" 2>&1 || true; done
  fi
  for suffix in client native synapse pg; do docker rm -fv "$name-$suffix" >/dev/null 2>&1 || true; done
  docker network rm "$name" >/dev/null 2>&1 || true
  rm -rf "$fixtures"
  exit "$status"
}
trap cleanup EXIT
mkdir -p "$fixtures"
cp "$server_source/integration/matrix/homeserver.yaml" "$server_source/integration/matrix/log.config" "$fixtures/"
openssl req -x509 -newkey rsa:2048 -nodes -keyout "$fixtures/ca.key" -out "$fixtures/ca.pem" -days 2 \
  -subj '/CN=River isolated Matrix QR test CA' -addext 'basicConstraints=critical,CA:TRUE' -addext 'keyUsage=critical,keyCertSign,cRLSign' >/dev/null 2>&1
openssl req -newkey rsa:2048 -nodes -keyout "$fixtures/peer.key" -out "$fixtures/peer.csr" -subj '/CN=native.test' >/dev/null 2>&1
cat > "$fixtures/extensions.cnf" <<'EXT'
subjectAltName=DNS:native.test,DNS:reference.test
basicConstraints=critical,CA:FALSE
keyUsage=critical,digitalSignature,keyEncipherment
extendedKeyUsage=serverAuth
EXT
openssl x509 -req -in "$fixtures/peer.csr" -CA "$fixtures/ca.pem" -CAkey "$fixtures/ca.key" -CAcreateserial \
  -out "$fixtures/peer.pem" -days 2 -extfile "$fixtures/extensions.cnf" >/dev/null 2>&1
rm "$fixtures/ca.key"
chmod 600 "$fixtures/peer.key"
docker network create --internal "$name" >/dev/null
docker run -d --name "$name-pg" --network "$name" --network-alias postgres \
  -e POSTGRES_PASSWORD=postgres -e POSTGRES_DB=matrix_interop_native \
  postgres@sha256:721873c34ceb9f8d8fc265984940dc982404c105f19ad51be9fdc5970a6080ea >/dev/null
for attempt in $(seq 1 60); do
  if docker exec "$name-pg" pg_isready -h 127.0.0.1 -U postgres >/dev/null 2>&1; then break; fi
  if (( attempt == 60 )); then exit 1; fi
  sleep 1
done
docker run -d --name "$name-synapse" --network "$name" --network-alias reference.test \
  --user 0 --security-opt label=disable --read-only --tmpfs /data:rw --tmpfs /tmp:rw \
  -v "$fixtures:/fixtures:ro" --entrypoint python \
  ghcr.io/element-hq/synapse@sha256:b497dc97929056f25401ad3f4e8c7e82cb374cfaba07d7348a3c4ea3d1ae950f \
  -m synapse.app.homeserver --config-path /fixtures/homeserver.yaml >/dev/null
docker run -d --name "$name-native" --network "$name" --network-alias native.test --init \
  --security-opt label=disable -v "$fixtures:/fixtures:ro" \
  -e POSTGRES_HOST=postgres -e POSTGRES_USER=postgres -e POSTGRES_PASSWORD=postgres \
  -e WALLABY_SKIP=1 -e INTEROP_HOLD=1 -e INTEROP_SERVE_ONLY=1 \
  --entrypoint mix "$server_image" run --no-start integration/matrix/native.exs >/dev/null
for attempt in $(seq 1 90); do
  if docker logs "$name-native" 2>&1 | rg -q 'INTEROP CRYPTO SERVER READY'; then break; fi
  if [[ $(docker inspect -f '{{.State.Running}}' "$name-native") != true ]] || (( attempt == 90 )); then
    docker logs --tail 40 "$name-native"; exit 1
  fi
  sleep 1
done
docker run --name "$name-client" --network "$name" --security-opt label=disable \
  -v "$fixtures:/fixtures:ro" "$client_image"
