// Test-only browser entry point; the production build targets lib/main.dart.
import 'dart:convert';
import 'package:river_matrix/river_matrix.dart';
import 'package:web/web.dart' as web;

Future<void> main() async {
  final result = web.document.createElement('pre')..id = 'matrix-smoke';
  web.document.body!.append(result);
  try {
    await RustLib.init();
    try {
      await MatrixConnection.open(
        homeserver: 'http://invalid.example',
        expectedUser: '@alice:example.org',
        store: 'test',
        storeKey: 'x' * 43,
      );
      throw StateError('Insecure homeserver was accepted');
    } catch (e) {
      if (!'$e'.contains('Invalid Matrix homeserver')) rethrow;
    }
    // A mismatched restored account must fail before opening a store/network.
    try {
      await MatrixConnection.open(
        homeserver: 'https://example.org',
        expectedUser: '@alice:example.org',
        store: 'test',
        storeKey: 'x' * 43,
        session:
            '{"user_id":"@mallory:example.org","device_id":"X","access_token":"test"}',
      );
      throw StateError('Mismatched account was accepted');
    } catch (e) {
      if (!'$e'.contains('Matrix session belongs to another account')) rethrow;
    }
    final previous = web.window.sessionStorage.getItem(
      'river.offline.test.store',
    );
    final name =
        previous ??
        'river-offline-smoke-${DateTime.now().microsecondsSinceEpoch}';
    web.window.sessionStorage.setItem('river.offline.test.store', name);
    const session =
        '{"user_id":"@alice:offline.invalid","device_id":"OFFLINE","access_token":"test-only"}';
    Future<MatrixConnection> open() => MatrixConnection.open(
      homeserver: 'https://offline.invalid',
      expectedUser: '@alice:offline.invalid',
      store: name,
      storeKey: 'x' * 43,
      session: session,
    );
    var engine = await open();
    if (previous != null) {
      final restored =
          jsonDecode(
                await engine.action(
                  payload: jsonEncode({
                    'action': 'local_read',
                    'scope': 'overview',
                  }),
                ),
              )
              as Map;
      if (restored['value']?['draft'] != 'offline browser draft') {
        throw StateError(
          'The browser reload lost its existing IndexedDB draft',
        );
      }
    }
    await engine.action(
      payload: jsonEncode({
        'action': 'local_write',
        'scope': 'overview',
        'value': {
          'rooms': ['!cached:offline.invalid'],
          'draft': 'offline browser draft',
          'history': ['saved message'],
        },
      }),
    );
    await engine.close(logout: false);
    engine.dispose();
    engine = await open();
    final cached =
        jsonDecode(
              await engine.action(
                payload: jsonEncode({
                  'action': 'local_read',
                  'scope': 'overview',
                }),
              ),
            )
            as Map;
    if (cached['value']['draft'] != 'offline browser draft' ||
        cached['value']['history'][0] != 'saved message') {
      throw StateError('IndexedDB records did not survive an offline reopen');
    }
    await engine.close(logout: false);
    engine.dispose();
    result.textContent = 'RIVER_MATRIX_BROWSER_PASS';
  } catch (e) {
    result.textContent = 'RIVER_MATRIX_BROWSER_FAIL: $e';
  }
}
