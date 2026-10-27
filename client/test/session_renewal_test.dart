import 'dart:async';
import 'dart:convert';
import 'package:crypto/crypto.dart';

import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:river/api.dart';
import 'package:river/matrix_messaging.dart';

import 'matrix_messaging_test.dart'
    show MemoryMatrixStorage, FakeMatrixTransport, matrixProfile;

class RestoredTransport extends FakeMatrixTransport {
  @override
  Future<String> credentials() async => 'rotated-matrix-credentials';
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  test(
    'restored device saves credentials rotated by its initial sync before returning',
    () async {
      final storage = MemoryMatrixStorage();
      final namespace = sha256.convert(
        utf8.encode('https://example.org|alice'),
      );
      final key = 'river_matrix.session.$namespace';
      storage.values[key] = jsonEncode({
        'homeserver': 'https://example.org',
        'user_id': '@alice:example.org',
        'store': 'same-store',
        'store_key': 'same-private-key',
        'session': 'old-matrix-credentials',
      });
      final engine = RestoredTransport();
      final matrix = MatrixMessaging(
        request: (_, {method = 'GET', body}) async => {},
        storage: storage,
        factory: (_) async => engine,
        syncEnabled: false,
        changed: () {},
      );
      await matrix.bind(matrixProfile);
      expect(matrix.connected, isTrue);
      final saved = jsonDecode(storage.values[key]!) as Map;
      expect(saved['session'], 'rotated-matrix-credentials');
      expect(saved['store'], 'same-store');
      expect(saved['store_key'], 'same-private-key');
      matrix.dispose();
    },
  );
  setUp(
    () => FlutterSecureStorage.setMockInitialValues({
      'river_session': 'expired-envelope',
    }),
  );

  test(
    'concurrent expired requests renew once, persist, and preserve the linked device',
    () async {
      final matrixStorage = MemoryMatrixStorage();
      final namespace = sha256.convert(
        utf8.encode('https://example.org|alice'),
      );
      matrixStorage.values['river_matrix.session.$namespace'] = jsonEncode({
        'homeserver': 'https://example.org',
        'user_id': '@alice:example.org',
        'store': 'same-store',
        'store_key': 'same-key',
        'session': 'saved-device',
      });
      final engine = FakeMatrixTransport();
      final gate = Completer<void>();
      var renewals = 0;
      final api = RiverApi(
        live: false,
        matrixEnabled: true,
        matrixStorage: matrixStorage,
        matrixFactory: (_) async => engine,
        client: MockClient((r) async {
          if (r.url.path == '/api/session/refresh') {
            renewals++;
            await gate.future;
            return http.Response('{"session":"renewed-envelope"}', 200);
          }
          if (r.headers['Authorization'] != 'Bearer renewed-envelope') {
            return http.Response('{"error":"login required"}', 401);
          }
          return http.Response('{"ok":true}', 200);
        }),
      );
      api.token = 'expired-envelope';
      api.user = Map.of(matrixProfile);
      await api.matrix.bind(matrixProfile);
      expect(api.matrixConnected, isTrue);
      final reads = [api.request('/api/one'), api.request('/api/two')];
      await Future<void>.delayed(Duration.zero);
      expect(renewals, 1);
      gate.complete();
      expect(await Future.wait(reads), [
        {'ok': true},
        {'ok': true},
      ]);
      expect(api.user, matrixProfile);
      expect(api.matrixConnected, isTrue);
      expect(api.token, 'renewed-envelope');
      expect(await api.storage.read(key: 'river_session'), 'renewed-envelope');
      expect(engine.closed, isEmpty);
      api.dispose();
    },
  );

  test(
    'temporary refresh outage retains login and can retry after network recovery',
    () async {
      var offline = true;
      final api = RiverApi(
        live: false,
        client: MockClient((r) async {
          if (r.url.path == '/api/session/refresh') {
            return http.Response(
              offline ? '{"error":"unavailable"}' : '{"session":"renewed"}',
              offline ? 503 : 200,
            );
          }
          return http.Response(
            r.headers['Authorization'] == 'Bearer renewed'
                ? '{}'
                : '{"error":"expired"}',
            r.headers['Authorization'] == 'Bearer renewed' ? 200 : 401,
          );
        }),
      );
      api.token = 'expired-envelope';
      api.user = Map.of(matrixProfile);
      await expectLater(
        api.request('/api/session'),
        throwsA(isA<ApiException>().having((e) => e.status, 'status', 503)),
      );
      expect(api.user, matrixProfile);
      expect(api.token, 'expired-envelope');
      expect(await api.storage.read(key: 'river_session'), 'expired-envelope');
      offline = false;
      await api.request('/api/session');
      expect(api.token, 'renewed');
      api.dispose();
    },
  );

  test(
    'central revocation clears login without deleting Matrix device credentials',
    () async {
      final storage = MemoryMatrixStorage()
        ..values['river_matrix.session.saved'] = 'private keys';
      final api = RiverApi(
        live: false,
        matrixStorage: storage,
        client: MockClient(
          (_) async => http.Response('{"error":"revoked"}', 401),
        ),
      );
      api.user = Map.of(matrixProfile);
      api.token = 'expired-envelope';
      await expectLater(
        api.request('/api/session'),
        throwsA(isA<ApiException>().having((e) => e.status, 'status', 401)),
      );
      expect(api.user, isNull);
      expect(api.token, isNull);
      expect(storage.values['river_matrix.session.saved'], 'private keys');
      await Future<void>.delayed(Duration.zero);
      expect(await api.storage.read(key: 'river_session'), isNull);
      api.dispose();
    },
  );

  test(
    'logout during renewal cannot restore credentials or overwrite deletion',
    () async {
      final gate = Completer<void>();
      final api = RiverApi(
        live: false,
        client: MockClient((r) async {
          if (r.url.path == '/api/session/refresh') {
            await gate.future;
            return http.Response('{"session":"late-renewal"}', 200);
          }
          return http.Response('{"error":"expired"}', 401);
        }),
      );
      api.user = Map.of(matrixProfile);
      api.token = 'expired-envelope';
      final pending = expectLater(
        api.request('/api/session'),
        throwsA(
          isA<ApiException>().having((e) => e.code, 'code', 'session_changed'),
        ),
      );
      await Future<void>.delayed(Duration.zero);
      await api.logout();
      gate.complete();
      await pending;
      expect(api.token, isNull);
      expect(await api.storage.read(key: 'river_session'), isNull);
      api.dispose();
    },
  );

  test(
    'boot after process restart automatically renews saved credentials',
    () async {
      final api = RiverApi(
        live: false,
        client: MockClient((r) async {
          if (r.url.path == '/auth/gravitas/config') {
            return http.Response('{"defaultDomain":"example.org"}', 200);
          }
          if (r.url.path == '/api/session/refresh') {
            return http.Response('{"session":"renewed-on-boot"}', 200);
          }
          if (r.headers['Authorization'] != 'Bearer renewed-on-boot') {
            return http.Response('{"error":"expired"}', 401);
          }
          if (r.url.path == '/api/session') {
            return http.Response(jsonEncode({'user': matrixProfile}), 200);
          }
          if (r.url.path == '/api/overview') {
            return http.Response('{"groups":[],"recent":[]}', 200);
          }
          return http.Response(
            '{"friends":[],"requests":[],"blocked":[]}',
            200,
          );
        }),
      );
      await api.boot();
      expect(api.user, matrixProfile);
      expect(api.token, 'renewed-on-boot');
      expect(await api.storage.read(key: 'river_session'), 'renewed-on-boot');
      api.dispose();
    },
  );
}
