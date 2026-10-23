#!/usr/bin/env python3
"""Publish only an unchanged, verified signed River release from main."""
import argparse, hashlib, os, pathlib, re, shutil, subprocess

root = pathlib.Path(__file__).resolve().parents[1]
p = argparse.ArgumentParser()
p.add_argument('--publish', action='store_true', help='Publish the stable release; otherwise create a draft.')
p.add_argument('--verified-build', action='store_true', help='Use the existing build; identity verification always runs.')
args = p.parse_args()
def run(*command, capture=False):
    return subprocess.run([str(c) for c in command], cwd=root, check=True, text=True, capture_output=capture).stdout
if run('git', 'status', '--porcelain', capture=True).strip():
    raise SystemExit('Commit release source before publishing.')
if run('git', 'branch', '--show-current', capture=True).strip() != 'main':
    raise SystemExit('Publish from main after the feature PR is merged.')
version = re.search(r'^version:\s*(\d+\.\d+\.\d+)\+(\d+)\s*$', (root / 'client/pubspec.yaml').read_text(), re.M)
if not version:
    raise SystemExit('Use a stable version and build number.')
tag = 'v' + version[1]
if subprocess.run(['gh', 'release', 'view', tag, '--repo', 'jeethsuresh/river'], capture_output=True).returncode == 0:
    raise SystemExit('Published versions are immutable. Increase version and build number.')
existing = subprocess.run(['git', 'ls-remote', '--exit-code', '--tags', 'origin', 'refs/tags/' + tag], cwd=root, capture_output=True)
if existing.returncode == 0:
    raise SystemExit('Release tag already exists. Inspect it instead of overwriting it.')
if existing.returncode != 2:
    raise SystemExit('Cannot verify remote release tag availability.')
if not args.verified_build:
    run('python3', root / 'scripts/build-android.py')
apk = root / 'client/build/app/outputs/flutter-apk/app-release.apk'
run('python3', root / 'scripts/verify-android.py', apk)
dist = root / '.release'
dist.mkdir(exist_ok=True)
asset = dist / ('River-' + tag + '-android.apk')
shutil.copyfile(apk, asset)
checksums = dist / 'SHA256SUMS'
checksums.write_text(hashlib.sha256(asset.read_bytes()).hexdigest() + '  ' + asset.name + '\n')
sha = run('git', 'rev-parse', 'HEAD', capture=True).strip()
run('git', 'tag', '-a', tag, '-m', 'River ' + version[1])
run('git', 'push', 'origin', tag)
command = ['gh', 'release', 'create', tag, asset, checksums, '--repo', 'jeethsuresh/river', '--verify-tag',
    '--target', sha, '--title', 'River ' + version[1], '--notes-file', root / 'docs/RELEASE_NOTES.md']
if not args.publish:
    command.append('--draft')
run(*command)
