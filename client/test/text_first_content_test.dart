import 'package:flutter/material.dart';
import 'package:flutter_markdown_plus/flutter_markdown_plus.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:river/api.dart';
import 'package:river/comment_tree.dart';
import 'package:river/content_widgets.dart';
import 'package:river/destination_widgets.dart';
import 'package:river/river_design.dart';

Json writing(String id, String body, {String type = 'm.room.message'}) => {
  'event_id': id,
  'type': type,
  'sender': '@alice:home',
  'origin_server_ts': 1,
  'content': <String, dynamic>{
    'body': body,
    if (type != 'm.room.message') 'title': 'A useful idea',
  },
};

void main() {
  for (final width in [360.0, 1440.0]) {
    testWidgets('text leads and one-line messages stay compact at $width', (
      tester,
    ) async {
      await tester.binding.setSurfaceSize(Size(width, 900));
      addTearDown(() => tester.binding.setSurfaceSize(null));
      final api = RiverApi(live: false)..user = {'user_id': '@reader:home'};
      bool replied = false;
      await tester.pumpWidget(
        MaterialApp(
          theme: riverTheme(),
          home: Scaffold(
            body: Align(
              alignment: Alignment.topLeft,
              child: ContentCard(
                app: api,
                room: 'room',
                event: writing('short', 'Hello there'),
                reply: () => replied = true,
              ),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      final body = find.byKey(const ValueKey('content-body-short'));
      final caption = find.byKey(const ValueKey('content-meta-short'));
      expect(
        tester.getTopLeft(body).dy,
        lessThan(tester.getTopLeft(caption).dy),
      );
      expect(tester.getTopLeft(body).dx, tester.getTopLeft(caption).dx);
      expect(tester.getSize(find.byType(ContentCard)).height, lessThan(60));
      expect(
        tester
            .widget<MarkdownBody>(find.byType(MarkdownBody))
            .styleSheet!
            .p!
            .fontSize,
        16,
      );
      for (final type in [Card, CircleAvatar, FilterChip]) {
        expect(find.byType(type), findsNothing);
      }
      await tester.tap(find.text('Reply'));
      expect(replied, isTrue);
      await tester.tap(find.byTooltip('Add reaction'));
      await tester.pumpAndSettle();
      expect(find.text('👍'), findsOneWidget);
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox());
      api.dispose();
    });
    testWidgets(
      'forum and post overview bodies are readable and not clipped at $width',
      (tester) async {
        await tester.binding.setSurfaceSize(Size(width, 1200));
        addTearDown(() => tester.binding.setSurfaceSize(null));
        for (final destination in ['Forums', 'Posts']) {
          final kind = destination == 'Posts' ? 'post' : 'discussion';
          final api = RiverApi(live: false)
            ..groups = [
              {
                'id': 'space',
                'kind': 'space',
                'name': 'Design',
                'membership': 'join',
              },
            ]
            ..recent = [
              {
                ...writing(
                  'entry',
                  'First paragraph with **clear emphasis**.\n\n${List.filled(6, 'An actual thought that deserves to be read.').join('\n\n')}\n\nThe final paragraph remains visible.',
                  type: 'cool.gravitas.river.$kind.v1',
                ),
                'group_id': 'space',
                'reply_count': 3,
                'publication': {'visibility': 'public'},
              },
            ];
          String? opened;
          await tester.pumpWidget(
            MaterialApp(
              theme: riverTheme(),
              home: Scaffold(
                body: RiverDestinationView(
                  app: api,
                  destination: destination,
                  open: (_) {},
                  create: (_) {},
                  friends: () {},
                  compose: () {},
                  thread: (_, e) => opened = e['event_id'] as String,
                ),
              ),
            ),
          );
          await tester.pumpAndSettle();
          expect(find.byType(EntryPreview), findsOneWidget);
          final preview = find.byType(EntryPreview);
          expect(
            find.descendant(of: preview, matching: find.byType(Card)),
            findsNothing,
          );
          final markdown = tester.widget<MarkdownBody>(
            find.descendant(of: preview, matching: find.byType(MarkdownBody)),
          );
          expect(
            markdown.data,
            contains('The final paragraph remains visible.'),
          );
          expect(markdown.styleSheet!.p!.color, riverInk);
          expect(
            markdown.styleSheet!.p!.fontSize,
            greaterThan(contentMetaStyle.fontSize!),
          );
          final body = find.descendant(
            of: preview,
            matching: find.byType(RichBody),
          );
          final author = find.descendant(
            of: preview,
            matching: find.text('alice'),
          );
          expect(
            tester.getBottomLeft(body).dy,
            lessThan(tester.getTopLeft(author).dy),
          );
          await tester.ensureVisible(find.text('A useful idea'));
          await tester.tap(find.text('A useful idea'));
          expect(opened, 'entry');
          expect(tester.takeException(), isNull);
          await tester.pumpWidget(const SizedBox());
          api.dispose();
        }
      },
    );
  }
  testWidgets(
    'metadata, reactions and long names wrap without constraining the body',
    (tester) async {
      await tester.binding.setSurfaceSize(const Size(360, 1000));
      addTearDown(() => tester.binding.setSurfaceSize(null));
      final api = RiverApi(live: false)
        ..user = {'user_id': '@alice:home', 'username': 'Alice'};
      await tester.pumpWidget(
        MaterialApp(
          theme: riverTheme(),
          home: Scaffold(
            body: MediaQuery(
              data: const MediaQueryData(textScaler: TextScaler.linear(2)),
              child: SingleChildScrollView(
                child: ContentCard(
                  app: api,
                  room: 'room',
                  event: {
                    ...writing(
                      'long',
                      'Readable text at a larger text size.',
                      type: 'cool.gravitas.river.post.v1',
                    ),
                    'edited': true,
                    'publication': {'visibility': 'public'},
                    'reaction_summary': [
                      {'key': '👍', 'count': 12, 'mine': true},
                    ],
                  },
                  audience: 'Community members only',
                  reply: () {},
                ),
              ),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      expect(find.text('Copy public link'), findsOneWidget);
      expect(find.text('Edit'), findsOneWidget);
      expect(find.byTooltip('Remove 👍 reaction'), findsOneWidget);
      expect(find.textContaining('edited'), findsOneWidget);
      expect(tester.getSize(find.byType(RichBody)).width, greaterThan(320));
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox());
      api.dispose();
    },
  );
  testWidgets(
    'nested reply collapse stays in the caption and preserves replies',
    (tester) async {
      final api = RiverApi(live: false)..user = {'user_id': '@reader:home'};
      final parent = writing('parent', 'The parent thought');
      final child = writing('child', 'The reply');
      (child['content'] as Json)['m.relates_to'] = {
        'm.in_reply_to': {'event_id': 'parent'},
      };
      await tester.pumpWidget(
        MaterialApp(
          theme: riverTheme(),
          home: Scaffold(
            body: CommentTree(
              events: [parent, child],
              parentOf: getReplyParent,
              branchBuilder: (e, control) => ContentCard(
                app: api,
                room: 'room',
                event: e,
                threadControl: control,
                reply: () {},
              ),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      final caption = tester.getRect(
        find.byKey(const ValueKey('content-meta-parent')),
      );
      expect(
        caption.contains(
          tester.getCenter(find.byKey(const ValueKey('collapse-parent'))),
        ),
        isTrue,
      );
      await tester.tap(find.byKey(const ValueKey('collapse-parent')));
      await tester.pumpAndSettle();
      expect(find.byKey(const ValueKey('content-body-child')), findsNothing);
      expect(find.byKey(const ValueKey('content-body-parent')), findsOneWidget);
      await tester.tap(find.byKey(const ValueKey('collapse-parent')));
      await tester.pumpAndSettle();
      expect(find.byKey(const ValueKey('content-body-child')), findsOneWidget);
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox());
      api.dispose();
    },
  );
}
