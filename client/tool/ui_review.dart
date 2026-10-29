// Deterministic UI review fixture. Run with --target tool/ui_review.dart.
import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:river/api.dart';
import 'package:river/main.dart';
import 'package:river/matrix_messaging.dart';
import 'package:river/content_widgets.dart';

class ReviewStorage implements MatrixStorage {
  final values = <String, String>{};
  @override
  Future<String?> read(String key) async => values[key];
  @override
  Future<void> write(String key, String value) async {
    values[key] = value;
  }

  @override
  Future<void> delete(String key) async {
    values.remove(key);
  }
}

Json event(
  String id,
  String body, {
  String? parent,
  String? type,
  String? title,
}) => {
  'event_id': id,
  'sender': '@maya:review.invalid',
  'type': type ?? 'm.room.message',
  'origin_server_ts': DateTime(2026, 10, 28, 10, 24).millisecondsSinceEpoch,
  'group_id': 'studio',
  'group_name': 'The studio',
  'reply_count': 0,
  'content': {
    'body': body,
    if (title != null) 'title': title,
    if (parent != null)
      'm.relates_to': {
        'm.in_reply_to': {'event_id': parent},
      },
  },
};
void main() {
  final comments = [
    event(
      'first',
      'I like the lighter navigation. Keeping rooms close to their space makes it much easier to scan.',
    ),
    event(
      'second',
      'Agreed. The voice preview is useful when deciding where to drop in.',
      parent: 'first',
    ),
    event(
      'third',
      'And the text chats can stay in the space, independently of who is in the call.',
      parent: 'second',
    ),
    event(
      'fourth',
      'The compact composer feels much better on a small screen.',
    ),
  ];
  final root = event(
    'discussion',
    'What should we work on together this week?',
    type: 'cool.gravitas.river.discussion.v1',
    title: 'A few ideas for the week',
  );
  final api =
      RiverApi(
          live: false,
          matrixEnabled: false,
          matrixStorage: ReviewStorage(),
          client: MockClient(
            (r) async => http.Response(
              jsonEncode(
                r.url.path.endsWith('/thread')
                    ? {'root': root, 'events': comments, 'next_cursor': null}
                    : {
                        'events': [
                          event(
                            'hello',
                            'Morning! I put the notes for our next project in the studio.',
                          ),
                          event(
                            'response',
                            'Perfect. I’ll have a look before we catch up.',
                          ),
                        ],
                        'next_cursor': null,
                      },
              ),
              200,
              headers: {'content-type': 'application/json'},
            ),
          ),
        )
        ..loading = false
        ..user = {
          'issuer': 'review.invalid',
          'sub': 'alex',
          'username': 'Alex',
          'user_id': '@alex:review.invalid',
        }
        ..friends = [
          {'user_id': '@maya:review.invalid', 'username': 'Maya Chen'},
          {'user_id': '@sam:review.invalid', 'username': 'Sam Rivera'},
          {'user_id': '@jo:review.invalid', 'username': 'Jo Park'},
        ]
        ..online = {'@maya:review.invalid', '@sam:review.invalid'}
        ..groups = [
          {
            'id': 'studio',
            'name': 'The studio',
            'kind': 'space',
            'membership': 'join',
            'owner': true,
            'description': 'A place for our projects, plans and good ideas.',
            'members': <Json>[],
          },
          {
            'id': 'voice',
            'name': 'Kitchen table',
            'kind': 'channel',
            'channel_kind': 'drop_in',
            'parent_id': 'studio',
            'membership': 'join',
            'members': <Json>[],
          },
          {
            'id': 'ideas',
            'name': 'ideas',
            'kind': 'channel',
            'channel_kind': 'text',
            'parent_id': 'studio',
            'membership': 'join',
            'members': <Json>[],
            'unread_count': 3,
          },
          {
            'id': 'planning',
            'name': 'planning',
            'kind': 'channel',
            'channel_kind': 'text',
            'parent_id': 'studio',
            'membership': 'join',
            'members': <Json>[],
          },
          {
            'id': 'garden',
            'name': 'The garden',
            'kind': 'space',
            'membership': 'join',
            'members': <Json>[],
          },
          {
            'id': 'chat',
            'name': 'Maya & Alex',
            'kind': 'dm',
            'membership': 'join',
            'members': <Json>[
              {'user_id': '@maya:review.invalid', 'username': 'Maya Chen'},
            ],
            'unread_count': 2,
            'unread_preview': 'Are we still on for tomorrow?',
          },
          {
            'id': 'weekend',
            'name': 'Weekend plans',
            'kind': 'group',
            'membership': 'join',
            'members': <Json>[],
          },
        ]
        ..activeCalls = [
          {
            'group_id': 'voice',
            'name': 'Kitchen table',
            'participants': [
              {'user_id': '@maya:review.invalid'},
              {'user_id': '@sam:review.invalid'},
            ],
          },
        ]
        ..recent = [
          event(
            'post',
            'A few thoughts and sketches from this week. Let’s compare notes.',
            type: 'cool.gravitas.river.post.v1',
            title: 'Small things worth sharing',
          ),
          root,
        ];
  final view = Uri.base.queryParameters['view'];
  if (view == 'space') api.selected = 'studio';
  if (view == 'chat') {
    api.selected = 'chat';
    api.events = [
      event(
        'hello',
        'Morning! I put the notes for our next project in the studio.',
      ),
      event('response', 'Perfect. I’ll have a look before we catch up.'),
    ];
  }
  if (view == 'thread') {
    runApp(
      MaterialApp(
        theme: ThemeData(
          useMaterial3: true,
          scaffoldBackgroundColor: const Color(0xfff4f7fc),
        ),
        home: ThreadScreen(app: api, room: 'studio', rootId: 'discussion'),
      ),
    );
  } else {
    runApp(RiverApp(api: api, boot: false));
  }
}
