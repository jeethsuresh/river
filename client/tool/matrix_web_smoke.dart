// Test-only browser entry point; the production build targets lib/main.dart.
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
    result.textContent = 'RIVER_MATRIX_BROWSER_PASS';
  } catch (e) {
    result.textContent = 'RIVER_MATRIX_BROWSER_FAIL: $e';
  }
}
