# River media service

This is a separate, manual platform addition. The app workflow does not apply it.
Use the private Gravitas deployment knowledge and check current cluster capacity
before rollout. Both app deployment holds must remain false for a manual release.

The pinned LiveKit SFU and Coturn relay use one private pod each, reserving 350m
CPU and 640Mi memory together. These are initial bounded reservations, not a
verified participant-capacity guarantee.
The broker and SFU use LiveKit’s zero default (no configured room participant
ceiling). TURN allocation quotas, bandwidth safeguards and resource limits stay
bounded. See [the verification ledger](../../docs/VERIFICATION_GAPS.md) for the
64-participant signaling-only check and the remaining media load tests. There is no new load balancer, public UDP
port, host networking, database, or copied TLS key. Existing Traefik terminates
HTTPS/WSS for rtc.gravitas.cool and TURN/TLS on turn.gravitas.cool:443. The TURN
TCP route forwards PROXY v2 to a single Coturn proxy listener. The official
Coturn binary carries a file capability, so its non-root container retains only
NET_BIND_SERVICE in the bounding set; other capabilities are dropped. Both names use the
existing wildcard DNS and certificate.

All clients force relay. SFU and peer-file candidates remain private pod IPs.
TURN network policy permits UDP only to its own allocation range and the SFU's
media port, preventing credentials from becoming a general internet or internal
network proxy. The SFU can return only to TURN allocations. Coturn REST credentials
last five minutes; clients renew ICE configuration before expiry. Central call
membership renews every 20 seconds and expires after 70 seconds; the Go coordinator
removes revoked/expired SFU participants, including after coordinator restart.

Prepare local configuration in a fresh protected directory outside the repository:

```
python3 deploy/media/create-secrets.py --directory /absolute/private/river-media
kubectl --context do-tor1-gravitas-k8s-services -n river create secret generic river-media-runtime --from-env-file=/absolute/private/river-media/river.env
kubectl --context do-tor1-gravitas-k8s-services -n river create secret generic river-sfu-config --from-file=/absolute/private/river-media/config.yaml --from-file=/absolute/private/river-media/turn-secret
kubectl --context do-tor1-gravitas-k8s-services -n river create secret generic river-turn-config --from-file=/absolute/private/river-media/turnserver.conf
kubectl --context do-tor1-gravitas-k8s-services apply --server-side --dry-run=server -f deploy/media/resources.json
kubectl --context do-tor1-gravitas-k8s-services apply --server-side --field-manager=river-media -f deploy/media/resources.json
kubectl --context do-tor1-gravitas-k8s-services -n river rollout status deployment/river-sfu
kubectl --context do-tor1-gravitas-k8s-services -n river rollout status deployment/river-turn
```

Preserve the generated originals; do not regenerate/overwrite production secrets.
The app deployment reads `river-media-runtime` optionally, so a non-media install
still starts. IAM needs `MATRIX_RTC_URL=wss://rtc.gravitas.cool` after its workspace
migration. Deploy IAM first using its maintenance adapter, then River's exact
verified image. Verify HTTPS, TURN/TLS certificate validation, a selected relay
candidate, actual decoded media and peer-file bytes before calling media live.
Do not consider a ready pod or a successful STUN binding a media test.

The manifests and local transport tests do not prove physical Android Bluetooth,
mobile-network handoff, or multi-party production capacity. RTC uses versioned
Matrix sticky membership/slot events with a LiveKit transport, within Gravitas's
existing Matrix API subset; this is not full homeserver/federation/E2EE support.
