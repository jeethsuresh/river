import 'dart:convert';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:river/api.dart';
import 'package:river/matrix_messaging.dart';

import 'matrix_messaging_test.dart'
    show MemoryMatrixStorage, FakeMatrixTransport, matrixProfile;

class RoomTransport extends FakeMatrixTransport {
  bool failSend = false, failFile = false;
  final fileTransactions = <String>[];
  @override
  Future<MatrixJson> sync() async => {
    'rooms': [
      {
        'room_id': '!room:remote',
        'name': 'Encrypted room',
        'kind': 'group',
        'membership': 'join',
        'encrypted': true,
        'parents': [],
      },
    ],
    'changed': [],
  };
  @override
  Future<MatrixJson> send(
    String room,
    String type,
    MatrixJson content,
    String txn,
  ) async {
    sends++;
    if (failSend) throw StateError('Matrix transport failed');
    return {'event_id': r'$sent'};
  }

  @override
  Future<MatrixJson> sendAttachment(
    String room,
    String name,
    String mime,
    Uint8List bytes,
    String txn,
  ) async {
    fileTransactions.add(txn);
    if (failFile) {
      failFile = false;
      throw StateError('Lost response');
    }
    return {'event_id': r'$file'};
  }

  @override
  Future<MatrixJson> history(String room, String? cursor) async => {
    'events': [
      {
        'event_id': cursor == null ? 'new1' : 'old1',
        'sender': '@Case:remote',
        'type': 'm.room.message',
        'content': {'body': 'one'},
        'origin_server_ts': 999999,
      },
      {
        'event_id': cursor == null ? 'new2' : 'old2',
        'sender': '@Case:remote',
        'type': 'm.room.message',
        'content': {'body': 'two'},
        'origin_server_ts': 0,
      },
    ],
    'next_cursor': cursor == null ? 'earlier' : null,
  };
}

class SpaceThreadTransport extends RoomTransport {
  int threadReads = 0;
  @override
  Future<MatrixJson> thread(String room, String event, String? cursor) async {
    threadReads++;
    return {
      'root': {
        'event_id': event,
        'type': 'm.room.message',
        'sender': '@alice:example.org',
        'content': {'body': 'Matrix space chat'},
      },
      'events': <MatrixJson>[],
    };
  }
}

class EchoTransport extends RoomTransport {
  bool delivered = false, departed = false;
  @override
  Future<MatrixJson> sync() async {
    final snapshot = await super.sync();
    if (departed) (snapshot['rooms'] as List).single['membership'] = 'leave';
    return snapshot;
  }

  @override
  Future<MatrixJson> history(String room, String? cursor) async => {
    'events': [
      if (delivered) ...[
        {
          'event_id': r'$remote',
          'sender': '@bob:remote',
          'type': 'm.room.message',
          'origin_server_ts': 9,
          'content': {'body': 'Remote before own', 'msgtype': 'm.text'},
        },
        {
          'event_id': r'$sent',
          'sender': '@alice:example.org',
          'type': 'm.room.message',
          'origin_server_ts': 1,
          'content': {'body': 'Canonical own', 'msgtype': 'm.text'},
        },
      ],
    ],
    'next_cursor': null,
  };
}

Future<RiverApi> connected(
  RoomTransport engine,
  List<http.Request> requests,
) async {
  final storage = MemoryMatrixStorage();
  final namespace = sha256.convert(utf8.encode('https://example.org|alice'));
  storage.values['river_matrix.session.$namespace'] = jsonEncode({
    'user_id': '@alice:example.org',
    'homeserver': 'https://example.org',
    'store': 'test',
    'store_key': 'x' * 43,
    'session': '{}',
  });
  final api = RiverApi(
    live: false,
    matrixEnabled: true,
    matrixStorage: storage,
    matrixFactory: (_) async => engine,
    client: MockClient((request) async {
      requests.add(request);
      if (request.url.path == '/api/overview') {
        return http.Response(
          jsonEncode({
            'groups': [
              {
                'id': 'local',
                'room_id': '!room:remote',
                'name': 'Old name',
                'kind': 'group',
                'membership': 'join',
                'members': [],
              },
            ],
            'recent': [],
          }),
          200,
        );
      }
      return http.Response('{"friends":[],"requests":[],"blocked":[]}', 200);
    }),
  );
  api.user = Map.of(matrixProfile);
  await api.matrix.bind(matrixProfile);
  await api.refresh();
  return api;
}

