"""Disposable HTTPS Matrix peer for the installed Android SDK regression test.

Only the disposable emulator trusts its generated CA. No production account or service is used.
"""
import collections
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
import json
import os
from pathlib import Path
import ssl
import subprocess
import threading
from urllib.parse import urlsplit

FIXTURE = Path(os.environ['RUNNER_TEMP']) / 'river-android-matrix-fixture'
USER = '@alice:localhost:8448'
ACCESS = 'disposable-android-fixture-access-token'


def prepare():
    FIXTURE.mkdir(parents=True, exist_ok=True)
    (FIXTURE / 'extensions.cnf').write_text('''subjectAltName=DNS:localhost
basicConstraints=critical,CA:FALSE
keyUsage=critical,digitalSignature,keyEncipherment
extendedKeyUsage=serverAuth
''')
    for name in ['trusted', 'untrusted']:
        subprocess.run([
            'openssl', 'req', '-x509', '-newkey', 'rsa:2048', '-nodes',
            '-keyout', str(FIXTURE / f'{name}-ca.key'),
            '-out', str(FIXTURE / f'{name}-ca.pem'), '-days', '2',
            '-subj', f'/CN=River Android {name} test CA',
            '-addext', 'basicConstraints=critical,CA:TRUE',
            '-addext', 'keyUsage=critical,keyCertSign,cRLSign',
        ], check=True, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
        subprocess.run([
            'openssl', 'req', '-newkey', 'rsa:2048', '-nodes',
            '-keyout', str(FIXTURE / f'{name}.key'),
            '-out', str(FIXTURE / f'{name}.csr'), '-subj', '/CN=localhost',
        ], check=True, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
        subprocess.run([
            'openssl', 'x509', '-req', '-in', str(FIXTURE / f'{name}.csr'),
            '-CA', str(FIXTURE / f'{name}-ca.pem'),
            '-CAkey', str(FIXTURE / f'{name}-ca.key'), '-CAcreateserial',
            '-out', str(FIXTURE / f'{name}.pem'), '-days', '2',
            '-extfile', str(FIXTURE / 'extensions.cnf'),
        ], check=True, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
        (FIXTURE / f'{name}.key').chmod(0o600)
        (FIXTURE / f'{name}-ca.key').unlink()



class Fixture:
    def __init__(self):
        self.counts = collections.Counter()
        self.lock = threading.Lock()
        self.servers = []
        self.violations = []

    def __enter__(self):
        fixture = self

        class Handler(BaseHTTPRequestHandler):
            def log_message(self, *_):
                pass  # Never log auth headers or login/session response bodies.

            def do_GET(self):
                self.respond()

            def do_POST(self):
                self.respond()

            def do_PUT(self):
                self.respond()

            def respond(self):
                path = urlsplit(self.path).path
                body = json.loads(self.rfile.read(int(self.headers.get('Content-Length', 0))) or b'{}')
                with fixture.lock:
                    fixture.counts[self.command, path] += 1
                    if self.server.server_port != 8448:
                        fixture.violations.append('Untrusted TLS reached HTTP')
                    if self.headers.get('Host', '').startswith('127.0.0.1'):
                        fixture.violations.append('Wrong certificate hostname reached HTTP')
                status, data = 200, {}
                if path == '/_matrix/client/versions':
                    data = {'versions': ['v1.11'], 'unstable_features': {}}
                elif path == '/_matrix/client/v3/login':
                    assert self.server.server_port == 8448, 'Untrusted TLS reached HTTP'
                    assert body.get('token') == 'android-fixture-one-use-token', 'Invalid TLS reached login'
                    assert body.get('type') == 'm.login.token'
                    assert fixture.counts[self.command, path] == 1, 'One-use login token replayed'
                    data = {'user_id': USER, 'device_id': 'ANDROID-FIXTURE',
                            'access_token': ACCESS, 'refresh_token': 'disposable-refresh',
                            'expires_in_ms': 3600000}
                elif self.headers.get('Authorization') != 'Bearer ' + ACCESS:
                    status, data = 401, {'errcode': 'M_UNKNOWN_TOKEN', 'error': 'Not authenticated'}
                elif path == '/_matrix/client/v3/sync':
                    data = {'next_batch': str(fixture.counts[self.command, path]),
                            'rooms': {}, 'account_data': {'events': []},
                            'to_device': {'events': []},
                            'device_lists': {'changed': [], 'left': []},
                            'device_one_time_keys_count': {'signed_curve25519': 50}}
                elif path == '/_matrix/client/v3/keys/upload':
                    data = {'one_time_key_counts': {'signed_curve25519': 50}}
                elif path == '/_matrix/client/v3/keys/query':
                    data = {'device_keys': {}, 'failures': {}}
                elif path == '/_matrix/client/v3/capabilities':
                    data = {'capabilities': {}}
                elif path == '/_matrix/client/v3/account/whoami':
                    data = {'user_id': USER, 'device_id': 'ANDROID-FIXTURE'}
                elif path == '/_matrix/client/v3/logout':
                    pass
                else:
                    status, data = 404, {'errcode': 'M_NOT_FOUND', 'error': 'No account data'}
                encoded = json.dumps(data).encode()
                self.send_response(status)
                self.send_header('Content-Type', 'application/json')
                self.send_header('Content-Length', str(len(encoded)))
                self.end_headers()
                self.wfile.write(encoded)

        for port, name in [(8448, 'trusted'), (8449, 'untrusted')]:
            server = ThreadingHTTPServer(('127.0.0.1', port), Handler)
            context = ssl.SSLContext(ssl.PROTOCOL_TLS_SERVER)
            context.load_cert_chain(FIXTURE / f'{name}.pem', FIXTURE / f'{name}.key')
            server.socket = context.wrap_socket(server.socket, server_side=True)
            self.servers.append(server)
            threading.Thread(target=server.serve_forever, daemon=True).start()
        return self

    def verify(self):
        assert not self.violations, self.violations
        assert self.counts['POST', '/_matrix/client/v3/login'] == 1, self.counts
        assert self.counts['GET', '/_matrix/client/v3/sync'] >= 3, self.counts
        assert self.counts['POST', '/_matrix/client/v3/logout'] == 1, self.counts
        print('ANDROID MATRIX HTTPS PASS login, sync, persisted-device restore, logout', flush=True)

    def __exit__(self, *_):
        for server in self.servers:
            server.shutdown()
            server.server_close()


if __name__ == '__main__':
    prepare()
