import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:river/api.dart';
import 'package:river/main.dart';
import 'package:river/destination_widgets.dart';
import 'package:river/content_widgets.dart';
import 'package:river/rich_composer.dart';
import 'package:river/workspace_widgets.dart';
import 'matrix_messaging_test.dart' show MemoryMatrixStorage;
import 'ui_refresh_test.dart' show ReviewRoom;

Json room(
  String id,
  String kind, {
  String? parent,
  bool matrix = false,
  bool encrypted = false,
}) => {
  'id': id,
  'kind': kind,
  'name': id,
  'membership': 'join',
  'members': <Json>[],
  if (parent != null) 'parent_id': parent,
  if (kind == 'channel') 'channel_kind': 'text',
  'matrix_only': matrix,
  'encrypted': encrypted,
};
Json entry(String id, String kind, String group, {String? audience}) => {
  'event_id': id,
  'group_id': group,
  'group_name': group,
  'type': 'cool.gravitas.river.$kind.v1',
  'sender': '@sam:home',
  'origin_server_ts': 100,
  'content': {'title': id, 'body': 'A thoughtful update'},
  'reply_count': 4,
  if (audience != null) 'publication': {'visibility': audience},
};
RiverApi fixture() =>
    RiverApi(
        live: false,
        matrixStorage: MemoryMatrixStorage(),
        client: MockClient(
          (r) async => http.Response(
            jsonEncode({'events': [], 'next_cursor': null}),
            200,
          ),
        ),
      )
      ..loading = false
      ..user = {'sub': 'alex', 'username': 'Alex', 'user_id': '@alex:home'}
      ..groups = [
        {
          ...room('Weekend plans', 'dm'),
          'unread_count': 3,
          'unread_preview': 'Saturday works for me',
        },
        room('Study group', 'group'),
        room('Design collective', 'space'),
        room('general', 'channel', parent: 'Design collective'),
        room('Private community', 'space', encrypted: true),
        room('Open source', 'space', matrix: true),
        room('Matrix project', 'channel', parent: 'Open source'),
        room('External friend', 'dm', matrix: true),
        {...room('Left community', 'space'), 'membership': 'leave'},
      ]
      ..recent = [
        entry(
          'What makes a great shared space?',
          'discussion',
          'Design collective',
        ),
        entry(
          'October field notes',
          'post',
          'Design collective',
          audience: 'public',
        ),
        entry(
          'Members update',
          'post',
          'Design collective',
          audience: 'members',
        ),
        entry('Hidden left post', 'post', 'Left community'),
        entry('Hidden Matrix post', 'post', 'Open source'),
      ];

Future<void> destination(WidgetTester tester, String name, double width) async {
  await tester.tap(
    find.byKey(ValueKey('${width < 1000 ? 'mobile' : 'destination'}-$name')),
  );
  await tester.pumpAndSettle();
}

