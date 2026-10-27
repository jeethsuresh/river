import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:river/api.dart';
import 'package:river/main.dart';

void main() {
  test(
    'custom entries use the space API and canonical Matrix space ID',
    () async {
      final writes = <http.Request>[];
      final api =
          RiverApi(
              client: MockClient((request) async {
                writes.add(request);
                return http.Response('{"event_id":"entry"}', 200);
              }),
            )
            ..groups = [
              {
                'id': 'space',
                'kind': 'space',
                'room_id': '!space:example.test',
              },
              {'id': 'dm', 'kind': 'dm'},
              {'id': 'group', 'kind': 'group'},
              {'id': 'child', 'kind': 'channel', 'parent_id': 'space'},
            ];
      for (final kind in ['post', 'discussion']) {
        final type = 'cool.gravitas.river.$kind.v1';
        await api.send(
          'space',
          type,
          {'version': 1, 'title': 'Title', 'body': 'Body'},
          kind,
          refreshAfter: false,
        );
        expect(writes.last.url.path, '/api/spaces/space/entries/$type/$kind');
        expect(
          (jsonDecode(writes.last.body) as Json)['content']['space_id'],
          '!space:example.test',
        );
        for (final id in ['dm', 'group', 'child']) {
          await expectLater(
            api.send(
              id,
              type,
              {'body': 'Invalid'},
              'invalid',
              refreshAfter: false,
            ),
            throwsStateError,
          );
          await expectLater(
            api.editEntry(id, 'entry', 'Title', 'Body', refreshAfter: false),
            throwsStateError,
          );
        }
      }
      expect(writes, hasLength(2));
      api.dispose();
    },
  );

  testWidgets(
    'switching from space posts to a conversation always shows chat',
    (tester) async {
      await tester.binding.setSurfaceSize(const Size(1440, 1100));
      addTearDown(() => tester.binding.setSurfaceSize(null));
      final groups = <Json>[
        for (final kind in ['space', 'dm', 'group', 'channel'])
          {
            'id': kind,
            'name': 'Test $kind',
            'kind': kind,
            'membership': 'join',
            'members': <Json>[],
            if (kind == 'channel') 'parent_id': 'space',
          },
      ];
      final api =
          RiverApi(
              client: MockClient(
                (request) async => http.Response(
                  jsonEncode({'events': [], 'next_cursor': null}),
                  200,
                ),
              ),
            )
            ..groups = groups
            ..selected = 'space'
            ..loading = false
            ..user = {
              'sub': 'alice',
              'username': 'alice',
              'user_id': '@alice:example.test',
            };
      await tester.pumpWidget(RiverApp(api: api, boot: false));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Posts'));
      await tester.pumpAndSettle();
      expect(find.text('New post'), findsOneWidget);
      for (final kind in ['dm', 'group', 'channel']) {
        api.selected = kind;
        api.events = [
          {
            'event_id': 'message-$kind',
            'type': 'm.room.message',
            'sender': '@alice:example.test',
            'origin_server_ts': 1,
            'content': {'body': 'Conversation message $kind'},
          },
        ];
        api.notifyListeners();
        await tester.pumpAndSettle();
        expect(find.text('New post'), findsNothing);
        expect(find.byType(SegmentedButton<String>), findsNothing);
        expect(find.text('Conversation message $kind'), findsOneWidget);
      }
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox());
    },
  );
}
