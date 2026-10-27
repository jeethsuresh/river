import 'dart:async';
import 'dart:convert';
import 'package:crypto/crypto.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:river/matrix_messaging.dart';
import 'matrix_messaging_test.dart'
    show FakeMatrixTransport, MemoryMatrixStorage, matrixProfile, matrixHarness;

class RotatingDevice extends FakeMatrixTransport {
  String session = 'original-device-session';
  Completer<void>? pendingSync;
  Completer<void>? pendingCredentials;
  bool failOperation = false;
  bool failSyncAfterRotation = false;
  @override
  Future<String> credentials() async {
    final snapshot = session, pending = pendingCredentials;
    pendingCredentials = null;
    await pending?.future;
    return snapshot;
  }

  @override
  Future<MatrixJson> sync() async {
    await pendingSync?.future;
    if (failSyncAfterRotation) {
      session = 'rotated-before-sync-failure';
      throw StateError('sync response failed after rotation');
    }
    return {'rooms': <MatrixJson>[], 'changed': []};
  }

  @override
  Future<MatrixJson> rooms() async => {'rooms': <MatrixJson>[]};
  @override
  Future<MatrixJson> action(MatrixJson payload) async {
    session = 'rotated-during-${payload['action']}';
    if (failOperation) throw StateError('request failed after token refresh');
    return {};
  }

  @override
  Future<MatrixJson> send(
    String room,
    String type,
    MatrixJson content,
    String txn,
  ) => action({'action': 'send'});
  @override
  Future<MatrixJson> history(String room, String? cursor) =>
      action({'action': 'history'});
}

class FailingSessionStorage extends MemoryMatrixStorage {
  int sessionWrites = 0;
  int? failAt;
  @override
  Future<void> write(String key, String value) async {
    if (key.contains('.session.') && ++sessionWrites == failAt) {
      throw StateError('storage temporarily unavailable');
    }
    await super.write(key, value);
  }
}

final sessionKey =
    'river_matrix.session.${sha256.convert(utf8.encode('https://example.org|alice'))}';
Future<MatrixMessaging> restore(
  MemoryMatrixStorage storage,
  RotatingDevice device, {
  bool failedFirstSync = false,
}) async {
  storage.values.putIfAbsent(
    sessionKey,
    () => jsonEncode({
      'homeserver': matrixProfile['issuer'],
      'user_id': matrixProfile['user_id'],
      'store': 'same-private-store',
      'store_key': 'same-private-key',
      'session': device.session,
    }),
  );
  final matrix = MatrixMessaging(
    request: (_, {method = 'GET', body}) async =>
        throw StateError('SSO must not be needed'),
    changed: () {},
    storage: storage,
    factory: (config) async {
      device.session = config['session'] as String;
      return device;
    },
    syncEnabled: false,
  );
  await matrix.bind(matrixProfile);
  if (failedFirstSync) {
    // Restore now publishes local state before starting the remote poll. Exercise
    // that first poll explicitly, then simulate the device being reopened.
    await expectLater(matrix.syncNow(), throwsStateError);
  }
  expect(matrix.connected, true);
  return matrix;
}

