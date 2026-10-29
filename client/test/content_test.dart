import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:river/api.dart';
import 'package:river/content_widgets.dart';
import 'package:river/main.dart';

const roomId = '11111111-1111-4111-8111-111111111111';
final person = <String, dynamic>{
  'sub': 'alice',
  'username': 'alice',
  'user_id': '@alice:gravitas.cool',
};
Json message(String id, String body, {Json? relation}) => {
  'event_id': id,
  'type': 'm.room.message',
  'sender': '@alice:gravitas.cool',
  'origin_server_ts': 100,
  'content': {'body': body, if (relation != null) 'm.relates_to': relation},
};
final group = <String, dynamic>{
  'id': roomId,
  'name': 'Content space',
  'kind': 'space',
  'membership': 'join',
  'owner': true,
  'members': <Json>[],
};
http.Response response(Json data, [int status = 200]) => http.Response(
  jsonEncode(data),
  status,
  headers: {'content-type': 'application/json'},
);

void main() {
  testWidgets(
    'thread routes keep replies separate and send canonical root plus quoted parent',
    (tester) async {
      final semantics = tester.ensureSemantics();
      await tester.binding.setSurfaceSize(const Size(1200, 1100));
      final root = message(r'$root', 'Root message');
      final first = message(
        r'$first',
        'First reply',
        relation: {
          'rel_type': 'm.thread',
          'event_id': r'$root',
          'm.in_reply_to': {'event_id': r'$root'},
        },
      );
      Json? sent;
      final api =
          RiverApi(
              client: MockClient((r) async {
                if (r.url.path.endsWith('/thread')) {
                  expect(r.url.queryParameters['event_id'], r'$root');
                  return response({
                    'root': {...root, 'reply_count': sent == null ? 1 : 2},
                    'events': [
                      first,
                      if (sent != null)
                        {
                          ...message(r'$new', 'Nested reply'),
                          'content': sent!['content'],
                        },
                    ],
                    'next_cursor': null,
                  });
                }
                if (r.method == 'PUT') {
                  sent = jsonDecode(r.body) as Json;
                  return response({'event_id': r'$new'});
                }
                if (r.url.path == '/api/overview') {
                  return response({
                    'groups': [group],
                    'recent': [],
                  });
                }
                if (r.url.path == '/api/friends') {
                  return response({
                    'friends': [],
                    'requests': [],
                    'blocked': [],
                  });
                }
                return response({
                  'events': [root, first],
                  'next_cursor': null,
                });
              }),
            )
            ..user = person
            ..loading = false
            ..groups = [
              {...group, 'kind': 'group'},
            ]
            ..selected = roomId
            ..events = [root, first];
      await tester.pumpWidget(RiverApp(api: api, boot: false));
      await tester.pumpAndSettle();
      expect(find.byType(ContentCard), findsOneWidget);
      expect(find.bySemanticsLabel(RegExp('Root message')), findsWidgets);
      await tester.tap(find.text('Reply'));
      await tester.pumpAndSettle();
      expect(find.text('Thread'), findsOneWidget);
      expect(find.byType(ContentCard), findsNWidgets(2));
      final firstCard = find.byWidgetPredicate(
        (w) => w is ContentCard && w.event['event_id'] == r'$first',
      );
      await tester.ensureVisible(firstCard);
      await tester.tap(
        find.descendant(of: firstCard, matching: find.text('Reply')),
      );
      await tester.pumpAndSettle();
      await tester.ensureVisible(find.text('Markdown').last);
      await tester.tap(find.text('Markdown').last);
      await tester.pumpAndSettle();
      await tester.enterText(find.byType(TextField).last, 'Nested reply');
      await tester.tap(find.byTooltip('Send reply'));
      await tester.pumpAndSettle();
      final relation = (sent!['content'] as Json)['m.relates_to'] as Json;
      expect(relation['rel_type'], 'm.thread');
      expect(relation['event_id'], r'$root');
      expect((relation['m.in_reply_to'] as Json)['event_id'], r'$first');
      expect(find.byType(ContentCard), findsNWidgets(3));
      api.user = {'sub': 'bob', 'username': 'bob'};
      api.events = [];
      api.groups = [];
      api.selected = null;
      api.notifyListeners();
      await tester.pumpAndSettle();
      expect(find.text('Thread'), findsNothing);
      expect(find.byType(ContentCard), findsNothing);
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox());
      await tester.binding.setSurfaceSize(null);
      semantics.dispose();
    },
  );

  testWidgets(
    'reaction removal uses explicit desired state and retries the same transaction after failure',
    (tester) async {
      final root = {
        ...message(r'$root', 'React to this'),
        'reaction_summary': [
          {'key': '👍', 'count': 1, 'mine': true},
        ],
      };
      final requests = <Json>[];
      final api = RiverApi(
        client: MockClient((r) async {
          if (r.url.path.endsWith('/reactions')) {
            requests.add(jsonDecode(r.body) as Json);
            return requests.length == 1
                ? response({'error': 'unavailable'}, 503)
                : response({'ok': true});
          }
          if (r.url.path == '/api/overview') {
            return response({
              'groups': [group],
              'recent': [],
            });
          }
          if (r.url.path == '/api/friends') {
            return response({'friends': [], 'requests': [], 'blocked': []});
          }
          return response({
            'events': [root],
          });
        }),
      )..user = person;
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: ContentCard(
              app: api,
              room: roomId,
              event: root,
              reply: () {},
            ),
          ),
        ),
      );
      await tester.tap(find.byTooltip('Remove 👍 reaction'));
      await tester.pumpAndSettle();
      await tester.tap(find.byTooltip('Remove 👍 reaction'));
      await tester.pumpAndSettle();
      expect(requests, hasLength(2));
      expect(requests[0]['active'], false);
      expect(requests[0]['event_id'], r'$root');
      expect(requests[0]['txn_id'], requests[1]['txn_id']);
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox());
      api.dispose();
    },
  );

  testWidgets(
    'entry editing keeps failed drafts and renders safely across phone tablet and desktop',
    (tester) async {
      for (final width in [390.0, 768.0, 1440.0]) {
        await tester.binding.setSurfaceSize(Size(width, 1100));
        final edits = <Json>[];
        final post = {
          ...message(r'$post', 'Original'),
          'type': 'cool.gravitas.river.post.v1',
          'content': {'title': 'Original title', 'body': 'Original'},
        };
        final api = RiverApi(
          client: MockClient((r) async {
            if (r.url.path.endsWith('/entry')) {
              edits.add(jsonDecode(r.body) as Json);
              return response({'error': 'unavailable'}, 503);
            }
            return response({'groups': [], 'recent': []});
          }),
        )..user = person;
        api.groups = [group];
        await tester.pumpWidget(
          MaterialApp(
            home: Scaffold(
              body: Builder(
                builder: (context) => TextButton(
                  onPressed: () => showDialog<void>(
                    context: context,
                    builder: (_) =>
                        EntryEditor(app: api, room: roomId, entry: post),
                  ),
                  child: const Text('Open editor'),
                ),
              ),
            ),
          ),
        );
        await tester.tap(find.text('Open editor'));
        await tester.pumpAndSettle();
        await tester.enterText(
          find.widgetWithText(TextFormField, 'Title'),
          'Changed title',
        );
        await tester.ensureVisible(find.text('Markdown'));
        await tester.tap(find.text('Markdown'));
        await tester.pumpAndSettle();
        await tester.enterText(
          find.widgetWithText(TextField, 'Body'),
          '**Formatted body**',
        );
        await tester.ensureVisible(find.text('Preview'));
        await tester.tap(find.text('Preview'));
        await tester.pumpAndSettle();
        expect(find.byType(RichBody), findsOneWidget);
        await tester.tap(find.text('Save changes'));
        await tester.pumpAndSettle();
        expect(find.textContaining('Your draft is kept'), findsOneWidget);
        await tester.ensureVisible(find.text('Markdown'));
        await tester.tap(find.text('Markdown'));
        await tester.pumpAndSettle();
        expect(
          find.widgetWithText(TextFormField, 'Changed title'),
          findsOneWidget,
        );
        expect(
          find.widgetWithText(TextField, '**Formatted body**'),
          findsOneWidget,
        );
        await tester.tap(find.text('Save changes'));
        await tester.pumpAndSettle();
        expect(edits[0]['txn_id'], edits[1]['txn_id']);
        expect(edits[0]['event_id'], r'$post');
        expect(tester.takeException(), isNull);
        await tester.pumpWidget(const SizedBox());
        api.dispose();
      }
      await tester.binding.setSurfaceSize(null);
    },
  );

  testWidgets('untrusted Markdown never loads local or executable images', (
    tester,
  ) async {
    await tester.pumpWidget(
      const MaterialApp(
        home: Scaffold(
          body: RichBody(
            '![file](file:///private/secret)\n\n![asset](assets/secret.png)\n\n![data](data:image/png;base64,AA)',
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    expect(find.byType(Image), findsNothing);
    expect(find.text('Unsupported image link'), findsNWidgets(3));
    expect(tester.takeException(), isNull);
  });
}
