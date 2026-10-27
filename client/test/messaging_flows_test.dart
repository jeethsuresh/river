import 'dart:async';
import 'dart:convert';
import 'package:crypto/crypto.dart';
import 'package:flutter/material.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:river/api.dart';
import 'package:river/matrix_messaging.dart';
import 'package:river/main.dart';
import 'package:river/workspace_widgets.dart';
import 'matrix_messaging_test.dart'
    show FakeMatrixTransport, MemoryMatrixStorage, matrixProfile;

class FlowTransport extends FakeMatrixTransport {
  List<Json> roomList = [];
  List<Json>? nextRooms;
  int delayedPolls = 0;
  final actions = <Json>[];
  final sentEvents = <String, Json>{};
  final sendAttempts = <String>[];
  bool loseSendResponse = false;
  bool rosterUnavailable = false, offline = false;
  int syncs = 0;
  Completer<void>? syncGate;
  @override
  Future<Json> sync() async {
    syncs++;
    await syncGate?.future;
    if (offline) throw StateError('offline');
    if (delayedPolls > 0) {
      delayedPolls--;
    } else if (nextRooms != null) {
      roomList = nextRooms!;
      nextRooms = null;
    }
    return {'rooms': roomList, 'changed': []};
  }

  @override
  Future<Json> history(String room, String? cursor) async => {
    'events': [
      {
        'event_id': '\$message-$room',
        'sender': '@alice:example.org',
        'type': 'm.room.message',
        'origin_server_ts': 1,
        'content': {'body': 'Message in $room', 'msgtype': 'm.text'},
      },
      ...sentEvents.values.where((e) => e['room_id'] == room),
    ],
    'next_cursor': null,
  };
  @override
  Future<Json> send(String room, String type, Json content, String txn) async {
    sendAttempts.add(txn);
    final event = sentEvents.putIfAbsent(
      txn,
      () => {
        'event_id': '\$sent-$txn',
        'room_id': room,
        'sender': matrixProfile['user_id'],
        'type': type,
        'origin_server_ts': 2,
        'content': Map.of(content),
      },
    );
    if (loseSendResponse) {
      loseSendResponse = false;
      throw StateError('Lost send response');
    }
    return {'event_id': event['event_id']};
  }

  @override
  Future<Json> members(String room) async {
    if (rosterUnavailable) throw StateError('roster unavailable');
    return {'members': []};
  }

  @override
  Future<Json> action(Json payload) async {
    actions.add(payload);
    if (payload['action'] == 'join') {
      roomList = [
        for (final r in roomList)
          {...r, if (r['room_id'] == payload['room']) 'membership': 'join'},
      ];
    }
    if (payload['action'] == 'encrypt') {
      roomList = [
        for (final r in roomList)
          {...r, if (r['room_id'] == payload['room']) 'encrypted': true},
      ];
    }
    return {};
  }
}

Json room(String id, String wire) => {
  'id': id,
  'room_id': wire,
  'name': id,
  'kind': 'group',
  'membership': 'join',
  'members': <Json>[],
  'parents': [],
  'encrypted': false,
  'can_encrypt': true,
};

