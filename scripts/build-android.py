#!/usr/bin/env python3
"""Build a release APK using River's protected permanent signing configuration."""
import json, os, pathlib, subprocess

root = pathlib.Path(__file__).resolve().parents[1]
config_path = pathlib.Path(os.environ.get('RIVER_SIGNING_CONFIG', root / '.signing/signing.json'))
if not config_path.is_file():
    raise SystemExit('Set RIVER_SIGNING_CONFIG to the protected original signing.json file.')
c = json.loads(config_path.read_text())
env = {**os.environ, 'RIVER_KEYSTORE': c['storeFile'], 'RIVER_STORE_PASSWORD': c['storePassword'],
    'RIVER_KEY_ALIAS': c['keyAlias'], 'RIVER_KEY_PASSWORD': c['keyPassword']}
subprocess.run([os.environ.get('FLUTTER', 'flutter'), '--no-version-check', 'build', 'apk', '--release'],
    cwd=root / 'client', env=env, check=True)
subprocess.run(['python3', str(root / 'scripts/verify-android.py'), str(root / 'client/build/app/outputs/flutter-apk/app-release.apk')], env=env, check=True)
