import 'dart:async';
import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:river/api.dart';
import 'package:river/main.dart';
import 'package:river/friends_view.dart';

const rootId = '11111111-1111-4111-8111-111111111111';
const childId = '22222222-2222-4222-8222-222222222222';
Json event(String id, String body, int time) => {
  'event_id': id,
  'type': 'm.room.message',
  'sender': '@bob:gravitas.cool',
  'origin_server_ts': time,
  'content': {'body': body},
};
final alice = <String, dynamic>{
  'sub': 'alice',
  'username': 'alice',
  'domain': 'gravitas.cool',
  'user_id': '@alice:gravitas.cool',
};
final bob = <String, dynamic>{
  'principal_id': 'bob',
  'username': 'bob',
  'user_id': '@bob:gravitas.cool',
};
Json room(String id, String name, {String kind = 'space', String? parent}) => {
  'id': id,
  'name': name,
  'kind': kind,
  'parent_id': parent,
  'channel_kind': parent == null ? null : 'text',
  'membership': 'join',
  'owner': true,
  'members': <Json>[],
  'unread_count': 2,
};
http.Response response(Json data, [int status = 200]) => http.Response(
  jsonEncode(data),
  status,
  headers: {'content-type': 'application/json'},
);

void main() {
  testWidgets(
    'friend request dialog canonicalizes username and displays outgoing request',
    (tester) async {
      final social = <Json>[];
      final api =
          RiverApi(
              client: MockClient((r) async {
                if (r.url.path == '/api/overview') {
                  return response({'groups': [], 'recent': []});
                }
                if (r.url.path == '/api/friends') {
                  if (r.method == 'POST') {
                    expect(r.headers['X-Gravitas-CSRF'], '1');
                    final data = jsonDecode(r.body) as Json;
                    expect(data['action'], 'request');
                    expect(data['user_id'], '@bob:gravitas.cool');
                    expect(data['txn_id'], isNotEmpty);
                    social.add({...bob, 'direction': 'outgoing'});
                    return response({'ok': true});
                  }
                  return response({
                    'friends': [],
                    'requests': social,
                    'blocked': [],
                  });
                }
                return response({'error': 'not_found'}, 404);
              }),
            )
            ..user = alice
            ..loading = false;
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: AnimatedBuilder(
              animation: api,
              builder: (_, _) => FriendsView(app: api, onConversation: () {}),
            ),
          ),
        ),
      );
      await tester.tap(find.text('Add a friend'));
      await tester.pumpAndSettle();
      await tester.enterText(
        find.widgetWithText(TextField, 'Gravitas username'),
        'Bob',
      );
      await tester.tap(find.text('Send request'));
      await tester.pumpAndSettle();
      expect(find.text('bob'), findsOneWidget);
      expect(find.text('Cancel request'), findsOneWidget);
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox());
      api.dispose();
    },
  );

  testWidgets(
    'accept and message friend use real client requests on phone, tablet and desktop',
    (tester) async {
      for (final width in [390.0, 768.0, 1440.0]) {
        await tester.binding.setSurfaceSize(Size(width, 1100));
        bool accepted = false, opened = false;
        final api =
            RiverApi(
                client: MockClient((r) async {
                  if (r.url.path == '/api/overview') {
                    return response({'groups': [], 'recent': []});
                  }
                  if (r.url.path == '/api/friends' && r.method == 'POST') {
                    final p = jsonDecode(r.body) as Json;
                    expect(p['action'], 'accept');
                    accepted = true;
                    return response({'ok': true});
                  }
                  if (r.url.path == '/api/friends') {
                    return response({
                      'friends': accepted ? [bob] : [],
                      'requests': accepted
                          ? []
                          : [
                              {...bob, 'direction': 'incoming'},
                            ],
                      'blocked': [],
                    });
                  }
                  if (r.url.path == '/api/direct') {
                    expect(
                      (jsonDecode(r.body) as Json)['user_id'],
                      bob['user_id'],
                    );
                    opened = true;
                    return response({'id': childId});
                  }
                  return response({'error': 'not_found'}, 404);
                }),
              )
              ..user = alice
              ..loading = false
              ..requests = [
                {...bob, 'direction': 'incoming'},
              ];
        await tester.pumpWidget(
          MaterialApp(
            home: Scaffold(
              body: AnimatedBuilder(
                animation: api,
                builder: (_, _) => FriendsView(app: api, onConversation: () {}),
              ),
            ),
          ),
        );
        await tester.tap(find.text('Accept'));
        await tester.pumpAndSettle();
        expect(accepted, isTrue);
        await tester.ensureVisible(find.text('Message'));
        await tester.tap(find.text('Message'));
        await tester.pumpAndSettle();
        expect(opened, isTrue);
        expect(tester.takeException(), isNull);
        await tester.pumpWidget(const SizedBox());
        api.dispose();
      }
      await tester.binding.setSurfaceSize(null);
    },
  );

  testWidgets(
    'drawer channel navigation closes drawer and sends to the selected room',
    (tester) async {
      await tester.binding.setSurfaceSize(const Size(390, 1000));
      final groups = [
        room(rootId, 'Family'),
        room(childId, 'plans', kind: 'channel', parent: rootId),
      ];
      String? sentTo;
      final timeline = <Json>[];
      final api =
          RiverApi(
              client: MockClient((r) async {
                if (r.url.path == '/api/overview') {
                  return response({'groups': groups, 'recent': []});
                }
                if (r.url.path == '/api/friends') {
                  return response({
                    'friends': [],
                    'requests': [],
                    'blocked': [],
                  });
                }
                if (r.url.path.contains('/events/') && r.method == 'PUT') {
                  sentTo = r.url.path;
                  timeline.add(
                    event(
                      'new',
                      (jsonDecode(r.body) as Json)['content']['body'] as String,
                      2,
                    ),
                  );
                  return response({'event_id': 'new'});
                }
                if (r.url.path.endsWith('/events')) {
                  return response({'events': timeline, 'next_cursor': null});
                }
                if (r.url.path.endsWith('/read')) return response({'ok': true});
                return response({'error': 'not_found'}, 404);
              }),
            )
            ..user = alice
            ..loading = false
            ..groups = groups;
      await tester.pumpWidget(RiverApp(api: api, boot: false));
      await tester.tap(find.byTooltip('Open navigation menu'));
      await tester.pumpAndSettle();
      await tester.tap(
        find.descendant(of: find.byType(Drawer), matching: find.text('plans')),
      );
      await tester.pumpAndSettle();
      expect(api.selected, childId);
      expect(find.text('Back to space'), findsOneWidget);
      expect(find.byType(Drawer), findsNothing);
      await tester.tap(find.text('Markdown'));
      await tester.pumpAndSettle();
      await tester.enterText(find.byType(TextField).last, 'Meet tomorrow');
      await tester.tap(find.byTooltip('Send'));
      await tester.pumpAndSettle();
      expect(sentTo, contains('/groups/$childId/events/m.room.message/'));
      expect(find.text('Meet tomorrow'), findsOneWidget);
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox());
      await tester.binding.setSurfaceSize(null);
    },
  );

  test(
    'pagination keeps loaded history through refresh and does not duplicate events',
    () async {
      final recent = [event('b', 'newer', 2), event('c', 'latest', 3)];
      final api = RiverApi(
        client: MockClient((r) async {
          if (r.url.path == '/api/overview') {
            return response({
              'groups': [
                room(childId, 'plans', kind: 'channel', parent: rootId),
              ],
              'recent': [],
            });
          }
          if (r.url.path == '/api/friends') {
            return response({'friends': [], 'requests': [], 'blocked': []});
          }
          if (r.url.path.endsWith('/read')) return response({'ok': true});
          if (r.url.queryParameters['before'] != null) {
            expect(r.url.queryParameters['before'], 'b');
            return response({
              'events': [event('a', 'earlier', 1)],
              'next_cursor': null,
            });
          }
          return response({'events': recent, 'next_cursor': 'b'});
        }),
      )..user = alice;
      await api.open(childId);
      expect(api.nextCursor, 'b');
      await api.older();
      await api.refresh();
      expect(api.events.map((e) => e['event_id']), ['a', 'b', 'c']);
      expect(api.nextCursor, isNull);
      api.dispose();
    },
  );

  test(
    'a late response cannot populate another account or sign it out',
    () async {
      final old = Completer<http.Response>();
      final api = RiverApi(client: MockClient((r) => old.future))..user = alice;
      final pending = api.request('/api/friends');
      api.user = {'sub': 'bob'};
      old.complete(response({'error': 'revoked'}, 401));
      await expectLater(
        pending,
        throwsA(
          isA<ApiException>().having((e) => e.code, 'code', 'session_changed'),
        ),
      );
      expect(api.user?['sub'], 'bob');
      api.dispose();
    },
  );

  test(
    'insufficient new consent keeps chat usable and clears private social data',
    () async {
      final api =
          RiverApi(
              client: MockClient((r) async {
                if (r.url.path == '/api/overview') {
                  return response({
                    'groups': [room(rootId, 'Family')],
                    'recent': [],
                  });
                }
                return response({'error': 'insufficient_scope'}, 403);
              }),
            )
            ..user = alice
            ..friends = [bob]
            ..otherContacts = [
              {...bob, 'username': 'carol'},
            ];
      await api.refresh();
      expect(api.groups, hasLength(1));
      expect(api.friends, isEmpty);
      expect(api.friendsStatus, 403);
      expect(api.otherContacts, isEmpty);
      expect(api.error, isNull);
      api.dispose();
    },
  );
  testWidgets(
    'timeline opens at latest and new arrivals preserve an older scroll position',
    (tester) async {
      await tester.binding.setSurfaceSize(const Size(390, 900));
      final reads = <String>[];
      final api =
          RiverApi(
              client: MockClient((r) async {
                if (r.url.path.endsWith('/read')) {
                  reads.add((jsonDecode(r.body) as Json)['event_id'] as String);
                }
                return response({'ok': true});
              }),
            )
            ..user = alice
            ..loading = false
            ..groups = [room(childId, 'plans', kind: 'channel', parent: rootId)]
            ..selected = childId;
      api.events = List.generate(30, (i) => event('m$i', 'Message $i', i));
      await tester.pumpWidget(RiverApp(api: api, boot: false));
      await tester.pumpAndSettle();
      expect(find.text('Message 29'), findsOneWidget);
      expect(reads.last, 'm29');
      await tester.drag(find.byType(ListView).last, const Offset(0, 650));
      await tester.pumpAndSettle();
      final before = reads.length;
      api.events = [...api.events, event('newest', 'Newest arrival', 31)];
      api.notifyListeners();
      await tester.pumpAndSettle();
      expect(find.text('New messages'), findsOneWidget);
      expect(reads.length, before);
      await tester.tap(find.text('New messages'));
      await tester.pumpAndSettle();
      expect(find.text('Newest arrival'), findsOneWidget);
      expect(reads.last, 'newest');
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox());
      await tester.binding.setSurfaceSize(null);
    },
  );
}