void main() {
  test(
    'room classification separates River chats, communities and external rooms',
    () {
      final app = fixture();
      expect(destinationGroups(app, 'Chats').map((g) => g['id']), [
        'Study group',
        'Weekend plans',
      ]);
      expect(destinationGroups(app, 'Communities').map((g) => g['id']), [
        'Design collective',
        'Private community',
      ]);
      expect(destinationGroups(app, 'Matrix').map((g) => g['id']), [
        'External friend',
        'Open source',
      ]);
      for (final name in ['Forums', 'Posts']) {
        expect(destinationGroups(app, name).map((g) => g['id']), [
          'Design collective',
        ]);
      }
      expect(roomDestination(app, app.group('Matrix project')!), 'Matrix');
      app.dispose();
    },
  );
  for (final width in [360.0, 768.0, 1440.0]) {
    testWidgets('five destinations show focused content at $width', (
      tester,
    ) async {
      await tester.binding.setSurfaceSize(Size(width, 1000));
      addTearDown(() => tester.binding.setSurfaceSize(null));
      final app = fixture();
      await tester.pumpWidget(RiverApp(api: app, boot: false));
      await tester.pumpAndSettle();
      for (final name in [
        'Chats',
        'Communities',
        'Forums',
        'Posts',
        'Matrix',
      ]) {
        await destination(tester, name, width);
        expect(app.selected, isNull);
        expect(
          tester
              .widget<RiverDestinationView>(find.byType(RiverDestinationView))
              .destination,
          name,
        );
        if (name == 'Chats') {
          expect(find.text('Weekend plans'), findsWidgets);
          expect(find.text('External friend'), findsNothing);
          await tester.tap(find.widgetWithText(FilterChip, 'Unread'));
          await tester.pumpAndSettle();
          expect(
            find.descendant(
              of: find.byType(RiverDestinationView),
              matching: find.text('Study group'),
            ),
            findsNothing,
          );
          await tester.enterText(
            find.byKey(const ValueKey('search-Chats')),
            'missing',
          );
          await tester.pumpAndSettle();
          expect(find.text('Nothing matches this view'), findsOneWidget);
        }
        if (name == 'Forums') {
          expect(find.text('What makes a great shared space?'), findsOneWidget);
          expect(find.text('October field notes'), findsNothing);
        }
        if (name == 'Posts') {
          expect(find.text('October field notes'), findsOneWidget);
          expect(find.text('Public'), findsOneWidget);
          expect(find.text('Hidden left post'), findsNothing);
          expect(find.text('Hidden Matrix post'), findsNothing);
        }
        if (name == 'Matrix') {
          expect(find.text('External friend'), findsWidgets);
          expect(find.text('Weekend plans'), findsNothing);
          await tester.tap(find.text('Connect with Matrix').last);
          await tester.pumpAndSettle();
          expect(
            tester
                .widget<ConversationPicker>(find.byType(ConversationPicker))
                .matrixOnly,
            isTrue,
          );
          expect(find.text('Start conversation'), findsNothing);
          await tester.tap(find.text('Cancel'));
          await tester.pumpAndSettle();
        }
        expect(tester.takeException(), isNull);
      }
      await tester.pumpWidget(const SizedBox());
    });
    testWidgets(
      'Posts chooses a supported community and opens its editor at $width',
      (tester) async {
        await tester.binding.setSurfaceSize(Size(width, 1000));
        addTearDown(() => tester.binding.setSurfaceSize(null));
        final app = fixture();
        await tester.pumpWidget(RiverApp(api: app, boot: false));
        await tester.pumpAndSettle();
        await destination(tester, 'Posts', width);
        await tester.tap(find.widgetWithText(FilledButton, 'New post'));
        await tester.pumpAndSettle();
        expect(
          find.descendant(
            of: find.byType(SimpleDialog),
            matching: find.text('Open source'),
          ),
          findsNothing,
        );
        expect(
          find.descendant(
            of: find.byType(SimpleDialog),
            matching: find.text('Private community'),
          ),
          findsNothing,
        );
        await tester.tap(
          find.descendant(
            of: find.byType(SimpleDialog),
            matching: find.text('Design collective'),
          ),
        );
        await tester.pumpAndSettle();
        expect(app.selected, 'Design collective');
        expect(
          tester.widget<EntryEditor>(find.byType(EntryEditor)).room,
          'Design collective',
        );
        expect(find.text('Post audience'), findsOneWidget);
        await tester.tap(find.text('Cancel'));
        await tester.pumpAndSettle();
        expect(find.byType(EntryFeed), findsOneWidget);
        expect(find.byType(RichComposer), findsNothing);
        expect(tester.takeException(), isNull);
        await tester.pumpWidget(const SizedBox());
      },
    );
  }
  testWidgets(
    'Matrix spaces open child messaging without River calls or publishing',
    (tester) async {
      await tester.binding.setSurfaceSize(const Size(390, 900));
      addTearDown(() => tester.binding.setSurfaceSize(null));
      final app = fixture()..selected = 'Open source';
      app.group('Matrix project')!['channel_kind'] = 'drop_in';
      await tester.pumpWidget(RiverApp(api: app, boot: false));
      await tester.pumpAndSettle();
      expect(find.byType(MatrixRoomList), findsOneWidget);
      await tester.tap(find.text('Matrix project'));
      await tester.pumpAndSettle();
      expect(app.selected, 'Matrix project');
      expect(find.byType(RichComposer), findsOneWidget);
      expect(find.byTooltip('Join call'), findsNothing);
      expect(find.byType(SegmentedButton<String>), findsNothing);
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox());
    },
  );
  testWidgets(
    'global room search crosses destinations and keeps a chat draft',
    (tester) async {
      await tester.binding.setSurfaceSize(const Size(1440, 1000));
      addTearDown(() => tester.binding.setSurfaceSize(null));
      final app = fixture()..selected = 'Weekend plans';
      await tester.pumpWidget(RiverApp(api: app, boot: false));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Markdown'));
      await tester.pumpAndSettle();
      await tester.enterText(
        find.byType(TextField).last,
        'Saved while I explore',
      );
      await tester.tap(find.byTooltip('Search'));
      await tester.pumpAndSettle();
      await tester.enterText(
        find.byKey(const ValueKey('conversation-search')),
        'External friend',
      );
      await tester.pumpAndSettle();
      await tester.tap(find.widgetWithText(ListTile, 'External friend'));
      await tester.pumpAndSettle();
      expect(app.selected, 'External friend');
      await tester.enterText(
        find.byKey(const ValueKey('conversation-search')),
        'Weekend plans',
      );
      await tester.pumpAndSettle();
      await tester.tap(find.widgetWithText(ListTile, 'Weekend plans'));
      await tester.pumpAndSettle();
      expect(find.text('Saved while I explore'), findsOneWidget);
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox());
    },
  );
  testWidgets(
    'active call controls remain visible across mobile destinations',
    (tester) async {
      await tester.binding.setSurfaceSize(const Size(390, 900));
      addTearDown(() => tester.binding.setSurfaceSize(null));
      final app = fixture();
      final call = ReviewRoom();
      app.calls
        ..room = call
        ..target = {'id': 'voice', 'name': 'Design lounge'};
      await tester.pumpWidget(RiverApp(api: app, boot: false));
      await tester.pumpAndSettle();
      for (final name in [
        'Chats',
        'Communities',
        'Forums',
        'Posts',
        'Matrix',
      ]) {
        await destination(tester, name, 390);
        expect(find.byTooltip('Leave call'), findsOneWidget);
        expect(find.text('Design lounge'), findsOneWidget);
      }
      await tester.tap(find.byTooltip('Leave call'));
      await tester.pumpAndSettle();
      expect(call.disconnected, isTrue);
      expect(find.byTooltip('Leave call'), findsNothing);
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox());
    },
  );
}