void main() {
  test(
    'an active conversation follows its verified replacement and retains readable history',
    () async {
      final engine = UpgradeTransport();
      final api = await connected(engine, []);
      await api.open('local');
      engine.upgraded = true;
      await api.matrix.syncNow();
      for (var i = 0; i < 5; i++) {
        await Future<void>.delayed(Duration.zero);
      }
      expect(api.selected, '!replacement:remote');
      await api.send(api.selected!, 'm.room.message', {
        'body': 'after upgrade',
        'msgtype': 'm.text',
      }, 'upgrade');
      expect(engine.sentRooms, ['!replacement:remote']);
      expect(api.group('local')?['name'], startsWith('History:'));
      await api.open('local');
      expect(api.events, isNotEmpty);
      await api.matrix.syncNow();
      expect(
        api.selected,
        'local',
        reason: 'Explicit historical reading must stay on the old room',
      );
      await expectLater(
        api.send('local', 'm.room.message', {'body': 'wrong room'}, 'old'),
        throwsStateError,
      );
      expect(engine.sentRooms, ['!replacement:remote']);
      api.dispose();
    },
  );

  test(
    'pending replacements block messages and files while leaving history readable',
    () async {
      final engine = UpgradeTransport();
      final api = await connected(engine, []);
      await api.open('local');
      engine.pending = true;
      await api.matrix.syncNow();
      expect(api.events, isNotEmpty);
      await expectLater(
        api.send('local', 'm.room.message', {'body': 'pending'}, 'pending'),
        throwsStateError,
      );
      await expectLater(
        api.sendMatrixFile(
          'local',
          'file.bin',
          'application/octet-stream',
          Uint8List(4),
        ),
        throwsStateError,
      );
      expect(engine.sentRooms, isEmpty);
      expect(engine.fileTransactions, isEmpty);
      api.dispose();
    },
  );

  test(
    'acknowledged echoes reconcile in SDK order and departure clears the timeline',
    () async {
      final engine = EchoTransport();
      final api = await connected(engine, []);
      await api.open('local');
      await api.send('local', 'm.room.message', {
        'body': 'Own',
        'msgtype': 'm.text',
      }, 'txn');
      expect(api.events.single['event_id'], r'$sent');
      engine.delivered = true;
      await api.refresh();
      expect(api.events.map((e) => e['event_id']), [r'$remote', r'$sent']);
      expect(api.events.last['content']['body'], 'Canonical own');
      engine.departed = true;
      await api.matrix.syncNow();
      expect(api.selected, isNull);
      expect(api.events, isEmpty);
      api.dispose();
    },
  );

  test('Matrix-only space chat threads use the Matrix transport', () async {
    final engine = SpaceThreadTransport(), requests = <http.Request>[];
    final api = await connected(engine, requests);
    api.group('local')!['kind'] = 'space';
    api.group('local')!['matrix_only'] = true;
    final result = await api.thread('local', r'$chat');
    expect(engine.threadReads, 1);
    expect(result['root']['content']['body'], 'Matrix space chat');
    expect(requests.where((r) => r.url.path.endsWith('/thread')), isEmpty);
    api.dispose();
  });

  test(
    'connected Matrix uses space projections for entry threads and edits',
    () async {
      final requests = <http.Request>[];
      final api = await connected(RoomTransport(), requests);
      api.group('local')!['kind'] = 'space';
      await api.thread('local', r'$discussion');
      expect(requests.last.url.path, '/api/groups/local/thread');
      await api.editEntry(
        'local',
        r'$discussion',
        'Title',
        'Body',
        refreshAfter: false,
      );
      expect(requests.last.url.path, '/api/spaces/local/entry');
      api.dispose();
    },
  );

  test(
    'Matrix-only sync invalidates open views while active and pauses in background',
    () async {
      final api = await connected(RoomTransport(), []);
      final observed = <void>[];
      final subscription = api.changes.stream.listen(observed.add);
      try {
        await api.matrix.syncNow();
        await Future<void>.delayed(Duration.zero);
        expect(
          observed,
          hasLength(1),
          reason:
              'Open thread views must receive Matrix updates without a delegated live event.',
        );
        api.active = false;
        await api.matrix.syncNow();
        await Future<void>.delayed(Duration.zero);
        expect(observed, hasLength(1));
      } finally {
        await subscription.cancel();
        api.dispose();
      }
    },
  );

  test(
    'encrypted send failure cannot fall back to a plaintext delegated request',
    () async {
      final engine = RoomTransport()..failSend = true,
          requests = <http.Request>[];
      final api = await connected(engine, requests);
      await expectLater(
        api.send('local', 'm.room.message', {
          'body': 'secret',
          'msgtype': 'm.text',
        }, 'txn'),
        throwsStateError,
      );
      expect(engine.sends, 1);
      expect(requests.where((r) => r.method != 'GET'), isEmpty);
      await api.matrix.disconnect();
      await expectLater(
        api.send('local', 'm.room.message', {'body': 'secret'}, 'next'),
        throwsStateError,
      );
      expect(requests.where((r) => r.method != 'GET'), isEmpty);
      api.dispose();
    },
  );
  test(
    'remote IDs and SDK DAG ordering survive refresh and earlier pagination',
    () async {
      final api = await connected(RoomTransport(), []);
      expect(
        api.userId('@CaseSensitive:Remote.example:8448'),
        '@CaseSensitive:Remote.example:8448',
      );
      await api.open('local');
      expect(api.events.map((e) => e['event_id']), ['new1', 'new2']);
      await api.older();
      expect(api.events.map((e) => e['event_id']), [
        'old1',
        'old2',
        'new1',
        'new2',
      ]);
      await api.refresh();
      expect(api.events.map((e) => e['event_id']), [
        'old1',
        'old2',
        'new1',
        'new2',
      ]);
      api.dispose();
    },
  );
  test(
    'attachment retries reuse the Matrix transaction without publishing a legacy manifest',
    () async {
      final engine = RoomTransport()..failFile = true,
          requests = <http.Request>[];
      final api = await connected(engine, requests);
      final bytes = Uint8List.fromList([1, 2, 3]);
      await expectLater(
        api.sendMatrixFile('local', 'proof.txt', 'text/plain', bytes),
        throwsStateError,
      );
      await api.sendMatrixFile('local', 'proof.txt', 'text/plain', bytes);
      expect(engine.fileTransactions, hasLength(2));
      expect(engine.fileTransactions.first, engine.fileTransactions.last);
      expect(requests.where((r) => r.method != 'GET'), isEmpty);
      api.dispose();
    },
  );
  test('public post flow is rejected in encrypted rooms', () async {
    final requests = <http.Request>[];
    final api = await connected(RoomTransport(), requests);
    await expectLater(
      api.send('local', 'cool.gravitas.river.post.v1', {
        'body': 'private',
      }, 'post'),
      throwsStateError,
    );
    expect(requests.where((r) => r.method != 'GET'), isEmpty);
    api.dispose();
  });
}

class UpgradeTransport extends RoomTransport {
  bool upgraded = false, pending = false;
  final sentRooms = <String>[];
  @override
  Future<MatrixJson> sync() async {
    final snapshot = await super.sync();
    final old = (snapshot['rooms'] as List).single;
    old['upgrade_pending'] = pending;
    if (upgraded) {
      old['replacement_room'] = '!replacement:remote';
      (snapshot['rooms'] as List).add({
        'room_id': '!replacement:remote',
        'name': 'Encrypted room',
        'kind': 'group',
        'membership': 'join',
        'encrypted': true,
        'parents': [],
      });
    }
    return snapshot;
  }

  @override
  Future<MatrixJson> send(
    String room,
    String type,
    MatrixJson content,
    String txn,
  ) async {
    sentRooms.add(room);
    return super.send(room, type, content, txn);
  }
}
