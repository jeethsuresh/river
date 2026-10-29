import 'dart:async';
import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:river/api.dart';
import 'package:river/main.dart';
import 'matrix_messaging_test.dart' show matrixProfile, MemoryMatrixStorage;
import 'messaging_flows_test.dart' show FlowTransport, room, device;

class OfflineTransport extends FlowTransport {
  Completer<void>? draftRead, localWrite, logoutGate;
  @override
  Future<void> close(bool logout) async {
    if (logout) await logoutGate?.future;
    await super.close(logout);
  }

  @override
  Future<Json> history(String room, String? cursor) async {
    if (offline) throw StateError('RIVER_NETWORK_UNAVAILABLE');
    return {
      'events': [
        {
          'event_id': cursor == null ? '\$latest-$room' : '\$older-$room',
          'sender': '@alice:example.org',
          'room_id': room,
          'type': 'm.room.message',
          'origin_server_ts': cursor == null ? 2 : 1,
          'content': {
            'msgtype': 'm.text',
            'body': '${cursor == null ? 'Latest' : 'Older'} in $room',
          },
        },
      ],
      'next_cursor': cursor == null ? 'older' : null,
    };
  }

  @override
  Future<Json> thread(String room, String event, String? cursor) async {
    if (offline) throw StateError('RIVER_NETWORK_UNAVAILABLE');
    return {
      'root': {
        'event_id': event,
        'type': 'm.room.message',
        'sender': '@alice:example.org',
        'content': {'body': 'Cached thread root', 'msgtype': 'm.text'},
      },
      'events': [
        {
          'event_id': r'$reply',
          'type': 'm.room.message',
          'sender': '@alice:example.org',
          'content': {'body': 'Cached thread reply', 'msgtype': 'm.text'},
        },
      ],
      'next_cursor': null,
    };
  }

  @override
  Future<Json> action(Json payload) async {
    if (payload['action'] == 'local_write') await localWrite?.future;
    if (payload['action'] == 'local_read' && payload['scope'] == 'draft') {
      await draftRead?.future;
    }
    return super.action(payload);
  }
}

class Fixture {
  late MemoryMatrixStorage storage;
  late OfflineTransport engine;
  bool offline = false, revoked = false;
  Completer<http.Response>? configGate;
  final rooms = [
    room('one', '!one:example.org'),
    room('two', '!two:example.org'),
  ];

  RiverApi api() => RiverApi(
    live: false,
    matrixEnabled: true,
    matrixStorage: storage,
    matrixFactory: (_) async => engine,
    client: MockClient((request) async {
      if (request.url.path == '/auth/gravitas/config' && configGate != null) {
        return configGate!.future;
      }
      if (offline) throw http.ClientException('network down');
      if (revoked &&
          (request.url.path == '/api/session' ||
              request.url.path == '/api/session/refresh')) {
        return http.Response('{"error":"invalid_session"}', 401);
      }
      return http.Response(
        jsonEncode(switch (request.url.path) {
          '/auth/gravitas/config' => {},
          '/api/session' => {'user': matrixProfile},
          '/api/overview' => {'groups': rooms, 'recent': []},
          _ => {'friends': [], 'requests': [], 'blocked': []},
        }),
        200,
      );
    }),
  );

