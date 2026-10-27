import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';
import 'package:flutter_test/flutter_test.dart';
import 'package:river/matrix_messaging.dart';

class MemoryMatrixStorage implements MatrixStorage {
  final values = <String, String>{};
  bool failSessionWrite = false, failDelete = false;
  Completer<void>? sessionWrite;
  @override
  Future<String?> read(String key) async => values[key];
  @override
  Future<void> write(String key, String value) async {
    if (key.contains('.session.')) {
      if (failSessionWrite) throw StateError('secure storage unavailable');
      await sessionWrite?.future;
    }
    values[key] = value;
  }

  @override
  Future<void> delete(String key) async {
    if (failDelete) throw StateError('secure storage unavailable');
    values.remove(key);
  }
}

class FakeMatrixTransport implements MatrixTransport {
  final closed = <bool>[];
  Completer<void>? loginGate;
  int sends = 0;
  @override
  Future<MatrixJson> login(String token) async {
    await loginGate?.future;
    return {};
  }

  @override
  Future<String> credentials() async => jsonEncode({
    'user_id': '@alice:example.org',
    'access_token': 'client-only',
  });
  @override
  Future<MatrixJson> sync() async => {'rooms': <MatrixJson>[], 'changed': []};
  @override
  Future<MatrixJson> rooms() => sync();
  @override
  Future<MatrixJson> history(String room, String? cursor) async => {
    'events': [],
    'next_cursor': null,
  };
  @override
  Future<MatrixJson> thread(String room, String event, String? cursor) async =>
      {'root': {}, 'events': []};
  @override
  Future<MatrixJson> members(String room) async => {'members': []};
  @override
  Future<MatrixJson> send(
    String room,
    String type,
    MatrixJson content,
    String txn,
  ) async {
    sends++;
    return {'event_id': r'$encrypted'};
  }

  final localValues = <String, MatrixJson>{};
  @override
  Future<MatrixJson> action(MatrixJson payload) async {
    final key = '${payload['scope']}:${payload['room']}:${payload['event']}';
    if (payload['action'] == 'local_read') return {'value': localValues[key]};
    if (payload['action'] == 'local_write') {
      if (payload['value'] == null) {
        localValues.remove(key);
      } else {
        localValues[key] =
            jsonDecode(jsonEncode(payload['value'])) as MatrixJson;
      }
    }
    return {};
  }

  @override
  Future<MatrixJson> sendAttachment(
    String room,
    String name,
    String mime,
    Uint8List bytes,
    String txn,
  ) async => {};
  @override
  Future<Uint8List> downloadAttachment(MatrixJson content) async =>
      Uint8List(0);
  @override
  Future<MatrixJson> security() async => {
    'devices': [],
    'requests': [],
    'device_id': 'RIVER',
  };
  @override
  Future<MatrixJson> setupRecovery(MatrixJson? authentication) async => {};
  @override
  Future<MatrixJson> recover(String key) async => {};
  @override
  Future<MatrixJson> requestVerification(String device) async => {};
  @override
  Future<MatrixJson> verificationAction(String flow, String action) async => {};
  @override
  Future<MatrixJson> verificationQr(String flow) async => {};
  @override
  Future<MatrixJson> scanVerificationImage(
    String flow,
    Uint8List bytes,
  ) async => {};
  @override
  Future<void> close(bool logout) async => closed.add(logout);
}

const matrixProfile = {
  'issuer': 'https://example.org',
  'sub': 'alice',
  'user_id': '@alice:example.org',
};

MatrixMessaging matrixHarness(
  MemoryMatrixStorage storage,
  FakeMatrixTransport engine, {
  List<MatrixJson>? requests,
}) => MatrixMessaging(
  storage: storage,
  factory: (_) async => engine,
  syncEnabled: false,
  launch: (_) async {},
  storeLocation: (name) async => name,
  changed: () {},
  request: (path, {method = 'GET', body}) async {
    requests?.add({'path': path, 'method': method, 'body': body});
    return path == '/api/matrix/link'
        ? {
            'id': 'flow',
            'url': 'https://river.example/matrix/link?id=flow',
            'expires_at': DateTime.now().millisecondsSinceEpoch ~/ 1000 + 300,
            'homeserver': 'https://example.org',
            'user_id': '@alice:example.org',
          }
        : {
            'login_token': 'one-use',
            'homeserver': 'https://example.org',
            'user_id': '@alice:example.org',
          };
  },
);

