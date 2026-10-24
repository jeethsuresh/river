#!/usr/bin/env python3
"""Create local, protected RTC configuration; never print or publish credentials."""
import argparse, json, os, pathlib, secrets
p=argparse.ArgumentParser();p.add_argument('--directory',required=True);a=p.parse_args()
d=pathlib.Path(a.directory).expanduser().resolve();d.mkdir(mode=0o700,parents=False,exist_ok=False)
os.chmod(d,0o700)
key='river_'+secrets.token_hex(12);secret=secrets.token_urlsafe(48);turn=secrets.token_urlsafe(48)
def save(name,text):
 path=d/name
 fd=os.open(path,os.O_WRONLY|os.O_CREAT|os.O_EXCL,0o600)
 with os.fdopen(fd,'w') as f:f.write(text)
save('river.env',f'LIVEKIT_URL=wss://rtc.gravitas.cool\nLIVEKIT_API_KEY={key}\nLIVEKIT_API_SECRET={secret}\nTURN_URIS=turns:turn.gravitas.cool:443?transport=tcp\nTURN_SHARED_SECRET={turn}\nTURN_FORCE_RELAY=true\n')
save('turn-secret',turn+'\n')
save('config.yaml',f'''port: 7880
bind_addresses: ["0.0.0.0"]
keys:
  {key}: {secret}
rtc:
  use_external_ip: false
  udp_port: 7882
  tcp_port: 0
  stun_servers: []
  turn_servers:
    - host: turn.gravitas.cool
      port: 443
      protocol: tls
      secret_file: /run/river/turn-secret
      ttl: 300
room:
  max_participants: 32
logging:
  level: warn
''')
save('turnserver.conf',f'''tcp-proxy-port=8443
realm=turn.gravitas.cool
server-name=turn.gravitas.cool
fingerprint
use-auth-secret
static-auth-secret={turn}
no-tls
no-dtls
no-udp
no-tcp-relay
no-multicast-peers
no-cli
no-software-attribute
min-port=50000
max-port=51000
relay-threads=1
user-quota=8
total-quota=128
max-bps=2000000
bps-capacity=10000000
log-file=stdout
simple-log
no-stdout-log
pidfile=/tmp/turnserver.pid
''')
print('Protected configuration created. Apply the three secrets using the commands in deploy/media/README.md.')