  Future<void> seed() async {
    engine = OfflineTransport()..roomList = rooms;
    final saved = await device(engine);
    storage = saved.storage as MemoryMatrixStorage;
    final online = api();
    await online.boot();
    await online.open('two');
    await online.open('one');
    await online.older();
    await online.thread('one', r'$root');
    await online.saveDraft('!one:example.org', {
      'text': 'Draft after restart',
      'files': [],
      'txn': 'stable-retry',
      'payload': 'payload',
    });
    final records = jsonDecode(jsonEncode(engine.localValues)) as Json;
    online.dispose();
    engine = OfflineTransport()..roomList = rooms;
    for (final record in records.entries) {
      engine.localValues[record.key] = (record.value as Map)
          .cast<String, dynamic>();
    }
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUp(() => FlutterSecureStorage.setMockInitialValues({}));

  for (final width in [390.0, 1200.0]) {
    testWidgets(
      'offline restart restores rooms, paged history and drafts at width $width',
      (tester) async {
        await tester.binding.setSurfaceSize(Size(width, 1000));
        addTearDown(() => tester.binding.setSurfaceSize(null));
        final fixture = Fixture();
        await fixture.seed();
        fixture.offline = true;
        fixture.engine.offline = true;
        final api = fixture.api();
        await api.boot();
        expect(api.user, matrixProfile);
        expect(api.matrixConnected, true);
        expect(api.groups, hasLength(2));
        expect(api.selected, 'one');
        expect(api.events.map((e) => e['content']['body']), [
          'Older in !one:example.org',
          'Latest in !one:example.org',
        ]);
        expect(api.networkUnavailable, true);
        await expectLater(
          api.updateGroup('one', name: 'Offline rename'),
          throwsStateError,
        );
        await expectLater(api.membership('one', 'leave'), throwsStateError);
        final thread = await api.thread('one', r'$root');
        expect(thread['root']['content']['body'], 'Cached thread root');
        expect(
          (thread['events'] as List).single['content']['body'],
          'Cached thread reply',
        );
        await tester.pumpWidget(RiverApp(api: api, boot: false));
        await tester.pumpAndSettle();
        expect(find.text('Network unavailable'), findsOneWidget);
        expect(find.text('Older in !one:example.org'), findsOneWidget);
        expect(find.text('Latest in !one:example.org'), findsOneWidget);
        await tester.ensureVisible(find.text('Markdown'));
        await tester.tap(find.text('Markdown'));
        await tester.pumpAndSettle();
        expect(
          tester
              .widget<TextField>(find.byType(TextField).last)
              .controller!
              .text,
          'Draft after restart',
        );
        await tester.enterText(
          find.byType(TextField).last,
          'Edited while offline',
        );
        expect(
          (await api.draft('!one:example.org'))!['text'],
          'Edited while offline',
        );
        await api.open('two');
        await tester.pumpAndSettle();
        expect(
          api.events.single['content']['body'],
          'Latest in !two:example.org',
        );
        expect(
          tester
              .widget<TextField>(find.byType(TextField).last)
              .controller!
              .text,
          isEmpty,
        );
        fixture.offline = false;
        fixture.engine.offline = false;
        await api.refresh();
        await tester.pumpAndSettle();
        expect(api.networkUnavailable, false);
        expect(find.text('Network unavailable'), findsNothing);
        expect(
          api.events,
          hasLength(1),
          reason: 'Refreshed events are deduplicated',
        );
        expect(tester.takeException(), isNull);
        await tester.pumpWidget(const SizedBox());
      },
    );
  }

  test(
    'cached interface becomes available before a stalled network check finishes',
    () async {
      final fixture = Fixture();
      await fixture.seed();
      fixture.configGate = Completer<http.Response>();
      final api = fixture.api();
      final booting = api.boot();
      for (var i = 0; i < 100 && api.loading; i++) {
        await Future<void>.delayed(const Duration(milliseconds: 1));
      }
      expect(api.loading, false);
      expect(api.events, hasLength(2));
      fixture.configGate!.complete(http.Response('{}', 200));
      await booting;
      api.dispose();
    },
  );

  test('a queued local read cannot move to a replacement device', () async {
    final fixture = Fixture();
    await fixture.seed();
    final api = fixture.api();
    await api.boot();
    final old = fixture.engine;
    old.localWrite = Completer<void>();
    final writing = api.matrix.writeLocal('draft', {
      'text': 'Old device draft',
    }, room: '!one:example.org');
    final rejectedWrite = expectLater(writing, throwsStateError);
    final reading = api.matrix.readLocal('draft', room: '!one:example.org');
    final rejectedRead = expectLater(reading, throwsStateError);
    await Future<void>.delayed(Duration.zero);
    await api.matrix.disconnect();
    fixture.engine = OfflineTransport()..roomList = fixture.rooms;
    fixture.engine.localValues['draft:!one:example.org:null'] = {
      'text': 'Replacement device',
    };
    await api.matrix.bind(matrixProfile, synchronize: false);
    old.localWrite!.complete();
    await Future.wait([rejectedWrite, rejectedRead]);
    expect(
      (await api.matrix.readLocal('draft', room: '!one:example.org'))!['text'],
      'Replacement device',
    );
    api.dispose();
  });

  test(
    'an account without its own saved Matrix device cannot read another account cache',
    () async {
      final fixture = Fixture();
      await fixture.seed();
      fixture.storage.values['river.offline_profile'] = jsonEncode({
        'origin': Uri.parse(RiverApi.endpoint).origin,
        'profile': {
          ...matrixProfile,
          'sub': 'bob',
          'user_id': '@bob:example.org',
        },
      });
      fixture.offline = true;
      final api = fixture.api();
      await api.boot();
      expect(api.user, isNull);
      expect(api.groups, isEmpty);
      expect(api.events, isEmpty);
      api.dispose();
    },
  );

  test(
    'explicit rejection clears cached identity and never falls back to offline data',
    () async {
      final fixture = Fixture();
      await fixture.seed();
      fixture.revoked = true;
      final api = fixture.api();
      await api.boot();
      await Future<void>.delayed(Duration.zero);
      expect(api.user, isNull);
      expect(api.groups, isEmpty);
      expect(api.events, isEmpty);
      expect(fixture.storage.values['river.offline_profile'], isNull);
      api.dispose();
      fixture.offline = true;
      final restarted = fixture.api();
      await restarted.boot();
      expect(restarted.user, isNull);
      restarted.dispose();
    },
  );

  test(
    'native logout removes its startup identity before a blocked network logout finishes',
    () async {
      final fixture = Fixture();
      await fixture.seed();
      final api = fixture.api();
      await api.boot();
      await api.storage.write(key: 'river_session', value: 'native-token');
      fixture.engine.logoutGate = Completer<void>();
      final loggingOut = api.logout();
      for (
        var i = 0;
        i < 100 && fixture.storage.values.containsKey('river.offline_profile');
        i++
      ) {
        await Future<void>.delayed(const Duration(milliseconds: 1));
      }
      expect(fixture.storage.values['river.offline_profile'], isNull);
      expect(await api.storage.read(key: 'river_session'), isNull);
      fixture.engine.logoutGate!.complete();
      await loggingOut;
      api.dispose();
    },
  );

  test('logout while offline removes the startup identity', () async {
    final fixture = Fixture();
    await fixture.seed();
    fixture.offline = true;
    final api = fixture.api();
    await api.boot();
    await api.logout();
    await Future<void>.delayed(Duration.zero);
    expect(fixture.storage.values['river.offline_profile'], isNull);
    expect(api.user, isNull);
    api.dispose();
  });

  testWidgets(
    'a delayed draft read cannot overwrite text typed in the new room',
    (tester) async {
      final fixture = Fixture();
      await fixture.seed();
      final api = fixture.api();
      await api.boot();
      fixture.engine.draftRead = Completer<void>();
      await tester.pumpWidget(RiverApp(api: api, boot: false));
      await tester.pump();
      await tester.ensureVisible(find.text('Markdown'));
      await tester.tap(find.text('Markdown'));
      await tester.pump();
      await tester.enterText(find.byType(TextField).last, 'New typing');
      fixture.engine.draftRead!.complete();
      await tester.pumpAndSettle();
      expect(
        tester.widget<TextField>(find.byType(TextField).last).controller!.text,
        'New typing',
      );
      expect((await api.draft('!one:example.org'))!['text'], 'New typing');
      await tester.pumpWidget(const SizedBox());
    },
  );
}
