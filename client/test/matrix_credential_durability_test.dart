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

final sessionKey =
    'river_matrix.session.${sha256.convert(utf8.encode('https://example.org|alice'))}';
Future<MatrixMessaging> restore(
  MemoryMatrixStorage storage,
  RotatingDevice device, {
  bool connected = true,
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
  expect(matrix.connected, connected);
  return matrix;
}

void main() {
  test(
    'failed initial restore sync keeps the rotated session for retry',
    () async {
      final storage = MemoryMatrixStorage();
      final device = RotatingDevice()..failSyncAfterRotation = true;
      final matrix = await restore(storage, device, connected: false);
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
