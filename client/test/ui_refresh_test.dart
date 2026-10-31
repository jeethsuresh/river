import 'dart:convert';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:livekit_client/livekit_client.dart' show Room;
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:river/api.dart';
import 'package:river/call_chat.dart';
import 'package:river/comment_tree.dart';
import 'package:river/content_widgets.dart';
import 'package:river/home_widgets.dart';
import 'package:river/main.dart';
import 'package:river/rich_composer.dart';
import 'package:river/river_design.dart';
import 'package:river/workspace_widgets.dart';
import 'matrix_messaging_test.dart' show MemoryMatrixStorage;

Json comment(String id, [String? parent]) => {
  'event_id': id,
  'type': 'm.room.message',
  'sender': '@alice:home',
  'origin_server_ts': 0,
  'content': {
    'body': id,
    if (parent != null)
      'm.relates_to': {
        'm.in_reply_to': {'event_id': parent},
      },
  },
};

// Exercise call lifecycle and UI without starting a native WebRTC engine.
class ReviewRoom implements Room {
  bool disconnected = false;
  @override
  Null get localParticipant => null;
  @override
  void addListener(VoidCallback listener) {}
  @override
  void removeListener(VoidCallback listener) {}
  @override
  Future<void> disconnect() async {
    disconnected = true;
  }

