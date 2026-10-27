// CI-only entry point. Release builds always target lib/main.dart.
import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:river/matrix_messaging.dart';
import 'package:river/matrix_store_location.dart';
import 'package:path_provider/path_provider.dart';

const profile = {
  'issuer': 'https://localhost:8448',
  'sub': 'android-fixture',
  'user_id': '@alice:localhost:8448',
};

MatrixMessaging controller({bool restoring = false}) => MatrixMessaging(
  request: (path, {method = 'GET', body}) async {
    if (restoring) throw StateError('Restore must not request browser sign-in');
    if (path == '/api/matrix/link') {
      return {
        'id': 'android-fixture',
        'url': 'https://localhost:8448/approved',
        'expires_at': DateTime.now().millisecondsSinceEpoch ~/ 1000 + 300,
        'homeserver': profile['issuer'],
        'user_id': profile['user_id'],
      };
    }
    return {
      'login_token': 'android-fixture-one-use-token',
      'homeserver': profile['issuer'],
      'user_id': profile['user_id'],
    };
  },
  // The separate warm/cold return tests exercise the Android browser intent.
  launch: (_) async {},
  changed: () {},
  syncEnabled: false,
);

void check(bool result, String message) {
  if (!result) throw StateError(message);
}

Future<void> rejectedCertificate(String homeserver) async {
  MatrixTransport? device;
  var rejected = false;
  try {
    device = await RustMatrixTransport.open({
      'homeserver': homeserver,
      'user_id': profile['user_id'],
      'store': await matrixStoreLocation(
        'rejected-${Uri.parse(homeserver).port}',
      ),
      'store_key': 'isolated-android-rejection-store-key-00000000',
    });
    await device.login('must-not-arrive-over-invalid-tls');
  } catch (error) {
    final message = '$error';
    check(
      message.contains('certificate') ||
          message.contains('TLS') ||
          message.contains('tls') ||
          message.contains('error sending request'),
      'Expected a TLS rejection, received $message',
    );
    rejected = true;
  } finally {
    await device?.close(false);
  }
  check(rejected, 'Invalid TLS certificate was accepted');
}

Future<void> run() async {
  final support = await getApplicationSupportDirectory();
  final marker = File('${support.path}/android-matrix-test-device');
  if (!await marker.exists()) {
    final first = controller();
    await first.bind(profile);
    await first.connect();
    check(
      first.connected,
      'Matrix approval/login/first sync failed: ${first.error}',
    );
    final original = jsonDecode(await first.transport.credentials()) as Map;
    check(original['device_id'] == 'ANDROID-FIXTURE', 'Wrong Matrix device');
    await marker.writeAsString(original['device_id'] as String, flush: true);
    await first.disconnect();
    first.dispose();
    debugPrint('RIVER_ANDROID_MATRIX_AUTH_SAVED');
    return;
  }

  final restored = controller(restoring: true);
  await restored.bind(profile);
  check(
    restored.connected,
    'Encrypted SQLite/secure credential restore failed',
  );
  final reopened = jsonDecode(await restored.transport.credentials()) as Map;
  check(
    reopened['device_id'] == await marker.readAsString(),
    'Restore replaced device',
  );
  await restored.syncNow();
  await restored.disconnect(logout: true);
  restored.dispose();

  // Check both certificate trust and host identity; no TLS bypass is permitted.
  await rejectedCertificate('https://localhost:8449');
  await rejectedCertificate('https://127.0.0.1:8448');
  await marker.delete();
  debugPrint('RIVER_ANDROID_MATRIX_AUTH_PASS');
}

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  runApp(
    const MaterialApp(home: Scaffold(body: Text('Matrix Android auth test'))),
  );
  try {
    await run();
  } catch (error, stack) {
    debugPrint('RIVER_ANDROID_MATRIX_AUTH_FAIL: $error\n$stack');
  }
}
