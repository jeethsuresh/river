import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:river/api.dart';
import 'package:river/main.dart';
import 'package:river/rich_composer.dart';

import 'matrix_messaging_test.dart' show matrixProfile;
import 'messaging_flows_test.dart' show FlowTransport, device, room;

const secureRoom = '!secure:example.org';
const olderRoom = '!legacy:example.org';
const plainRoom = '!fallback:example.org';
const bob = '@bob:example.org';

Json dm(String id, String wire, {required bool encrypted, String peer = bob}) =>
    {
      ...room(id, wire),
      'kind': 'dm',
      'encrypted': encrypted,
      'direct_peer': peer,
      'can_use_fallback': true,
    };

class FallbackTransport extends FlowTransport {
  final reads = <(String, String?)>[];
  final routes = <(String, String)>[];
  bool encryptionBlocked = false,
      failEnableEncryption = false,
      verified = false;
  String? unavailableHistory;

  @override
  Future<Json> send(String room, String type, Json content, String txn) async {
    routes.add((room, txn));
    if (room == secureRoom && encryptionBlocked) {
      return {'encryption_unavailable': true};
    }
    return super.send(room, type, content, txn);
  }

  @override
  Future<Json> sendAttachment(
    String room,
    String name,
    String mime,
    Uint8List bytes,
    String txn,
  ) => send(room, 'm.room.message', {'body': name, 'msgtype': 'm.file'}, txn);

  @override
  Future<Json> rooms() async => {
    ...await super.rooms(),
    'device_verified': verified,
  };

  @override
  Future<Json> sync() async => {
    ...await super.sync(),
    'device_verified': verified,
  };

  @override
  Future<Json> action(Json payload) async {
    if (payload['action'] == 'encrypt' && failEnableEncryption) {
      actions.add(payload);
      throw StateError('Encryption setup is unavailable');
    }
    if (payload['action'] != 'unencrypted_fallback') {
      return super.action(payload);
    }
    actions.add(payload);
    if (!roomList.any((r) => r['room_id'] == plainRoom)) {
      roomList = [
        ...roomList,
        {
          ...dm('fallback', plainRoom, encrypted: false),
          'direct_peer': null,
          'fallback_for': secureRoom,
          'is_fallback_room': true,
        },
      ];
    }
    return {'room_id': plainRoom};
  }

  @override
  Future<Json> history(String room, String? cursor) async {
    reads.add((room, cursor));
    if (room == unavailableHistory) throw StateError('History unavailable');
    final ts = cursor != null
        ? 0
        : room == secureRoom
        ? 2
        : 1;
    return {
      'events': [
        {
          'event_id': '$history-$room-$ts',
          'sender': bob,
          'type': 'm.room.message',
          'origin_server_ts': ts,
          'content': {'body': 'Message in $room', 'msgtype': 'm.text'},
          'river_encrypted': room == secureRoom,
        },
        ...sentEvents.values.where(
          (e) => cursor == null && e['room_id'] == room,
        ),
      ],
      'next_cursor': cursor == null ? 'earlier:$room' : null,
    };
  }

  @override
  Future<Json> thread(String room, String event, String? cursor) async => {
    'root': (await history(room, null))['events'].first,
    'events': <Json>[],
  };
}