void main() {
  test(
    'restoring a local device does not wait for its first remote poll',
    () async {
      final storage = MemoryMatrixStorage();
      final device = RotatingDevice()..pendingSync = Completer<void>();
      storage.values[sessionKey] = jsonEncode({
        'homeserver': matrixProfile['issuer'],
        'user_id': matrixProfile['user_id'],
        'store': 'same-private-store',
        'store_key': 'same-private-key',
        'session': device.session,
      });
      final matrix = MatrixMessaging(
        request: (_, {method = 'GET', body}) async => {},
        changed: () {},
        storage: storage,
        factory: (_) async => device,
      );
      await matrix.bind(matrixProfile).timeout(const Duration(seconds: 1));
      expect(matrix.connected, true);
      expect(device.pendingSync!.isCompleted, false);
      matrix.dispose();
      device.pendingSync!.complete();
      await Future<void>.delayed(Duration.zero);
    },
  );

  for (final phase in ['restore', 'link']) {
    test(
      '$phase retries a rotated first sync after storage recovers',
      () async {
        final storage = FailingSessionStorage()
          ..failAt = phase == 'restore' ? 1 : 2;
        final device = RotatingDevice()..failSyncAfterRotation = true;
        String? restoredSession;
        if (phase == 'restore') {
          storage.values[sessionKey] = jsonEncode({
            'homeserver': matrixProfile['issuer'],
            'user_id': matrixProfile['user_id'],
            'store': 'same-private-store',
            'store_key': 'same-private-key',
            'session': device.session,
          });
        }
        final matrix = MatrixMessaging(
          request: (path, {method = 'GET', body}) async =>
              path == '/api/matrix/link'
              ? {
                  'id': 'flow',
                  'url': 'https://river.example/link',
                  'expires_at':
                      DateTime.now().millisecondsSinceEpoch ~/ 1000 + 300,
                  'homeserver': matrixProfile['issuer'],
                  'user_id': matrixProfile['user_id'],
                }
              : {
                  'login_token': 'one-use',
                  'homeserver': matrixProfile['issuer'],
                  'user_id': matrixProfile['user_id'],
                },
          changed: () {},
          storage: storage,
          factory: (config) async {
            if (config['session'] is String) {
              device.session = restoredSession = config['session'] as String;
            }
            return device;
          },
          syncEnabled: false,
          launch: (_) async {},
          storeLocation: (name) async => name,
        );
        await matrix.bind(matrixProfile);
        if (phase == 'link') {
          await matrix.connect();
        } else {
          expect(matrix.connected, true);
          await expectLater(matrix.syncNow(), throwsStateError);
          await matrix.disconnect();
        }
        expect(matrix.connected, false);
        final original = (jsonDecode(storage.values[sessionKey]!) as Map);
        expect(original['session'], 'original-device-session');
        storage.failAt = null;
        device.failSyncAfterRotation = false;
        await matrix.bind(matrixProfile);
        expect(matrix.connected, true);
        expect(restoredSession, 'rotated-before-sync-failure');
        final saved = (jsonDecode(storage.values[sessionKey]!) as Map);
        expect(saved['session'], 'rotated-before-sync-failure');
        expect(saved['store'], original['store']);
        expect(saved['store_key'], original['store_key']);
        matrix.dispose();
      },
    );
  }

  test('connect does not replace an already connected device', () async {
    final storage = MemoryMatrixStorage(), device = RotatingDevice();
    final matrix = await restore(storage, device);
    final original = storage.values[sessionKey];
    await matrix.connect();
    expect(matrix.connected, true);
    expect(matrix.error, isNull);
    expect(device.closed, isEmpty);
    expect(storage.values[sessionKey], original);
    matrix.dispose();
  });

  test(
    'logout discards an unsaved rotated session before a later bind',
    () async {
      final storage = FailingSessionStorage()..failAt = 1;
      final device = RotatingDevice()..failSyncAfterRotation = true;
      final matrix = await restore(storage, device, failedFirstSync: true);
      storage.failAt = null;
      await matrix.disconnect(logout: true);
      await matrix.bind(matrixProfile);
      expect(matrix.connected, false);
      expect(storage.values[sessionKey], isNull);
      matrix.dispose();
    },
  );

  test(
    'failed initial restore sync keeps the rotated session for retry',
    () async {
      final storage = MemoryMatrixStorage();
      final device = RotatingDevice()..failSyncAfterRotation = true;
      final matrix = await restore(storage, device, failedFirstSync: true);
      expect(
        (jsonDecode(storage.values[sessionKey]!) as Map)['session'],
        'rotated-before-sync-failure',
      );
      final nextDevice = RotatingDevice();
      final next = await restore(storage, nextDevice);
      expect(nextDevice.session, 'rotated-before-sync-failure');
      next.dispose();
      matrix.dispose();
    },
  );

  test(
    'failed first-link sync keeps the persisted device and its rotated token',
    () async {
      final storage = MemoryMatrixStorage();
      final device = RotatingDevice()..failSyncAfterRotation = true;
      final matrix = matrixHarness(storage, device);
      await matrix.bind(matrixProfile);
      await matrix.connect();
      expect(matrix.connected, false);
      expect(device.closed, [false]);
      expect(
        (jsonDecode(storage.values[sessionKey]!) as Map)['session'],
        'rotated-before-sync-failure',
      );
      final nextDevice = RotatingDevice();
      final next = await restore(storage, nextDevice);
      expect(nextDevice.session, 'rotated-before-sync-failure');
      next.dispose();
      matrix.dispose();
    },
  );
  for (final operation in ['send', 'history', 'read']) {
    test(
      '$operation saves rotated credentials while a sync is still pending',
      () async {
        final storage = MemoryMatrixStorage(), device = RotatingDevice();
        final matrix = await restore(storage, device);
        device.pendingSync = Completer<void>();
        final sync = matrix.syncNow();
        await Future<void>.delayed(Duration.zero);
        switch (operation) {
          case 'send':
            await matrix.transport.send('!room:test', 'm.room.message', {
              'body': 'hello',
            }, 'txn');
          case 'history':
            await matrix.transport.history('!room:test', null);
          default:
            await matrix.transport.action({'action': operation});
        }
        expect(
          (jsonDecode(storage.values[sessionKey]!) as Map)['session'],
          'rotated-during-$operation',
        );
        device.pendingSync!.complete();
        await sync;
        await matrix.disconnect();
        final restarted = RotatingDevice();
        final next = await restore(storage, restarted);
        expect(restarted.session, 'rotated-during-$operation');
        expect(
          (jsonDecode(storage.values[sessionKey]!) as Map)['store'],
          'same-private-store',
        );
        next.dispose();
        matrix.dispose();
      },
    );
  }

  test(
    'failed requests still save credentials rotated before their error',
    () async {
      final storage = MemoryMatrixStorage(), device = RotatingDevice();
      final matrix = await restore(storage, device);
      device.failOperation = true;
      await expectLater(
        matrix.transport.history('!room:test', null),
        throwsStateError,
      );
      expect(
        (jsonDecode(storage.values[sessionKey]!) as Map)['session'],
        'rotated-during-history',
      );
      matrix.dispose();
    },
  );

  test(
    'a storage failure stays retryable without another token rotation',
    () async {
      final storage = MemoryMatrixStorage(), device = RotatingDevice();
      final matrix = await restore(storage, device);
      storage.failSessionWrite = true;
      await expectLater(
        matrix.transport.action({'action': 'read'}),
        throwsStateError,
      );
      expect(
        (jsonDecode(storage.values[sessionKey]!) as Map)['session'],
        'original-device-session',
      );
      storage.failSessionWrite = false;
      await matrix.transport.rooms();
      expect(
        (jsonDecode(storage.values[sessionKey]!) as Map)['session'],
        'rotated-during-read',
      );
      matrix.dispose();
    },
  );

  test(
    'concurrent operations cannot overwrite a newer token with a delayed read',
    () async {
      final storage = MemoryMatrixStorage(), device = RotatingDevice();
      final matrix = await restore(storage, device);
      final gate = Completer<void>();
      device.pendingCredentials = gate;
      final read = matrix.transport.action({'action': 'read'});
      await Future<void>.delayed(Duration.zero);
      final send = matrix.transport.action({'action': 'send'});
      await Future<void>.delayed(Duration.zero);
      gate.complete();
      await Future.wait([read, send]);
      expect(
        (jsonDecode(storage.values[sessionKey]!) as Map)['session'],
        'rotated-during-send',
      );
      matrix.dispose();
    },
  );

  test(
    'logout waits for operation credential writes and removes the result',
    () async {
      final storage = MemoryMatrixStorage(), device = RotatingDevice();
      final matrix = await restore(storage, device);
      storage.sessionWrite = Completer<void>();
      final send = matrix.transport.action({'action': 'send'});
      final rejected = expectLater(send, throwsStateError);
      await Future<void>.delayed(Duration.zero);
      final logout = matrix.disconnect(logout: true);
      storage.sessionWrite!.complete();
      await logout;
      await rejected;
      expect(storage.values, isEmpty);
      expect(device.closed.last, true);
      matrix.dispose();
    },
  );
}