Future<MatrixMessaging> device(FlowTransport engine) async {
  final storage = MemoryMatrixStorage();
  final namespace = sha256.convert(utf8.encode('https://example.org|alice'));
  storage.values['river_matrix.session.$namespace'] = jsonEncode({
    'user_id': matrixProfile['user_id'],
    'homeserver': matrixProfile['issuer'],
    'store': 'same-store',
    'store_key': 'k' * 43,
    'session': 'same-device',
  });
  return MatrixMessaging(
    request: (_, {method = 'GET', body}) async => {},
    changed: () {},
    storage: storage,
    factory: (_) async => engine,
    syncEnabled: false,
  );
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUp(() => FlutterSecureStorage.setMockInitialValues({}));

  for (final width in [390.0, 1200.0]) {
    testWidgets(
      'picker, encrypted send retry and separate drafts at width $width',
      (tester) async {
        await tester.binding.setSurfaceSize(Size(width, 1000));
        addTearDown(() => tester.binding.setSurfaceSize(null));
        final engine = FlowTransport()
          ..roomList = [room('old', '!old:example.org')];
        final saved = await device(engine);
        final delegated = [room('old', '!old:example.org')];
        final api =
            RiverApi(
                live: false,
                matrixEnabled: true,
                matrixFactory: (_) async => engine,
                matrixStorage: saved.storage,
                client: MockClient((r) async {
                  if (r.url.path == '/api/direct') {
                    delegated.add(room('direct', '!direct:example.org'));
                    engine.roomList = List.of(delegated);
                    return http.Response('{"id":"direct"}', 200);
                  }
                  return http.Response(
                    jsonEncode(
                      r.url.path == '/api/overview'
                          ? {'groups': delegated, 'recent': []}
                          : {
                              'friends': [
                                {
                                  'username': 'Bob',
                                  'user_id': '@bob:example.org',
                                },
                              ],
                              'requests': [],
                              'blocked': [],
                            },
                    ),
                    200,
                  );
                }),
              )
              ..user = Map.of(matrixProfile)
              ..loading = false;
        await api.matrix.bind(matrixProfile);
        await api.refresh();
        await tester.pumpWidget(
          MaterialApp(
            home: Scaffold(
              body: Builder(
                builder: (context) => TextButton(
                  onPressed: () => showDialog<void>(
                    context: context,
                    builder: (_) => ConversationPicker(app: api),
                  ),
                  child: const Text('Open picker'),
                ),
              ),
            ),
          ),
        );
        await tester.tap(find.text('Open picker'));
        await tester.pumpAndSettle();
        await tester.tap(find.text('Bob'));
        await tester.pumpAndSettle();
        await tester.tap(find.text('Start conversation'));
        await tester.pumpAndSettle();
        expect(api.selected, 'direct');
        expect(engine.actions.any((a) => a['action'] == 'encrypt'), true);
        await tester.pumpWidget(RiverApp(api: api, boot: false));
        await tester.pumpAndSettle();
        await tester.tap(find.text('Markdown'));
        await tester.pumpAndSettle();
        await tester.enterText(
          find.byType(TextField).last,
          'A message with a lost response',
        );
        engine.loseSendResponse = true;
        await tester.tap(find.byTooltip('Send'));
        await tester.pumpAndSettle();
        expect(find.textContaining('Your draft is kept.'), findsOneWidget);
        expect(
          find.byType(TextField).last.evaluate().single.widget,
          isA<TextField>().having(
            (w) => w.controller!.text,
            'draft',
            'A message with a lost response',
          ),
        );
        await tester.tap(find.text('Retry'));
        await tester.pumpAndSettle();
        expect(engine.sendAttempts, hasLength(2));
        expect(engine.sendAttempts.toSet(), hasLength(1));
        expect(engine.sentEvents, hasLength(1));
        expect(
          api.events.where(
            (e) => e['content']['body'] == 'A message with a lost response',
          ),
          hasLength(1),
        );
        await tester.enterText(find.byType(TextField).last, 'Direct draft');
        await api.open('old');
        await tester.pumpAndSettle();
        expect(
          (tester.widget<TextField>(
            find.byType(TextField).last,
          )).controller!.text,
          isEmpty,
        );
        await tester.enterText(find.byType(TextField).last, 'Old room draft');
        await api.open('direct');
        await tester.pumpAndSettle();
        expect(
          (tester.widget<TextField>(
            find.byType(TextField).last,
          )).controller!.text,
          'Direct draft',
        );
        expect(tester.takeException(), isNull);
        await tester.pumpWidget(const SizedBox());
        saved.dispose();
      },
    );
  }

  test(
    'same account retries its saved Matrix device after an offline restore',
    () async {
      final engine = FlowTransport()..offline = true;
      final matrix = await device(engine);
      await matrix.bind(matrixProfile);
      expect(matrix.connected, false);
      engine.offline = false;
      await matrix.bind(matrixProfile);
      expect(matrix.connected, true);
      expect(engine.syncs, 2);
      matrix.dispose();
    },
  );

  test(
    'foreground syncs share a pending poll and publish its room snapshot',
    () async {
      final engine = FlowTransport();
      final matrix = await device(engine);
      await matrix.bind(matrixProfile);
      engine.syncGate = Completer<void>();
      final first = matrix.syncNow(), second = matrix.syncNow();
      await Future<void>.delayed(Duration.zero);
      expect(engine.syncs, 2, reason: 'one restore and one shared poll');
      engine.roomList = [room('new', '!new:example.org')];
      engine.syncGate!.complete();
      await Future.wait([first, second]);
      expect(matrix.roomList.single['room_id'], '!new:example.org');
      matrix.dispose();
    },
  );

  test(
    'a create racing the active sync waits for the following room snapshot',
    () async {
      final engine = FlowTransport();
      final matrix = await device(engine);
      await matrix.bind(matrixProfile);
      engine.delayedPolls = 1;
      engine.nextRooms = [room('new', '!new:example.org')];
      await matrix.ensureJoinedRoom('!new:example.org');
      expect(engine.syncs, 3);
      await expectLater(
        matrix.ensureJoinedRoom('!missing:example.org'),
        throwsStateError,
      );
      expect(
        engine.actions,
        isEmpty,
        reason: 'Waiting must not join unapproved rooms.',
      );
      matrix.dispose();
    },
  );

  for (final operation in ['channel', 'space']) {
    test('creating a $operation clears the previous Matrix timeline', () async {
      final engine = FlowTransport()
        ..roomList = [room('old', '!old:example.org')];
      final delegated = [room('old', '!old:example.org')];
      final matrix = await device(engine);
      // Reuse the saved device configuration in the real River controller.
      final api = RiverApi(
        live: false,
        matrixEnabled: true,
        matrixFactory: (_) async => engine,
        matrixStorage: matrix.storage,
        client: MockClient((r) async {
          if (r.method == 'POST') {
            delegated.add(room('new', '!new:example.org'));
            engine.roomList = List.of(delegated);
            return http.Response('{"id":"new"}', 200);
          }
          return http.Response(
            jsonEncode(
              r.url.path == '/api/overview'
                  ? {'groups': delegated, 'recent': []}
                  : {'friends': [], 'requests': [], 'blocked': []},
            ),
            200,
          );
        }),
      )..user = Map.of(matrixProfile);
      await api.matrix.bind(matrixProfile);
      await api.open('old');
      expect(api.events.single['content']['body'], contains('!old:'));
      if (operation == 'channel') {
        await api.createChannel('parent', 'New', 'text');
      } else {
        await api.create('New', 'space');
      }
      expect(api.selected, 'new');
      expect(api.events, hasLength(1));
      expect(api.events.single['content']['body'], contains('!new:'));
      api.dispose();
      matrix.dispose();
    });
  }

  test(
    'room identity migration and roster outage preserve the open messages',
    () async {
      final engine = FlowTransport()
        ..roomList = [room('remote', '!room:example.org')];
      final matrix = await device(engine);
      final delegated = <Json>[];
      final api = RiverApi(
        live: false,
        matrixEnabled: true,
        matrixFactory: (_) async => engine,
        matrixStorage: matrix.storage,
        client: MockClient(
          (r) async => http.Response(
            jsonEncode(
              r.url.path == '/api/overview'
                  ? {'groups': delegated, 'recent': []}
                  : {'friends': [], 'requests': [], 'blocked': []},
            ),
            200,
          ),
        ),
      )..user = Map.of(matrixProfile);
      await api.matrix.bind(matrixProfile);
      await api.open('!room:example.org');
      delegated.add(room('local-id', '!room:example.org'));
      engine.rosterUnavailable = true;
      await api.refresh();
      expect(api.selected, 'local-id');
      expect(
        api.events.single['content']['body'],
        'Message in !room:example.org',
      );
      expect(api.error, isNull);
      api.dispose();
      matrix.dispose();
    },
  );

  test('single-person picker uses the canonical direct conversation', () async {
    final writes = <String>[];
    final api = RiverApi(
      client: MockClient((r) async {
        if (r.method == 'POST') {
          writes.add(r.url.path);
          expect(jsonDecode(r.body)['user_id'], '@bob:example.org');
          return http.Response('{"id":"direct"}', 200);
        }
        return http.Response(
          jsonEncode(
            r.url.path == '/api/overview'
                ? {
                    'groups': [room('direct', '!direct:example.org')],
                    'recent': [],
                  }
                : r.url.path.endsWith('/events')
                ? {'events': [], 'next_cursor': null}
                : {'friends': [], 'requests': [], 'blocked': []},
          ),
          200,
        );
      }),
    )..user = Map.of(matrixProfile);
    await api.conversation('Conversation', ['@bob:example.org']);
    expect(writes, ['/api/direct']);
    expect(api.selected, 'direct');
    api.dispose();
  });

  test(
    'local invitation approval stays delegated; native invites join and removals kick',
    () async {
      final engine = FlowTransport()
        ..roomList = [
          {...room('local', '!local:example.org'), 'membership': 'invite'},
          {...room('remote', '!remote:example.org'), 'membership': 'invite'},
        ];
      final matrix = await device(engine);
      final writes = <Json>[];
      final api = RiverApi(
        live: false,
        matrixEnabled: true,
        matrixFactory: (_) async => engine,
        matrixStorage: matrix.storage,
        client: MockClient((r) async {
          if (r.method == 'POST') {
            writes.add({'path': r.url.path, ...jsonDecode(r.body) as Json});
            engine.roomList = [
              for (final r in engine.roomList)
                {
                  ...r,
                  if (r['room_id'] == '!local:example.org')
                    'membership': 'join',
                },
            ];
            return http.Response('{}', 200);
          }
          return http.Response(
            jsonEncode(
              r.url.path == '/api/overview'
                  ? {
                      'groups': [room('local', '!local:example.org')],
                      'recent': [],
                    }
                  : {'friends': [], 'requests': [], 'blocked': []},
            ),
            200,
          );
        }),
      )..user = Map.of(matrixProfile);
      await api.matrix.bind(matrixProfile);
      await api.refresh();
      await api.membership('local', 'accept');
      expect(writes.single, {
        'path': '/api/groups/local/membership',
        'action': 'accept',
      });
      expect(engine.actions, isEmpty);
      await api.membership('!remote:example.org', 'accept');
      expect(engine.actions.last['action'], 'join');
      expect(engine.actions.last['room'], '!remote:example.org');
      await api.membership('local', 'remove', '@CaseSensitive:remote.test');
      expect(engine.actions.last, {
        'action': 'kick',
        'room': '!local:example.org',
        'user': '@CaseSensitive:remote.test',
      });
      api.dispose();
      matrix.dispose();
    },
  );

  test(
    'cold-start native return redeems the saved verifier and removes it',
    () async {
      FlutterSecureStorage.setMockInitialValues({
        'river_native_pending': jsonEncode({
          'id': 'pending',
          'verifier': 'proof',
          'label': 'ABC123',
          'expires_at': DateTime.now()
              .add(const Duration(minutes: 1))
              .millisecondsSinceEpoch,
        }),
      });
      var polls = 0;
      final api = RiverApi(
        client: MockClient((r) async {
          switch (r.url.path) {
            case '/api/native/session':
              polls++;
              expect(jsonDecode(r.body), {
                'id': 'pending',
                'verifier': 'proof',
              });
              return http.Response('{"session":"approved-session"}', 200);
            case '/api/session':
              expect(r.headers['Authorization'], 'Bearer approved-session');
              return http.Response(jsonEncode({'user': matrixProfile}), 200);
            case '/auth/gravitas/config':
              return http.Response('{}', 200);
            case '/api/overview':
              return http.Response('{"groups":[],"recent":[]}', 200);
            default:
              return http.Response(
                '{"friends":[],"requests":[],"blocked":[]}',
                200,
              );
          }
        }),
      );
      await api.boot();
      expect(polls, 1);
      expect(api.user, matrixProfile);
      expect(await api.storage.read(key: 'river_session'), 'approved-session');
      expect(await api.storage.read(key: 'river_native_pending'), isNull);
      api.dispose();
    },
  );

  test('native browser launch failure clears its pending exchange', () async {
    final api = RiverApi(
      authLaunch: (_) async => false,
      client: MockClient(
        (r) async => http.Response(
          '{"id":"pending","label":"ABC123","url":"https://chat.gravitas.cool/auth/native/start?id=pending"}',
          200,
        ),
      ),
    );
    await expectLater(api.login(username: 'alice'), throwsStateError);
    expect(await api.storage.read(key: 'river_native_pending'), isNull);
    expect(api.pairingLabel, isNull);
    api.dispose();
  });

  test('logging out during native approval cannot restore that login', () async {
    final reply = Completer<http.Response>();
    final polling = Completer<void>();
    final api = RiverApi(
      authLaunch: (_) async => true,
      client: MockClient((r) async {
        if (r.url.path == '/api/native/new') {
          return http.Response(
            '{"id":"pending","label":"ABC123","url":"https://chat.gravitas.cool/auth/native/start?id=pending"}',
            200,
          );
        }
        polling.complete();
        return reply.future;
      }),
    );
    final signingIn = api.login(username: 'alice');
    await polling.future;
    final rejected = expectLater(
      signingIn,
      throwsA(
        isA<ApiException>().having((e) => e.code, 'code', 'session_changed'),
      ),
    );
    await api.logout();
    reply.complete(http.Response('{"session":"must-not-be-restored"}', 200));
    await rejected;
    expect(api.user, isNull);
    expect(api.token, isNull);
    expect(await api.storage.read(key: 'river_session'), isNull);
    expect(await api.storage.read(key: 'river_native_pending'), isNull);
    api.dispose();
  });
}