void main() {
  test(
    'SSO broker receives a challenge and verifier, never the device session',
    () async {
      final storage = MemoryMatrixStorage(),
          engine = FakeMatrixTransport(),
          requests = <MatrixJson>[];
      final matrix = matrixHarness(storage, engine, requests: requests);
      await matrix.bind(matrixProfile);
      await matrix.connect();
      expect(matrix.connected, true);
      expect(requests.map((r) => r['path']), [
        '/api/matrix/link',
        '/api/matrix/poll',
      ]);
      final link = requests.first['body'] as MatrixJson,
          poll = requests.last['body'] as MatrixJson;
      expect(link['challenge'], isNot(poll['verifier']));
      expect(link['challenge'], hasLength(43));
      expect(jsonEncode(requests), isNot(contains('client-only')));
      expect(storage.values.keys.single, contains('.session.'));
      final config = jsonDecode(storage.values.values.single) as Map;
      expect(config['store_key'], hasLength(43));
      expect(config['session'], contains('client-only'));
      await matrix.disconnect(logout: true);
      expect(engine.closed, [true]);
      expect(storage.values, isEmpty);
      matrix.dispose();
    },
  );

  test(
    'secure storage failure revokes an unpersisted device and never exposes it',
    () async {
      final storage = MemoryMatrixStorage()..failSessionWrite = true;
      final engine = FakeMatrixTransport();
      final matrix = matrixHarness(storage, engine);
      await matrix.bind(matrixProfile);
      await matrix.connect();
      expect(matrix.connected, false);
      expect(matrix.error, isNotNull);
      expect(engine.closed, [true]);
      expect(
        storage.values.keys.where((key) => key.contains('.session.')),
        isEmpty,
      );
      matrix.dispose();
    },
  );

  test(
    'account switch during login cannot publish or persist the previous account',
    () async {
      final storage = MemoryMatrixStorage(),
          engine = FakeMatrixTransport()..loginGate = Completer<void>();
      final matrix = matrixHarness(storage, engine);
      await matrix.bind(matrixProfile);
      final connecting = matrix.connect();
      await Future<void>.delayed(Duration.zero);
      await matrix.bind({
        ...matrixProfile,
        'sub': 'bob',
        'user_id': '@bob:example.org',
      });
      engine.loginGate!.complete();
      await connecting;
      expect(matrix.userId, '@bob:example.org');
      expect(matrix.connected, false);
      expect(engine.closed, [true]);
      expect(
        storage.values.keys.where((key) => key.contains('.session.')),
        isEmpty,
      );
      matrix.dispose();
    },
  );

  test(
    'logout waits for in-flight credential writes then deletes them',
    () async {
      final storage = MemoryMatrixStorage()..sessionWrite = Completer<void>();
      final engine = FakeMatrixTransport(),
          matrix = matrixHarness(storage, FakeMatrixTransport());
      matrix.dispose();
      final active = matrixHarness(storage, engine);
      await active.bind(matrixProfile);
      final connecting = active.connect();
      await Future<void>.delayed(Duration.zero);
      final logout = active.disconnect(logout: true);
      storage.sessionWrite!.complete();
      await Future.wait([connecting, logout]);
      expect(storage.values, isEmpty);
      expect(active.connected, false);
      expect(engine.closed, [true]);
      active.dispose();
    },
  );

  test(
    'failed secure deletion still closes and revokes the live device',
    () async {
      final storage = MemoryMatrixStorage(), engine = FakeMatrixTransport();
      final matrix = matrixHarness(storage, engine);
      await matrix.bind(matrixProfile);
      await matrix.connect();
      storage.failDelete = true;
      await expectLater(matrix.disconnect(logout: true), throwsStateError);
      expect(matrix.connected, false);
      expect(engine.closed, [true]);
      matrix.dispose();
    },
  );

  test(
    'restoration rejects a mismatched Matrix user before opening the SDK',
    () async {
      final storage = MemoryMatrixStorage(), engine = FakeMatrixTransport();
      final matrix = matrixHarness(storage, engine);
      await matrix.bind(matrixProfile);
      await matrix.connect();
      await matrix.disconnect();
      final key = storage.values.keys.single;
      final config = jsonDecode(storage.values[key]!) as Map<String, dynamic>;
      config['user_id'] = '@mallory:example.org';
      storage.values[key] = jsonEncode(config);
      var opened = false;
      final restore = MatrixMessaging(
        request: (_, {method = 'GET', body}) async => {},
        changed: () {},
        storage: storage,
        factory: (_) async {
          opened = true;
          return engine;
        },
        syncEnabled: false,
      );
      await restore.bind(matrixProfile);
      expect(opened, false);
      expect(restore.connected, false);
      expect(restore.error, isNotNull);
      restore.dispose();
      matrix.dispose();
    },
  );
}
