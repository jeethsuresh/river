#!/usr/bin/env python3
"""Create River's permanent Android key once; never rotate an existing app identity."""
import argparse, hashlib, json, os, pathlib, secrets, shutil, subprocess

root = pathlib.Path(__file__).resolve().parents[1]
p = argparse.ArgumentParser()
p.add_argument('--directory', type=pathlib.Path, default=root / '.signing')
args = p.parse_args()
folder = args.directory.resolve()
folder.mkdir(mode=0o700, parents=True, exist_ok=True)
folder.chmod(0o700)
if any(folder.iterdir()):
    raise SystemExit('Signing directory is not empty. Preserve the original key and configuration.')
if (root / 'client/android/release-certificate.sha256').exists():
    raise SystemExit('A release certificate is already pinned. Recover the original key instead of replacing it.')
keytool = str(pathlib.Path(os.environ['JAVA_HOME']) / 'bin/keytool') if os.environ.get('JAVA_HOME') else shutil.which('keytool')
if not keytool:
    raise SystemExit('Set JAVA_HOME to an installed JDK.')
config = {'storeFile': str(folder / 'river-release.jks'), 'storePassword': secrets.token_urlsafe(32),
    'keyAlias': 'river-release', 'keyPassword': secrets.token_urlsafe(32)}
env = {**os.environ, 'RIVER_STORE_PASSWORD': config['storePassword'], 'RIVER_KEY_PASSWORD': config['keyPassword']}
subprocess.run([keytool, '-genkeypair', '-keystore', config['storeFile'], '-storetype', 'JKS',
    '-alias', config['keyAlias'], '-storepass:env', 'RIVER_STORE_PASSWORD', '-keypass:env', 'RIVER_KEY_PASSWORD',
    '-keyalg', 'RSA', '-keysize', '4096', '-validity', '10000', '-dname', 'CN=River Android Release, O=Jeeth Suresh'],
    env=env, check=True, capture_output=True)
pathlib.Path(config['storeFile']).chmod(0o600)
with os.fdopen(os.open(folder / 'signing.json', os.O_WRONLY | os.O_CREAT | os.O_EXCL, 0o600), 'w') as f:
    json.dump(config, f, indent=2)
    f.write('\n')
certificate = subprocess.check_output([keytool, '-exportcert', '-keystore', config['storeFile'],
    '-alias', config['keyAlias'], '-storepass:env', 'RIVER_STORE_PASSWORD'], env=env, stderr=subprocess.PIPE)
digest = hashlib.sha256(certificate).hexdigest()
(root / 'client/android/release-certificate.sha256').write_text(digest + '\n')
print('Created protected permanent River signing identity. Back up the private directory securely. Public certificate SHA256:', digest)
