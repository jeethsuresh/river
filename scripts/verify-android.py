#!/usr/bin/env python3
"""Check the release's signature, immutable certificate, package and source version."""
import argparse, hashlib, os, pathlib, re, subprocess

root = pathlib.Path(__file__).resolve().parents[1]
p = argparse.ArgumentParser()
p.add_argument('apk', type=pathlib.Path)
apk = p.parse_args().apk.resolve()
sdk = pathlib.Path(os.environ.get('ANDROID_HOME', pathlib.Path.home() / 'Library/Android/sdk'))
tools = sdk / 'build-tools/35.0.0'
cert = subprocess.check_output([str(tools / 'apksigner'), 'verify', '--verbose', '--print-certs', str(apk)], text=True)
expected = (root / 'client/android/release-certificate.sha256').read_text().strip()
actual = re.findall(r'^Signer #\d+ certificate SHA-256 digest: ([a-f0-9]+)$', cert, re.M)
if not re.fullmatch('[a-f0-9]{64}', expected) or actual != [expected]:
    raise SystemExit('APK does not match the permanent River signing identity.')
if not any(s in cert for s in ['Verified using v2 scheme (APK Signature Scheme v2): true', 'Verified using v3 scheme (APK Signature Scheme v3): true']):
    raise SystemExit('APK must use v2 or v3 signing.')
metadata = subprocess.check_output([str(tools / 'aapt2'), 'dump', 'badging', str(apk)], text=True)
identity = re.search(r"package: name='([^']+)' versionCode='(\d+)' versionName='([^']+)'", metadata)
source = re.search(r'^version:\s*(\d+\.\d+\.\d+)\+(\d+)\s*$', (root / 'client/pubspec.yaml').read_text(), re.M)
if not identity or not source or tuple(identity.groups()) != ('cool.gravitas.river', source[2], source[1]):
    raise SystemExit('APK identity/version does not match River source.')
minimum = re.search(r"(?:minSdkVersion|sdkVersion):'(\d+)'", metadata)
if not minimum or minimum[1] != '24':
    raise SystemExit('Unexpected minimum Android version.')
if re.search(r"application-debuggable", metadata):
    raise SystemExit('Store APK must not be debuggable.')
print('Verified River', source[1], '/ code', source[2], '/ permanent certificate', expected)
print('APK SHA256:', hashlib.sha256(apk.read_bytes()).hexdigest())
