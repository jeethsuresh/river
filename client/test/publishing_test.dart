import 'dart:convert';
import 'package:flutter/material.dart';
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
}
