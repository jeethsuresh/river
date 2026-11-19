# Encrypted Matrix interoperability tests

The River Matrix interoperability job runs against the CI-pinned Gravitas test server and independent modern and legacy Synapse homeservers. Both runs use temporary accounts and private container networks.

The federation regression creates an encrypted direct conversation through River’s Matrix engine and waits for the Synapse account to receive and accept the invitation. It then repeats the same checks in a conversation created on Synapse and joined by River.

- The room has encryption enabled before the recipient joins.
- Sends are rejected before joining and after leaving.
- Messages, replies and attachments reach both clients and decrypt with the expected content.
- Both homeservers return encrypted events. The test compares the downloaded attachment bytes with the original bytes.

Run from River’s repository root with the Gravitas fixture checkout pinned in `.github/workflows/gravitas.yml` at `.matrix-server`.

```sh
docker build -f .matrix-server/Dockerfile.tests -t river-matrix-server:test .matrix-server
docker build -f Dockerfile.matrix-tests -t river-matrix-client:test .
docker build --target matrix-browser-interop-client -t river-matrix-browser:test .

bash integration/matrix/run.sh river-matrix-server:test river-matrix-client:test .matrix-server river-matrix-browser:test
bash integration/matrix/run.sh river-matrix-server:test river-matrix-client:test .matrix-server '' legacy
```

The modern run also exercises existing device verification, recovery, and browser crypto tests. The legacy run exercises the federation regression with the Synapse 1.56 fixture and negotiated room versions.
