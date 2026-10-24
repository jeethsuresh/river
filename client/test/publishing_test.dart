import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:river/api.dart';
import 'package:river/publishing_widgets.dart';

void main() {
  for (final width in [360.0, 768.0, 1440.0]) {
    testWidgets(
      'public post respects comment visibility on refresh at width $width',
      (tester) async {
        await tester.binding.setSurfaceSize(Size(width, 1000));
        addTearDown(() => tester.binding.setSurfaceSize(null));
        bool visible = true;
        final api = RiverApi(
          client: MockClient(
            (r) async => http.Response(
              jsonEncode({
                'entry': {
                  'event_id': r'$river_post',
                  'type': 'cool.gravitas.river.post.v1',
                  'sender': '@author:gravitas.cool',
                  'origin_server_ts': 100,
                  'content': {
                    'title': 'Published post',
                    'body': 'A public **post**',
                  },
                },
                'space': {
                  'id': '11111111-1111-4111-8111-111111111111',
                  'name': 'Public blog',
                },
                'publication': {
                  'visibility': 'public',
                  'comments_policy': visible ? 'public' : 'members',
                  'anchor_id': r'$anchor',
                },
                'member': false,
                'can_comment': false,
                'can_view_comments': visible,
                'next_cursor': null,
                'reaction_summary': [],
                'comments': visible
                    ? [
                        {
                          'event_id': r'$comment',
                          'type': 'm.room.message',
                          'sender': '@reader:gravitas.cool',
                          'origin_server_ts': 200,
                          'content': {'body': 'Public conversation'},
                          'audience': 'public',
                          'comment_room':
                              '11111111-1111-4111-8111-111111111112',
                        },
                      ]
                    : [],
              }),
              200,
              headers: {'content-type': 'application/json'},
            ),
          ),
        );
        await tester.pumpWidget(
          MaterialApp(
            home: PostScreen(app: api, event: r'$river_post'),
          ),
        );
        await tester.pumpAndSettle();
        expect(find.text('Published post'), findsOneWidget);
        expect(find.text('Public conversation'), findsOneWidget);
        expect(tester.takeException(), isNull);
        visible = false;
        await tester.tap(find.byTooltip('Refresh post'));
        await tester.pumpAndSettle();
        expect(find.text('Public conversation'), findsNothing);
        expect(
          find.text('Only space members can see these comments.'),
          findsOneWidget,
        );
        expect(tester.takeException(), isNull);
        await tester.pumpWidget(const SizedBox());
        api.dispose();
      },
    );
  }
  testWidgets(
    'format toolbar surrounds the selection and keeps selection useful',
    (tester) async {
      final controller = TextEditingController(text: 'selected text')
        ..selection = const TextSelection(baseOffset: 0, extentOffset: 8);
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(body: MarkdownToolbar(controller: controller)),
        ),
      );
      await tester.tap(find.byTooltip('Bold'));
      expect(controller.text, '**selected** text');
      expect(
        controller.selection,
        const TextSelection(baseOffset: 2, extentOffset: 10),
      );
      controller.dispose();
    },
  );
  testWidgets('a member draft keeps its audience after a policy refresh', (tester) async {
    var policy = 'members';
    String? submitted;
    final api = RiverApi(client: MockClient((request) async {
      if (request.method == 'POST') {
        submitted = (jsonDecode(request.body) as Json)['audience'] as String;
        return http.Response('{}', 200);
      }
      return http.Response(jsonEncode({
        'entry': {'event_id': r'$post', 'sender': '@author:gravitas.cool', 'type': 'cool.gravitas.river.post.v1', 'content': {'title': 'Post', 'body': 'Body'}},
        'space': {'id': 'space', 'name': 'Space'},
        'publication': {'visibility': 'public', 'comments_policy': policy},
        'member': true, 'can_comment': true, 'can_view_comments': true,
        'comments': [], 'reaction_summary': [], 'next_cursor': null,
      }), 200);
    }))..user = {'user_id': '@reader:gravitas.cool'};
    await tester.pumpWidget(MaterialApp(home: PostScreen(app: api, event: r'$post')));
    await tester.pumpAndSettle();
    await tester.enterText(find.byType(TextField), 'Private draft');
    policy = 'public';
    await tester.tap(find.byTooltip('Refresh post'));
    await tester.pumpAndSettle();
    expect(find.text('Your reply is visible to space members.'), findsOneWidget);
    await tester.tap(find.byTooltip('Send comment'));
    await tester.pumpAndSettle();
    expect(submitted, 'members');
    await tester.pumpWidget(const SizedBox());
    api.dispose();
  });

  testWidgets('keyboard formatting and preview work in shared composers', (tester) async {
    final controller = TextEditingController(text: 'format me');
    await tester.pumpWidget(MaterialApp(home: Scaffold(body: Column(children: [
      MarkdownToolbar(controller: controller),
      MarkdownShortcuts(controller: controller, child: TextField(controller: controller)),
    ]))));
    await tester.tap(find.byType(TextField));
    controller.selection = const TextSelection(baseOffset: 0, extentOffset: 6);
    await tester.sendKeyDownEvent(LogicalKeyboardKey.controlLeft);
    await tester.sendKeyEvent(LogicalKeyboardKey.keyB);
    await tester.sendKeyUpEvent(LogicalKeyboardKey.controlLeft);
    expect(controller.text, '**format** me');
    await tester.tap(find.byTooltip('Preview formatting'));
    await tester.pumpAndSettle();
    expect(find.text('Preview'), findsOneWidget);
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox());
    controller.dispose();
  });

}
