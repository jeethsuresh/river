import 'dart:async';
import 'dart:convert';
import 'package:crypto/crypto.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:river/api.dart';
import 'package:river/matrix_messaging.dart';
import 'package:river/notification_runtime.dart';
import 'matrix_messaging_test.dart'
    show FakeMatrixTransport, MemoryMatrixStorage;

class PreviewTransport extends FakeMatrixTransport {
  int actions = 0, roomReads = 0;
  bool fail = false;
  Completer<void>? gate;
  bool needsKey = false;
  int syncs = 0;
  void Function()? onSync;
  @override
  Future<MatrixJson> sync() async {
    syncs++;
    onSync?.call();
    return super.sync();
  }

  @override
  Future<MatrixJson> rooms() async {
    roomReads++;
    return {'rooms': <MatrixJson>[]};
  }

  @override
  Future<MatrixJson> action(MatrixJson payload) async {
    expect(payload, {
      'action': 'notification',
      'room': '!room:remote',
      'event': r'$event',
    });
    actions++;
    await gate?.future;
    if (needsKey && syncs == 0) return {'needs_sync': true};
    if (fail) throw StateError('offline after token rotation');
    return {'title': 'Friends', 'sender': 'Bob', 'body': 'Hello 🌊🔐'};
  }

  @override
  Future<String> credentials() async =>
      '{"access_token":"rotated-access","refresh_token":"rotated-refresh"}';
}

class RuntimeApi extends RiverApi {
  RuntimeApi() : super(live: false);
  final gate = Completer<void>();
  final trace = <String>[];
  @override
  Future<Json> notificationPreview(Json ticket, {bool restore = false}) async {
    trace.add('preview:$restore');
    await gate.future;
    return {};
  }

  @override
  Future<void> boot() async {
    trace.add('boot');
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const profile = {
    'issuer': 'https://gravitas.cool',
    'sub': 'alice',
    'user_id': '@alice:gravitas.cool',
  };
  const ticket = {
    'subject': 'alice',
    'room_id': '!room:remote',
    'event_id': r'$event',
  };
  final namespace = sha256.convert(utf8.encode('https://gravitas.cool|alice'));
  final key = 'river_matrix.session.$namespace';

  test(
    'cold preview restores only the saved device and saves rotated credentials on errors',
    () async {
      final storage = MemoryMatrixStorage();
      storage.values['river.offline_profile'] = jsonEncode({
        'origin': 'https://chat.gravitas.cool',
        'profile': profile,
      });
      storage.values[key] = jsonEncode({
        'homeserver': profile['issuer'],
        'user_id': profile['user_id'],
        'store': 'test',
        'store_key': 'x' * 43,
        'session': '{}',
      });
      final engine = PreviewTransport();
      var opens = 0, requests = 0;
      final api = RiverApi(
        live: false,
        matrixEnabled: true,
        matrixStorage: storage,
        matrixFactory: (_) async {
          opens++;
          return engine;
        },
        client: MockClient((_) async {
          requests++;
          return http.Response('{}', 500);
        }),
      )..active = false;
      try {
        expect(
          await api.notificationPreview({
            ...ticket,
            'subject': 'bob',
          }, restore: true),
          isEmpty,
        );
        expect(opens, 0);
        expect(await api.notificationPreview(ticket, restore: true), {
          'title': 'Friends',
          'sender': 'Bob',
          'body': 'Hello 🌊🔐',
        });
        expect(engine.roomReads, 0);
        expect(requests, 0);
        expect(opens, 1);
        expect(api.matrix.active, isFalse);
        final saved = jsonDecode(storage.values[key]!);
        expect(
          jsonDecode(saved['session'])['refresh_token'],
          'rotated-refresh',
        );
        engine.needsKey = true;
        engine.onSync = () {
          expect(
            jsonDecode(
              jsonDecode(storage.values[key]!)['session'],
            )['refresh_token'],
            'rotated-refresh',
          );
        };
        expect(
          await api.notificationPreview(ticket),
          containsPair('body', 'Hello 🌊🔐'),
        );
        expect(engine.syncs, 1);
        expect(engine.actions, 3);
        engine.fail = true;
        await expectLater(api.notificationPreview(ticket), throwsStateError);
        expect(
          jsonDecode(
            jsonDecode(storage.values[key]!)['session'],
          )['access_token'],
          'rotated-access',
        );
        engine.fail = false;
        engine.gate = Completer<void>();
        final delayed = api.notificationPreview(ticket);
        while (engine.actions < 5) {
          await Future<void>.delayed(Duration.zero);
        }
        api.user = {...profile, 'sub': 'another-account'};
        engine.gate!.complete();
        expect(await delayed, isEmpty);
        expect(opens, 1);
      } finally {
        api.dispose();
      }
    },
  );

  test(
    'opening UI during headless preview serializes boot and reuses the runtime',
    () async {
      final api = RuntimeApi();
      final messenger =
          TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
      messenger.setMockMethodCallHandler(
        NotificationRuntime.channel,
        (_) async => false,
      );
      Future<Object?> native(String method, [Object? args]) async {
        final result = Completer<Object?>();
        messenger.handlePlatformMessage(
          NotificationRuntime.channel.name,
          const StandardMethodCodec().encodeMethodCall(
            MethodCall(method, args),
          ),
          (bytes) {
            result.complete(const StandardMethodCodec().decodeEnvelope(bytes!));
          },
        );
        return result.future;
      }

      Future<void>? startup;
      var shows = 0;
      final runtime = NotificationRuntime(api, (future) {
        shows++;
        startup = future;
      });
      try {
        await runtime.start();
        expect(shows, 0);
        final preview = native('preview', ticket);
        await Future<void>.delayed(Duration.zero);
        await native('show');
        await native('show');
        expect(shows, 1);
        expect(api.trace, ['preview:true']);
        api.gate.complete();
        await preview;
        await startup;
        await native('preview', ticket);
        expect(api.trace, ['preview:true', 'boot', 'preview:false']);
      } finally {
        NotificationRuntime.channel.setMethodCallHandler(null);
        messenger.setMockMethodCallHandler(NotificationRuntime.channel, null);
        api.dispose();
      }
    },
  );
}
