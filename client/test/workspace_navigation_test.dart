import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:river/api.dart';
import 'package:river/content_widgets.dart';
import 'package:river/publishing_widgets.dart';
import 'package:river/workspace_widgets.dart';

void main() {
  test('conversation search includes member names and IDs', () {
    final group = <String, dynamic>{
      'name': 'Planning',
      'members': [
        {'username': 'Alice', 'user_id': '@alice:gravitas.cool'},
      ],
    };
    for (final query in ['', 'plan', 'ALICE', '@alice:gravitas.cool']) {
      expect(conversationMatches(group, query), isTrue);
    }
    expect(conversationMatches(group, 'unrelated'), isFalse);
  });
  testWidgets(
    'channel navigation exposes, collapses and opens the correct threads and occupancy',
    (tester) async {
      final app = RiverApi(live: false)
        ..groups = [
          {
            'id': 'text',
            'parent_id': 'space',
            'channel_kind': 'text',
            'name': 'Projects',
          },
          {
            'id': 'voice',
            'parent_id': 'space',
            'channel_kind': 'drop_in',
            'name': 'Lounge',
          },
        ]
        ..threads = [
          {
            'group_id': 'text',
            'event_id': r'$root',
            'content': {'body': 'My active project'},
            'reply_count': 3,
          },
          {
            'group_id': 'other',
            'event_id': r'$secret',
            'content': {'body': 'Other space thread'},
            'reply_count': 1,
          },
        ]
        ..activeCalls = [
          {
            'group_id': 'voice',
            'participants': [
              {'user_id': 'alice'},
              {'user_id': 'bob'},
            ],
          },
        ];
      Json? openedThread;
      String? openedRoom;
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: SpaceChannels(
              app: app,
              space: 'space',
              open: (id) => openedRoom = id,
              thread: (event) => openedThread = event,
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      expect(find.text('My active project'), findsOneWidget);
      expect(find.text('Other space thread'), findsNothing);
      expect(find.text('2 people here'), findsOneWidget);
      await tester.tap(find.text('My active project'));
      expect(openedThread?['event_id'], r'$root');
      await tester.tap(find.byTooltip('Collapse replies in Projects'));
      await tester.pumpAndSettle();
      expect(find.text('My active project'), findsNothing);
      await tester.tap(find.byTooltip('Expand replies in Projects'));
      await tester.pumpAndSettle();
      expect(find.text('My active project'), findsOneWidget);
      await tester.tap(find.text('Lounge'));
      expect(openedRoom, 'voice');
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox());
      app.dispose();
    },
  );
  for (final kind in ['post', 'discussion']) {
    testWidgets(
      '$kind detail acknowledges its entry from every navigation path',
      (tester) async {
        final reads = <Json>[];
        final event = <String, dynamic>{
          'event_id': r'$entry',
          'type': 'cool.gravitas.river.$kind.v1',
          'sender': '@alice:gravitas.cool',
          'origin_server_ts': 1,
          'content': {'title': 'Title', 'body': 'Body'},
        };
        final app =
            RiverApi(
                client: MockClient((request) async {
                  if (request.url.path.endsWith('/entry/read')) {
                    reads.add(jsonDecode(request.body) as Json);
                    return http.Response('{}', 200);
                  }
                  return http.Response(
                    jsonEncode(
                      kind == 'post'
                          ? {
                              'entry': event,
                              'space': {'id': 'space', 'name': 'Space'},
                              'member': true,
                              'can_comment': false,
                              'can_view_comments': true,
                              'comments': [],
                              'reaction_summary': [],
                              'publication': {
                                'visibility': 'members',
                                'comments_policy': 'members',
                              },
                            }
                          : {'root': event, 'events': [], 'next_cursor': null},
                    ),
                    200,
                  );
                }),
              )
              ..user = {'user_id': '@reader:gravitas.cool'}
              ..catchUp = [event];
        await tester.pumpWidget(
          MaterialApp(
            home: kind == 'post'
                ? PostScreen(app: app, event: r'$entry')
                : ThreadScreen(app: app, room: 'space', rootId: r'$entry'),
          ),
        );
        await tester.pumpAndSettle();
        expect(reads.single['event_id'], r'$entry');
        expect(app.catchUp, isEmpty);
        await tester.pumpWidget(const SizedBox());
        app.dispose();
      },
    );
  }
  testWidgets('post card reactions use the canonical publication endpoint', (
    tester,
  ) async {
    String? path;
    final app = RiverApi(
      client: MockClient((request) async {
        path = request.url.path;
        return http.Response('{}', 200);
      }),
    )..user = {'user_id': '@reader:gravitas.cool'};
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: ContentCard(
            app: app,
            room: 'space',
            event: {
              'event_id': r'$post',
              'type': 'cool.gravitas.river.post.v1',
              'sender': '@author:gravitas.cool',
              'origin_server_ts': 1,
              'content': {'title': 'Post', 'body': 'Body'},
              'reaction_summary': [
                {'key': '👍', 'count': 1, 'mine': false},
              ],
            },
            reply: () {},
            changed: () async {},
          ),
        ),
      ),
    );
    await tester.tap(find.byTooltip('React 👍'));
    await tester.pumpAndSettle();
    expect(path, '/api/posts/%24post/reactions');
    await tester.pumpWidget(const SizedBox());
    app.dispose();
  });
}
