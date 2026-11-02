import 'dart:async';
import 'dart:convert';
import 'package:crypto/crypto.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:river/api.dart';
import 'package:river/store_notifications.dart';
import 'matrix_api_test.dart' show RoomTransport;
import 'matrix_messaging_test.dart' show MemoryMatrixStorage;

class SwitchingNotificationsApi extends RiverApi {
  SwitchingNotificationsApi() : super(live: false, matrixEnabled: false);
  final firstRefresh = Completer<void>();
  int refreshes = 0;
  @override
  Future<void> refresh() async {
    if (++refreshes == 1) await firstRefresh.future;
  }

  @override
  Future<void> open(String? id) async => selected = id;
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  test(
    'switching bubbles ignores a delayed earlier conversation open',
    () async {
      final api = SwitchingNotificationsApi()
        ..user = {'issuer': 'https://gravitas.cool', 'sub': 'alice'}
        ..groups = [
          for (final id in ['first', 'second'])
            {'id': id, 'room_id': '!$id:remote', 'membership': 'join'},
        ];
      try {
        final first = api.openStoreNotification({
          'subject': 'alice',
          'room_id': '!first:remote',
        });
        await api.openStoreNotification({
          'subject': 'alice',
          'room_id': '!second:remote',
        });
        expect(api.selected, 'second');
        api.firstRefresh.complete();
        await first;
        expect(api.selected, 'second');
      } finally {
        api.dispose();
      }
    },
  );
  test(
    'Android binds notifications to the validated account and clears before logout',
    () async {
      debugDefaultTargetPlatformOverride = TargetPlatform.android;
      final calls = <MethodCall>[];
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(StoreNotifications.channel, (call) async {
            calls.add(call);
            return call.method == 'clear'
                ? null
                : {'enabled': true, 'storeInstalled': true};
          });
      final api = RiverApi(live: false, matrixEnabled: false);
      try {
        api.user = {'issuer': 'https://gravitas.cool', 'sub': 'alice'};
        await api.refreshStoreNotifications();
        expect(calls.single.method, 'bind');
        expect(calls.single.arguments, {
          'issuer': 'https://gravitas.cool',
          'subject': 'alice',
        });
        expect(api.storeNotificationsEnabled, isTrue);
        await api.enableStoreNotifications(false);
        expect(calls.last.arguments, {'enabled': false});
        // Intercept secure storage so this test has no platform credential store.
        const storage = MethodChannel(
          'plugins.it_nomads.com/flutter_secure_storage',
        );
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
            .setMockMethodCallHandler(storage, (_) async => null);
        await api.logout();
        expect(calls.where((c) => c.method == 'clear'), isNotEmpty);
        expect(api.user, isNull);
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
            .setMockMethodCallHandler(storage, null);
      } finally {
        api.dispose();
        debugDefaultTargetPlatformOverride = null;
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
            .setMockMethodCallHandler(StoreNotifications.channel, null);
      }
    },
  );

  test(
    'notification taps open only the current account and a joined conversation',
    () async {
      final profile = {
        'issuer': 'https://gravitas.cool',
        'sub': 'alice',
        'user_id': '@alice:gravitas.cool',
      };
      final storage = MemoryMatrixStorage();
      final namespace = sha256.convert(
        utf8.encode('https://gravitas.cool|alice'),
      );
      storage.values['river_matrix.session.$namespace'] = jsonEncode({
        'user_id': profile['user_id'],
        'homeserver': profile['issuer'],
        'store': 'test',
        'store_key': 'x' * 43,
        'session': '{}',
      });
      final engine = RoomTransport();
      var reads = 0;
      final api = RiverApi(
        live: false,
        matrixEnabled: true,
        matrixStorage: storage,
        matrixFactory: (_) async => engine,
        client: MockClient((request) async {
          reads++;
          return http.Response(
            request.url.path == '/api/overview'
                ? '{"groups":[],"recent":[]}'
                : '{"friends":[],"requests":[],"blocked":[]}',
            200,
          );
        }),
      );
      try {
        api.user = profile;
        await api.matrix.bind(profile);
        await api.openStoreNotification({
          'subject': 'bob',
          'room_id': '!room:remote',
        });
        expect(reads, 0);
        expect(api.selected, isNull);
        await api.openStoreNotification({
          'subject': 'alice',
          'room_id': '!unknown:remote',
        });
        expect(api.selected, isNull);
        await api.openStoreNotification({
          'subject': 'alice',
          'room_id': '!room:remote',
        });
        expect(api.selected, '!room:remote');
      } finally {
        api.dispose();
      }
    },
  );
}