  @override
  Future<bool> dispose() async => true;
  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class PickerApi extends RiverApi {
  PickerApi() : super(live: false, matrixStorage: MemoryMatrixStorage());
  String? joined;
  bool fail = true;
  @override
  bool get matrixConnected => true;
  @override
  Future<void> joinMatrixRoom(String target) async {
    if (fail) throw StateError('Room unavailable');
    joined = target;
  }
}

void main() {
  testWidgets(
    'Matrix room joining lives in New conversation and keeps failures retryable',
    (tester) async {
      final app = PickerApi();
      await tester.pumpWidget(
        MaterialApp(
          home: Builder(
            builder: (context) => Scaffold(
              body: TextButton(
                onPressed: () => showDialog<bool>(
                  context: context,
                  builder: (_) => ConversationPicker(app: app),
                ),
                child: const Text('Open'),
              ),
            ),
          ),
        ),
      );
      await tester.tap(find.text('Open'));
      await tester.pumpAndSettle();
      await tester.enterText(find.byType(TextField), '#garden:example.org');
      await tester.tap(find.text('Join Matrix room'));
      await tester.pumpAndSettle();
      expect(find.textContaining('Room unavailable'), findsOneWidget);
      expect(find.byType(ConversationPicker), findsOneWidget);
      app.fail = false;
      await tester.tap(find.text('Join Matrix room'));
      await tester.pumpAndSettle();
      expect(app.joined, '#garden:example.org');
      expect(find.byType(ConversationPicker), findsNothing);
      await tester.pumpWidget(const SizedBox());
      app.dispose();
    },
  );
  testWidgets('space rooms retain access to existing space chat on mobile', (
    tester,
  ) async {
    await tester.binding.setSurfaceSize(const Size(390, 900));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    final app = RiverApi(live: false, matrixStorage: MemoryMatrixStorage())
      ..loading = false
      ..user = {'sub': 'alice', 'username': 'Alice'}
      ..groups = [
        {
          'id': 'space',
          'name': 'Our space',
          'kind': 'space',
          'membership': 'join',
          'members': <Json>[],
        },
      ]
      ..selected = 'space'
      ..events = [comment('Existing space message')];
    await tester.pumpWidget(RiverApp(api: app, boot: false));
    await tester.pumpAndSettle();
    expect(find.text('Our space'), findsOneWidget);
    expect(find.byType(ContentCard), findsNothing);
    await tester.tap(find.byKey(const ValueKey('space-chat')));
    await tester.pumpAndSettle();
    expect(find.text('Existing space message'), findsOneWidget);
    expect(find.byType(RichComposer), findsOneWidget);
    await tester.tap(find.text('Back to rooms'));
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('space-chat')), findsOneWidget);
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox());
  });

  test(
    'switching calls leaves the previous room before joining, including failure',
    () async {
      debugDefaultTargetPlatformOverride = TargetPlatform.linux;
      addTearDown(() => debugDefaultTargetPlatformOverride = null);
      final actions = <String>[];
      final previous = ReviewRoom();
      final app = RiverApi(
        live: false,
        client: MockClient((r) async {
          final action = (jsonDecode(r.body) as Json)['action'];
          actions.add('${r.url.path}:$action');
          if (action == 'join') {
            expect(previous.disconnected, isTrue);
            return http.Response('{"error":"unavailable"}', 503);
          }
          return http.Response('{}', 200);
        }),
      );
      app.calls
        ..room = previous
        ..target = {'id': 'old', 'name': 'Old voice room'}
        ..member = 'old-member';
      await expectLater(
        app.calls.join({
          'id': 'next',
          'name': 'Next voice room',
          'channel_kind': 'drop_in',
        }),
        throwsA(isA<ApiException>()),
      );
      expect(actions.first, '/api/groups/old/rtc:leave');
      expect(actions[1], '/api/groups/next/rtc:join');
      expect(app.calls.active, isFalse);
      expect(app.calls.target, isNull);
      expect(app.calls.chat, isNull);
      expect(app.calls.error, isNotNull);
      app.dispose();
    },
  );
  testWidgets(
    'active call controls stay above Settings and leave immediately',
    (tester) async {
      await tester.binding.setSurfaceSize(const Size(1440, 1000));
      addTearDown(() => tester.binding.setSurfaceSize(null));
      final app = RiverApi(live: false, matrixStorage: MemoryMatrixStorage())
        ..loading = false
        ..user = {'sub': 'alice', 'username': 'Alice'};
      final room = ReviewRoom();
      app.calls
        ..room = room
        ..target = {'id': 'voice', 'name': 'Current voice room'};
      await tester.pumpWidget(RiverApp(api: app, boot: false));
      await tester.pumpAndSettle();
      expect(
        tester.getTopLeft(find.byTooltip('Leave call')).dy,
        lessThan(tester.getTopLeft(find.byTooltip('Settings')).dy),
      );
      expect(find.byTooltip('Unmute microphone'), findsOneWidget);
      await tester.tap(find.byTooltip('Leave call'));
      await tester.pumpAndSettle();
      expect(room.disconnected, isTrue);
      expect(find.byTooltip('Leave call'), findsNothing);
      await tester.pumpWidget(const SizedBox());
    },
  );

  test(
    'comment forest keeps late parents, missing parents and cycles visible',
    () {
      final tree = commentForest([
        comment('child', 'parent'),
        comment('parent'),
        comment('orphan', 'missing'),
        comment('a', 'b'),
        comment('b', 'a'),
        comment('self', 'self'),
      ], getReplyParent);
      expect(tree.map((n) => n.event['event_id']), [
        'parent',
        'orphan',
        'a',
        'b',
        'self',
      ]);
      expect(tree.first.children.single.event['event_id'], 'child');
    },
  );
  test('display names prefer known names and readable Matrix localparts', () {
    final app = RiverApi(live: false)
      ..friends = [
        {
          'user_id': '@alice:home',
          'username': 'alice',
          'display_name': 'Alice Chen',
        },
      ];
    expect(app.displayName('@alice:home'), 'Alice Chen');
    expect(app.displayName('@sam.smith:example.org'), 'sam smith');
    app.dispose();
  });
  test('favourites persist and stay isolated by account', () async {
    final app = RiverApi(live: false, matrixStorage: MemoryMatrixStorage())
      ..user = {'issuer': 'home', 'sub': 'alice'};
    await app.saveFavouritePeople({'@bob:home'});
    expect(await app.favouritePeople(), {'@bob:home'});
    app.user = {'issuer': 'home', 'sub': 'bob'};
    expect(await app.favouritePeople(), isEmpty);
    app.user = {'issuer': 'home', 'sub': 'alice'};
    expect(await app.favouritePeople(), {'@bob:home'});
    app.dispose();
  });
  for (final width in [360.0, 1440.0]) {
    testWidgets('Home order and columns at $width', (tester) async {
      await tester.binding.setSurfaceSize(Size(width, 1400));
      addTearDown(() => tester.binding.setSurfaceSize(null));
      final app = RiverApi(live: false, matrixStorage: MemoryMatrixStorage())
        ..user = {'sub': 'alice', 'username': 'Alice'};
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: RiverHome(app: app, open: (_) {}, create: (_) {}),
          ),
        ),
      );
      await tester.pumpAndSettle();
      final catchUp = tester.getTopLeft(find.text('Catch Up')),
          voice = tester.getTopLeft(find.text('Active Voice Rooms')),
          people = tester.getTopLeft(find.text('Your Favourite People'));
      if (width < 850) {
        expect(voice.dy, lessThan(catchUp.dy));
        expect(catchUp.dy, lessThan(people.dy));
      } else {
        expect(catchUp.dx, lessThan(voice.dx));
        expect(voice.dx, people.dx);
        expect(
          tester.getSize(find.byType(CatchUpPanel)).width,
          greaterThan(tester.getSize(find.byType(FavouritePeople)).width * 1.8),
        );
      }
      for (final title in [
        'Recent Posts',
        'Recent Discussions',
        'Recent Chats',
      ]) {
        expect(find.text(title), findsOneWidget);
      }
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox());
      app.dispose();
    });
    testWidgets(
      'subtree collapse preserves siblings and reply width at $width',
      (tester) async {
        await tester.binding.setSurfaceSize(Size(width, 1000));
        addTearDown(() => tester.binding.setSurfaceSize(null));
        await tester.pumpWidget(
          MaterialApp(
            home: Scaffold(
              body: SingleChildScrollView(
                child: CommentTree(
                  events: [
                    comment('root'),
                    comment('child', 'root'),
                    comment('grandchild', 'child'),
                    comment('sibling', 'root'),
                  ],
                  parentOf: getReplyParent,
                  replyTarget: 'child',
                  composer: const SizedBox(
                    key: ValueKey('reply-box'),
                    height: 60,
                  ),
                  builder: (e) => SizedBox(
                    key: ValueKey('body-${e['event_id']}'),
                    height: 50,
                    child: Text(e['event_id'] as String),
                  ),
                ),
              ),
            ),
          ),
        );
        expect(
          tester.getSize(find.byKey(const ValueKey('reply-box'))).width,
          tester.getSize(find.byKey(const ValueKey('body-child'))).width,
        );
        expect(
          tester.getTopLeft(find.byKey(const ValueKey('body-grandchild'))).dx,
          greaterThan(
            tester.getTopLeft(find.byKey(const ValueKey('body-child'))).dx,
          ),
        );
        await tester.tap(find.byKey(const ValueKey('collapse-child')));
        await tester.pumpAndSettle();
        expect(find.text('grandchild'), findsNothing);
        expect(find.text('sibling'), findsOneWidget);
        expect(find.byKey(const ValueKey('reply-box')), findsOneWidget);
        await tester.tap(find.byKey(const ValueKey('collapse-child')));
        await tester.pumpAndSettle();
        expect(find.text('grandchild'), findsOneWidget);
        expect(tester.takeException(), isNull);
      },
    );
    testWidgets(
      'messages have no bubble and reply precedes reactions at $width',
      (tester) async {
        await tester.binding.setSurfaceSize(Size(width, 900));
        addTearDown(() => tester.binding.setSurfaceSize(null));
        final app = RiverApi(live: false)
          ..user = {'user_id': '@alice:home', 'username': 'Alice Chen'};
        await tester.pumpWidget(
          MaterialApp(
            home: Scaffold(
              body: Align(
                alignment: Alignment.topLeft,
                child: ContentCard(
                  app: app,
                  room: 'room',
                  event: comment('Hello'),
                  reply: () {},
                ),
              ),
            ),
          ),
        );
        await tester.pumpAndSettle();
        expect(find.byType(Card), findsNothing);
        expect(find.text('Alice Chen'), findsOneWidget);
        expect(find.text('@alice:home'), findsNothing);
        final avatar = find.byKey(const ValueKey('content-avatar-Hello'));
        expect(tester.widget<RiverAvatar>(avatar).name, 'Alice Chen');
        expect(
          tester.getTopLeft(avatar).dx,
          lessThan(tester.getTopLeft(find.text('Hello')).dx),
        );
        expect(
          tester.getTopLeft(avatar).dy,
          tester
              .getTopLeft(find.byKey(const ValueKey('content-body-Hello')))
              .dy,
        );
        expect(
          tester.getTopLeft(find.text('Reply')).dx,
          lessThan(tester.getTopLeft(find.byTooltip('Add reaction')).dx),
        );
        expect(tester.getSize(find.byType(ContentCard)).height, lessThan(110));
        expect(tester.takeException(), isNull);
        await tester.pumpWidget(const SizedBox());
        app.dispose();
      },
    );
    testWidgets('short chat stays above the composer at $width', (
      tester,
    ) async {
      await tester.binding.setSurfaceSize(Size(width, 900));
      addTearDown(() => tester.binding.setSurfaceSize(null));
      final app = RiverApi(live: false, matrixStorage: MemoryMatrixStorage())
        ..loading = false
        ..user = {'user_id': '@alice:home', 'username': 'Alice Chen'}
        ..groups = [
          {
            'id': 'chat',
            'name': 'Weekend plans',
            'kind': 'dm',
            'membership': 'join',
            'members': <Json>[],
          },
        ]
        ..selected = 'chat'
        ..events = [comment('First message'), comment('Latest message')];
      await tester.pumpWidget(RiverApp(api: app, boot: false));
      await tester.pumpAndSettle();
      final timeline = find.byKey(const ValueKey('message-timeline'));
      void expectBottom(String last) {
        final card = find.ancestor(
          of: find.byKey(ValueKey('content-body-$last')),
          matching: find.byType(ContentCard),
        );
        expect(
          tester.getBottomLeft(card).dy,
          closeTo(tester.getBottomLeft(timeline).dy - 7, 1),
        );
        expect(
          tester.getBottomLeft(card).dy,
          lessThan(tester.getTopLeft(find.byType(RichComposer)).dy),
        );
      }

      expectBottom('Latest message');
      expect(
        tester
            .getTopLeft(
              find.byKey(const ValueKey('content-body-First message')),
            )
            .dy,
        greaterThan(tester.getCenter(timeline).dy),
      );
      expect(
        tester.getTopLeft(find.text('First message')).dy,
        lessThan(tester.getTopLeft(find.text('Latest message')).dy),
      );
      app.events = [...app.events, comment('Just arrived')];
      app.notifyListeners();
      await tester.pumpAndSettle();
      expectBottom('Just arrived');
      expect(find.text('New messages'), findsNothing);
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox());
    });
  }
  testWidgets(
    'call chat grows up from the composer and loads earlier messages above it',
    (tester) async {
      await tester.binding.setSurfaceSize(const Size(390, 900));
      addTearDown(() => tester.binding.setSurfaceSize(null));
      Json callMessage(String id, String order) => {
        ...comment(id),
        'unsigned': {'cool.gravitas.stream_order': order},
      };
      final app = RiverApi(
        live: false,
        matrixStorage: MemoryMatrixStorage(),
        client: MockClient(
          (request) async => http.Response(
            jsonEncode({
              'events': request.url.queryParameters['before'] == 'older'
                  ? [callMessage('Earlier in the call', '00')]
                  : [
                      callMessage('Hello in the call', '01'),
                      callMessage('Latest in the call', '02'),
                    ],
              'next_cursor': request.url.hasQuery ? null : 'older',
            }),
            200,
          ),
        ),
      )..user = {'user_id': '@alice:home', 'username': 'Alice'};
      app.calls
        ..room = ReviewRoom()
        ..chat = 'call';
      await tester.pumpWidget(
        MaterialApp(
          home: CallChatScreen(api: app, room: 'call'),
        ),
      );
      await tester.pumpAndSettle();
      final timeline = find.byType(ListView);
      final last = find.ancestor(
        of: find.byKey(const ValueKey('content-body-Latest in the call')),
        matching: find.byType(ContentCard),
      );
      expect(
        tester.getBottomLeft(last).dy,
        closeTo(tester.getBottomLeft(timeline).dy - 19, 1),
      );
      expect(
        tester.getTopLeft(find.text('Hello in the call')).dy,
        lessThan(tester.getTopLeft(find.text('Latest in the call')).dy),
      );
      expect(
        tester.getTopLeft(find.text('Load older messages')).dy,
        lessThan(tester.getTopLeft(find.text('Hello in the call')).dy),
      );
      await tester.tap(find.text('Load older messages'));
      await tester.pumpAndSettle();
      expect(
        tester.getTopLeft(find.text('Earlier in the call')).dy,
        lessThan(tester.getTopLeft(find.text('Hello in the call')).dy),
      );
      expect(
        tester.getBottomLeft(last).dy,
        closeTo(tester.getBottomLeft(timeline).dy - 19, 1),
      );
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox());
      app.dispose();
    },
  );
  testWidgets(
    'composer has one ordered toolbar row without Write or a formatting gate',
    (tester) async {
      final draft = TextEditingController();
      await tester.binding.setSurfaceSize(const Size(1600, 900));
      addTearDown(() => tester.binding.setSurfaceSize(null));
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: RichComposer(controller: draft, onAttach: () {}),
          ),
        ),
      );
      await tester.pumpAndSettle();
      expect(find.text('Write'), findsNothing);
      expect(find.byTooltip('Formatting tools'), findsNothing);
      final centers = [
        find.byTooltip('Bold'),
        find.byTooltip('Attach files'),
        find.byTooltip('Insert image or GIF'),
        find.text('Markdown'),
        find.text('Preview'),
      ].map(tester.getCenter).toList();
      for (var i = 1; i < centers.length; i++) {
        expect(centers[i].dy, centers[0].dy);
        expect(centers[i].dx, greaterThan(centers[i - 1].dx));
      }
      expect(find.text('|'), findsNWidgets(2));
      await tester.pumpWidget(const SizedBox());
      await tester.pump(const Duration(milliseconds: 600));
      draft.dispose();
    },
  );
  testWidgets('search expands beside Home and sign out is inside Settings', (
    tester,
  ) async {
    await tester.binding.setSurfaceSize(const Size(1440, 1000));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    final app = RiverApi(live: false, matrixStorage: MemoryMatrixStorage())
      ..loading = false
      ..user = {'sub': 'alice', 'username': 'Alice'};
    await tester.pumpWidget(RiverApp(api: app, boot: false));
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('conversation-search')), findsNothing);
    await tester.tap(find.byTooltip('Search'));
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('conversation-search')), findsOneWidget);
    expect(find.byTooltip('Sign out'), findsNothing);
    expect(find.text('Sign out of River'), findsNothing);
    await tester.tap(find.byTooltip('Settings'));
    await tester.pumpAndSettle();
    expect(find.text('Settings'), findsOneWidget);
    await tester.scrollUntilVisible(
      find.text('Sign out of River'),
      200,
      scrollable: find
          .descendant(
            of: find.byType(AccountPanel),
            matching: find.byType(Scrollable),
          )
          .first,
    );
    expect(find.text('Sign out of River'), findsOneWidget);
    await tester.tap(find.byTooltip('Close settings'));
    await tester.pumpAndSettle();
    expect(find.text('Sign out of River'), findsNothing);
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox());
  });
}