Future<RiverApi> openConversation(
  FallbackTransport engine, {
  bool disposeWithWidget = false,
  List<Json>? roomSnapshot,
  List<Json>? delegated,
  bool directFriend = false,
}) async {
  final secure = dm('direct', secureRoom, encrypted: true);
  engine.roomList =
      roomSnapshot ??
      [
        secure,
        dm('older', olderRoom, encrypted: false),
        dm(
          'other',
          '!other:example.org',
          encrypted: false,
          peer: '@carol:example.org',
        ),
      ];
  final saved = await device(engine);
  addTearDown(saved.dispose);
  final api = RiverApi(
    live: false,
    matrixEnabled: true,
    matrixFactory: (_) async => engine,
    matrixStorage: saved.storage,
    client: MockClient(
      (request) async => http.Response(
        jsonEncode(
          request.url.path == '/api/direct' && directFriend
              ? engine.roomList.first
              : request.url.path == '/api/overview'
              ? {
                  'groups': delegated ?? [secure],
                  'recent': [],
                }
              : {
                  'friends': [
                    if (directFriend) {'user_id': bob},
                  ],
                  'requests': [],
                  'blocked': [],
                },
        ),
        200,
      ),
    ),
  )..user = Map.of(matrixProfile);
  if (!disposeWithWidget) addTearDown(api.dispose);
  await api.matrix.bind(matrixProfile);
  await api.refresh();
  await api.open('direct');
  return api;
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test(
    'opening a direct chat survives failed optional encryption setup',
    () async {
      final engine = FallbackTransport()
        ..verified = true
        ..failEnableEncryption = true;
      final plain = {
        ...dm('direct', secureRoom, encrypted: false),
        'can_encrypt': true,
      };
      final api = await openConversation(
        engine,
        roomSnapshot: [plain],
        delegated: [plain],
        directFriend: true,
      );
      await api.messageFriend(bob);
      expect(api.selected, 'direct');
      expect(
        engine.actions.where((a) => a['action'] == 'encrypt'),
        hasLength(1),
      );
      await api.send('direct', 'm.room.message', {
        'body': 'Hi',
        'msgtype': 'm.text',
      }, 'first');
      expect(engine.sentEvents['first']?['room_id'], secureRoom);
    },
  );

  test(
    'an ambiguous fallback delivery retries only its original route',
    () async {
      final engine = FallbackTransport()..encryptionBlocked = true;
      final api = await openConversation(engine);
      final body = {'body': 'Keep this message', 'msgtype': 'm.text'};
      engine.loseSendResponse = true;
      await expectLater(
        api.send('direct', 'm.room.message', body, 'retry'),
        throwsStateError,
      );
      engine.encryptionBlocked = false;
      final result = await api.send('direct', 'm.room.message', body, 'retry');
      expect(result['river_encrypted'], isFalse);
      expect(engine.routes, [
        (secureRoom, 'retry'),
        (plainRoom, 'retry'),
        (plainRoom, 'retry'),
      ]);
      expect(engine.sentEvents, hasLength(1));

      final next = await api.send('direct', 'm.room.message', body, 'next');
      expect(next['river_room_id'], secureRoom);
      expect(next['river_encrypted'], isTrue);
    },
  );

  test('a lost encrypted response never creates an unencrypted copy', () async {
    final engine = FallbackTransport();
    final api = await openConversation(engine);
    engine.loseSendResponse = true;
    final body = {'body': 'One copy', 'msgtype': 'm.text'};
    await expectLater(
      api.send('direct', 'm.room.message', body, 'lost'),
      throwsStateError,
    );
    engine.encryptionBlocked = true;
    await expectLater(
      api.send('direct', 'm.room.message', body, 'lost'),
      throwsStateError,
    );
    engine.encryptionBlocked = false;
    await api.send('direct', 'm.room.message', body, 'lost');
    expect(engine.routes, [
      (secureRoom, 'lost'),
      (secureRoom, 'lost'),
      (secureRoom, 'lost'),
    ]);
    expect(
      engine.actions.where((a) => a['action'] == 'unencrypted_fallback'),
      isEmpty,
    );
  });

  test(
    'attachments and replies fall back within the same conversation',
    () async {
      final engine = FallbackTransport()..encryptionBlocked = true;
      final api = await openConversation(engine);
      expect(
        await api.sendMatrixFile(
          'direct',
          'proof.txt',
          'text/plain',
          Uint8List.fromList([1]),
        ),
        isFalse,
      );
      final root = api.events.firstWhere((e) => e['room_id'] == secureRoom);
      final rootId = root['event_id'] as String;
      final result = await api.send(
        'direct',
        'm.room.message',
        {
          'body': 'A reply',
          'msgtype': 'm.text',
          'm.relates_to': {'rel_type': 'm.thread', 'event_id': rootId},
        },
        'reply',
        eventRoom: secureRoom,
      );
      expect(result['river_room_id'], plainRoom);
      final reply = engine.sentEvents['reply']!;
      expect(reply['content']['m.relates_to'], isNull);
      expect(
        reply['content']['cool.gravitas.river.thread.v1']['room_id'],
        secureRoom,
      );
      final thread = await api.thread('direct', rootId, eventRoom: secureRoom);
      expect((thread['events'] as List).single['event_id'], reply['event_id']);
    },
  );

  test(
    'Gravitas groups share history for exactly the same participants',
    () async {
      const alice = '@alice:example.org', carol = '@carol:example.org';
      Json groupChat(String id, String wire, List<String> participants) => {
        ...room(id, wire),
        'conversation_participants': participants,
      };
      final groups = [
        groupChat('direct', secureRoom, [alice, bob, carol]),
        groupChat('second', olderRoom, [carol, alice, bob]),
        groupChat('other', '!other:example.org', [
          alice,
          bob,
          '@dave:example.org',
        ]),
      ];
      final engine = FallbackTransport();
      final api = await openConversation(
        engine,
        roomSnapshot: groups,
        delegated: groups,
      );
      expect(api.groups, hasLength(2));
      expect(api.conversationForWire(olderRoom)?['id'], 'second');
      await api.conversation('Same conversation', [carol, bob]);
      expect(api.selected, 'second');
      expect(api.events.map((e) => e['room_id']).toSet(), {
        olderRoom,
        secureRoom,
      });
      engine.unavailableHistory = secureRoom;
      await api.older();
      expect(api.events.any((e) => e['origin_server_ts'] == 0), isTrue);
      engine.roomList = [
        for (final g in groups)
          if (g['room_id'] == olderRoom) {...g, 'membership': 'leave'} else g,
      ];
      await api.matrix.refreshRooms();
      expect(api.selected, 'direct');
    },
  );

  testWidgets('Send automatically falls back and announces delivery', (
    tester,
  ) async {
    final engine = FallbackTransport()..encryptionBlocked = true;
    final api = await openConversation(engine, disposeWithWidget: true);
    await tester.pumpWidget(RiverApp(api: api, boot: false));
    await tester.pumpAndSettle();
    final composer = tester.widget<RichComposer>(find.byType(RichComposer));
    composer.controller.text = 'Send this now';
    await tester.tap(find.byKey(const ValueKey('message-send')));
    await tester.pumpAndSettle();
    expect(composer.controller.text, isEmpty);
    expect(engine.sentEvents.values.single['room_id'], plainRoom);
    expect(api.selected, 'direct');
    expect(
      tester
          .widget<IconButton>(find.byKey(const ValueKey('message-send')))
          .tooltip,
      'Sent unencrypted',
    );
    await tester.pumpWidget(const SizedBox());
  });

  test(
    'participant history paginates across Matrix rooms and keeps event routing',
    () async {
      final engine = FallbackTransport();
      final api = await openConversation(engine);
      const content = {'body': 'Hello', 'msgtype': 'm.text'};
      expect(api.groups, hasLength(2));
      expect(api.events.map((e) => e['room_id']), [olderRoom, secureRoom]);
      final first = api.events.first['event_id'] as String;
      await api.react('direct', first, '👍', true, eventRoom: olderRoom);
      expect(
        engine.actions.lastWhere((a) => a['action'] == 'reaction')['room'],
        olderRoom,
      );
      await api.thread('direct', first, eventRoom: olderRoom);
      expect(engine.reads.last.$1, olderRoom);
      await api.older();
      expect(api.events.map((e) => e['room_id']).toSet(), {
        secureRoom,
        olderRoom,
      });
      expect(
        engine.reads,
        containsAll([
          (secureRoom, 'earlier:$secureRoom'),
          (olderRoom, 'earlier:$olderRoom'),
        ]),
      );
      expect(api.nextCursor, isNull);

      await api.send(
        'direct',
        'm.room.message',
        content,
        'secure',
        refreshAfter: false,
      );
      expect(engine.sentEvents['secure']?['room_id'], secureRoom);
      await api.chooseUnencrypted('direct');
      expect(api.selected, 'direct');
      expect(api.conversationForWire(plainRoom)?['id'], 'direct');
      engine.loseSendResponse = true;
      await expectLater(
        api.send(
          'direct',
          'm.room.message',
          content,
          'lost',
          refreshAfter: false,
        ),
        throwsStateError,
      );
      api.chooseEncrypted('direct');
      await expectLater(
        api.send(
          'direct',
          'm.room.message',
          content,
          'lost',
          refreshAfter: false,
        ),
        throwsStateError,
      );
      expect(engine.sendAttempts, ['secure', 'lost']);
      await api.chooseUnencrypted('direct');
      await api.send(
        'direct',
        'm.room.message',
        content,
        'lost',
        refreshAfter: false,
      );
      expect(engine.sentEvents['lost']?['room_id'], plainRoom);
      await api.refresh();
      expect(api.events.map((e) => e['room_id']).toSet(), {
        secureRoom,
        olderRoom,
        plainRoom,
      });

      engine.roomList = [
        for (final r in engine.roomList)
          {...r, if (r['room_id'] == plainRoom) 'fallback_for': null},
      ];
      await api.matrix.refreshRooms();
      await api.refresh();
      expect(api.events.map((e) => e['room_id']), isNot(contains(plainRoom)));
      await expectLater(
        api.send('direct', 'm.room.message', content, 'changed'),
        throwsStateError,
      );
      expect(engine.sentEvents, isNot(contains('changed')));
    },
  );

  testWidgets(
    'an unverified session confirms fallback and keeps the same composer',
    (tester) async {
      final engine = FallbackTransport();
      final api = await openConversation(engine, disposeWithWidget: true);
      await tester.pumpWidget(RiverApp(api: api, boot: false));
      await tester.pumpAndSettle();
      final composer = tester.widget<RichComposer>(find.byType(RichComposer));
      composer.controller.text = 'Keep this draft';
      await tester.tap(find.text('Send unencrypted'));
      await tester.pumpAndSettle();
      expect(find.text('Send unencrypted?'), findsOneWidget);
      await tester.tap(find.text('Cancel'));
      await tester.pumpAndSettle();
      expect(
        engine.actions.where((a) => a['action'] == 'unencrypted_fallback'),
        isEmpty,
      );
      await tester.tap(find.text('Send unencrypted'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Continue unencrypted'));
      await tester.pumpAndSettle();
      expect(
        engine.actions.where((a) => a['action'] == 'unencrypted_fallback'),
        hasLength(1),
      );
      expect(api.sendingUnencrypted('direct'), isTrue);
      expect(find.text('Messages are unencrypted'), findsOneWidget);
      expect(composer.controller.text, 'Keep this draft');
      expect(api.selected, 'direct');
      await tester.tap(find.byKey(const ValueKey('message-send')));
      await tester.pumpAndSettle();
      expect(engine.sentEvents.values.single['room_id'], plainRoom);
      await tester.tap(find.text('Use encryption'));
      await tester.pumpAndSettle();
      expect(find.text('Messages are unencrypted'), findsNothing);
      expect(api.composerWire('direct'), secureRoom);
      await tester.pumpWidget(const SizedBox());
    },
  );
}
