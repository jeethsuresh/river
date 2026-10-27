#!/usr/bin/env python3
"""Exercise installed Android return links without any account credentials."""
import argparse
import os
from pathlib import Path
import re
import subprocess
import time

parser = argparse.ArgumentParser()
parser.add_argument('--apk', required=True, type=Path)
parser.add_argument('--avd', required=True)
parser.add_argument('--matrix-apk', required=True, type=Path)
args = parser.parse_args()
sdk = Path(os.environ['ANDROID_HOME'])
adb = str(sdk / 'platform-tools/adb')
emulator = str(sdk / 'emulator/emulator')
package = 'cool.gravitas.river'
component = package + '/.MainActivity'
output = Path(os.environ['RUNNER_TEMP']) / 'river-auth-return'
output.mkdir(parents=True, exist_ok=True)


def device(*arguments, check=True, timeout=30):
    return subprocess.run([adb, '-s', 'emulator-5554', *arguments], check=check,
                          capture_output=True, text=True, timeout=timeout).stdout


def resumed():
    page = device('shell', 'dumpsys', 'activity', 'activities')
    # Android reports this record more than once; the unique activity object ID
    # proves that a warm return reused the existing Flutter engine/activity.
    records = re.findall(r'(?:mResumedActivity|topResumedActivity)[:=]?\s*ActivityRecord\{([0-9a-f]+)\s+u\d+\s+cool\.gravitas\.river/\.MainActivity\b', page)
    return records[0] if records else None


def wait_resumed():
    for _ in range(40):
        activity = resumed()
        if activity:
            return activity
        time.sleep(.25)
    raise AssertionError('River did not become the resumed Android activity')


def open_link(kind):
    result = device('shell', 'am', 'start', '-W', '-a', 'android.intent.action.VIEW',
                    '-c', 'android.intent.category.BROWSABLE', '-d', 'river://auth/' + kind)
    assert 'Error:' not in result and 'Status: ok' in result, result
    return wait_resumed()


with (output / 'emulator.log').open('w') as log:
    process = subprocess.Popen([emulator, '-avd', args.avd, '-port', '5554',
                                '-no-window', '-no-audio', '-no-boot-anim',
                                '-no-snapshot', '-gpu', 'swiftshader',
                                '-camera-back', 'none', '-camera-front', 'none'],
                               stdout=log, stderr=subprocess.STDOUT)
    try:
        deadline = time.monotonic() + 240
        while time.monotonic() < deadline:
            assert process.poll() is None, 'Emulator exited before boot'
            try:
                if device('shell', 'getprop', 'sys.boot_completed', check=False, timeout=5).strip() == '1':
                    break
            except subprocess.TimeoutExpired:
                pass
            time.sleep(1)
        else:
            raise AssertionError('Android emulator boot timed out')
        device('shell', 'input', 'keyevent', '82')
        device('install', '-r', str(args.apk.resolve()), timeout=120)
        device('logcat', '-c')
        device('shell', 'am', 'start', '-W', '-n', component)
        original = wait_resumed()
        for kind in ['native', 'matrix']:
            device('shell', 'input', 'keyevent', '3')
            assert open_link(kind) == original, 'Warm return created a second River activity'
            print('ANDROID AUTH RETURN PASS warm ' + kind, flush=True)
        for kind in ['native', 'matrix']:
            device('shell', 'am', 'force-stop', package)
            assert open_link(kind) != original, 'Cold return reused a stopped activity'
            print('ANDROID AUTH RETURN PASS cold ' + kind, flush=True)
        pid = device('shell', 'pidof', package).strip()
        assert pid, 'River exited after the return link'
        logs = device('logcat', '-d', '--pid=' + pid)
        (output / 'river.log').write_text(logs)
        assert not any(message in logs for message in [
            'FATAL EXCEPTION', 'Could not navigate to initial route',
            'Failed to handle route',
        ]), 'River crashed or tried to navigate to an auth callback route'
        from android_matrix_fixture import Fixture, FIXTURE
        with Fixture() as fixture:
            device('shell', 'am', 'force-stop', package)
            # The verifier uses AndroidCAStore directly, rather than app XML
            # trust overrides. Install one CA only in this disposable emulator.
            device('root')
            device('wait-for-device')
            assert device('shell', 'id', '-u').strip() == '0'
            ca = FIXTURE / 'trusted-ca.pem'
            name = subprocess.check_output([
                'openssl', 'x509', '-in', str(ca), '-subject_hash_old', '-noout',
            ], text=True).strip() + '.0'
            # Android sets the per-user directory at app startup. Retain the
            # Conscrypt default location too for system/older runtime peers.
            for directory in ['/data/misc/user/0/cacerts-added', '/data/misc/keychain/cacerts-added']:
                device('shell', 'mkdir', '-p', directory)
                device('push', str(ca), directory + '/' + name)
                device('shell', 'chmod', '0755', directory)
                device('shell', 'chmod', '0644', directory + '/' + name)
                device('shell', 'chown', '-R', 'system:system', directory)
                device('shell', 'restorecon', '-RF', directory)
            device('install', '-r', str(args.matrix_apk.resolve()), timeout=120)
            device('shell', 'pm', 'clear', package)  # Disposable emulator only.
            for port in [8448, 8449]:
                device('reverse', f'tcp:{port}', f'tcp:{port}')
            for marker in ['RIVER_ANDROID_MATRIX_AUTH_SAVED', 'RIVER_ANDROID_MATRIX_AUTH_PASS']:
                device('logcat', '-c')
                device('shell', 'am', 'start', '-W', '-n', component)
                app_pid = device('shell', 'pidof', package).strip()
                assert app_pid, 'Matrix test app exited during startup'
                deadline = time.monotonic() + 150
                while time.monotonic() < deadline:
                    logs = device('logcat', '-d', '--pid=' + app_pid)
                    assert 'RIVER_ANDROID_MATRIX_AUTH_FAIL' not in logs, logs
                    assert 'FATAL EXCEPTION' not in logs, logs
                    if marker in logs:
                        break
                    time.sleep(.5)
                else:
                    raise AssertionError('Matrix Android authentication timed out: ' + logs)
                print('ANDROID MATRIX PASS ' + marker, flush=True)
                # A new process must recover secure credentials and the SQLite
                # device, without repeating the consumed browser login token.
                device('shell', 'am', 'force-stop', package)
            fixture.verify()
    except BaseException:
        log.flush()
        print('Android emulator diagnostics:', flush=True)
        print('\n'.join((output / 'emulator.log').read_text().splitlines()[-100:]), flush=True)
        try:
            print(device('shell', 'dumpsys', 'activity', 'activities', check=False), flush=True)
        except subprocess.TimeoutExpired:
            pass
        raise
    finally:
        device('emu', 'kill', check=False)
        try:
            process.wait(timeout=10)
        except subprocess.TimeoutExpired:
            process.kill()
            process.wait(timeout=10)
