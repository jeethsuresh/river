import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:river/api.dart';
import 'package:river/content_widgets.dart';
import 'package:river/main.dart';
import 'package:river/river_feedback.dart';
import 'package:river/rich_composer.dart';

class FeedbackSendApi extends RiverApi {
  FeedbackSendApi() : super(live: false, matrixEnabled: false);
  Completer<Json> operation = Completer<Json>();
  final transactions = <String>[];
  @override
  Future<Json> send(
    String id,
    String type,
    Json content,
    String txn, {
    bool refreshAfter = true,
  }) {
    transactions.add(txn);
    return operation.future;
  }
}

FeedbackSendApi conversation() => FeedbackSendApi()
  ..loading = false
  ..user = {'sub': 'alice', 'username': 'Alice'}
  ..groups = [
    {
      'id': 'room',
      'name': 'Friends',
      'kind': 'group',
      'membership': 'join',
      'members': <Json>[],
    },
  ]
  ..selected = 'room';

void main() {
  testWidgets('send failure keeps the draft and retry reuses its transaction', (
    tester,
  ) async {
    final api = conversation();
    await tester.pumpWidget(RiverApp(api: api, boot: false));
    await tester.pumpAndSettle();
    final composer = tester.widget<RichComposer>(find.byType(RichComposer));
    composer.controller.text = 'Keep this message';
    await tester.pump();
    await tester.tap(find.byTooltip('Send'));
    await tester.pump();
    expect(find.text('Sending…'), findsOneWidget);
    await tester.tap(find.byTooltip('Send'));
    expect(api.transactions, hasLength(1));
    api.operation.completeError(StateError('offline'));
    await tester.pumpAndSettle();
    expect(composer.controller.text, 'Keep this message');
    expect(find.text('Send failed'), findsOneWidget);
    api.operation = Completer<Json>();
    await tester.tap(find.text('Retry'));
    await tester.pump();
    expect(api.transactions, hasLength(2));
    expect(api.transactions[1], api.transactions[0]);
    api.operation.complete({'event_id': 'sent'});
    await tester.pumpAndSettle();
    expect(composer.controller.text, isEmpty);
    expect(find.text('Sent'), findsOneWidget);
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('a completed send cannot clear a different account draft', (
    tester,
  ) async {
    final api = conversation();
    await tester.pumpWidget(RiverApp(api: api, boot: false));
    await tester.pumpAndSettle();
    final composer = tester.widget<RichComposer>(find.byType(RichComposer));
    composer.controller.text = 'Alice message';
    await tester.pump();
    await tester.tap(find.byTooltip('Send'));
    await tester.pump();
    api.user = {'sub': 'bob', 'username': 'Bob'};
    api.notifyListeners();
    await tester.pump();
    tester.widget<RichComposer>(find.byType(RichComposer)).controller.text =
        'Bob draft';
    api.operation.complete({'event_id': 'sent'});
    await tester.pumpAndSettle();
    expect(
      tester.widget<RichComposer>(find.byType(RichComposer)).controller.text,
      'Bob draft',
    );
    expect(find.text('Sent'), findsNothing);
    await tester.pumpWidget(const SizedBox());
  });
  testWidgets(
    'press is cancellable and does not delay the real control action',
    (tester) async {
      var actions = 0;
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: RiverPress(
              child: TextButton(
                onPressed: () => actions++,
                child: const Text('Send'),
              ),
            ),
          ),
        ),
      );
      final gesture = await tester.startGesture(
        tester.getCenter(find.text('Send')),
      );
      await tester.pump(const Duration(milliseconds: 90));
      expect(
        tester.widget<AnimatedScale>(find.byType(AnimatedScale)).scale,
        lessThan(1),
      );
      await gesture.cancel();
      await tester.pumpAndSettle();
      expect(actions, 0);
      expect(tester.widget<AnimatedScale>(find.byType(AnimatedScale)).scale, 1);
      await tester.tap(find.text('Send'));
      expect(actions, 1);
    },
  );

  testWidgets(
    'reduced motion changing during message arrival finishes without stale frames',
    (tester) async {
      Widget scene(bool reduced) => MaterialApp(
        home: MediaQuery(
          data: MediaQueryData(disableAnimations: reduced),
          child: const RiverMessageArrival(
            animate: true,
            child: Text('New message'),
          ),
        ),
      );
      await tester.pumpWidget(scene(false));
      await tester.pump(const Duration(milliseconds: 60));
      await tester.pumpWidget(scene(true));
      await tester.pumpAndSettle();
      expect(find.text('New message'), findsOneWidget);
      expect(tester.widget<Opacity>(find.byType(Opacity).last).opacity, 1);
      expect(tester.binding.transientCallbackCount, 0);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'reaction failure retains real count and repeated input submits once',
    (tester) async {
      var calls = 0;
      final gate = Completer<void>();
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: ReactionBar(
              summary: const [
                {'key': '👍', 'count': 1, 'mine': false},
              ],
              change: (emoji, active) async {
                calls++;
                await gate.future;
              },
            ),
          ),
        ),
      );
      await tester.tap(find.byTooltip('React 👍'));
      await tester.pump();
      await tester.tap(find.byTooltip('React 👍'));
      await tester.pump();
      expect(calls, 1);
      expect(find.text('1'), findsOneWidget);
      expect(find.text('2'), findsNothing);
      gate.completeError(StateError('offline'));
      await tester.pumpAndSettle();
      expect(find.text('1'), findsOneWidget);
      expect(find.textContaining('offline'), findsOneWidget);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'hydrated and paginated history stay still; only appended events arrive',
    (tester) async {
      Json message(String id, int at) => {
        'event_id': id,
        'type': 'm.room.message',
        'sender': '@alice:home',
        'origin_server_ts': at,
        'content': {'body': id, 'msgtype': 'm.text'},
      };
      final api =
          RiverApi(
              live: false,
              matrixEnabled: false,
              client: MockClient((_) async => http.Response('{}', 200)),
            )
            ..loading = false
            ..user = {
              'username': 'alice',
              'sub': 'alice',
              'user_id': '@alice:home',
            }
            ..groups = [
              {
                'id': 'room',
                'name': 'Friends',
                'kind': 'group',
                'membership': 'join',
                'members': <Json>[],
              },
            ]
            ..selected = 'room'
            ..events = [message('history', 100)];
      await tester.pumpWidget(RiverApp(api: api, boot: false));
      await tester.pumpAndSettle();
      expect(
        tester
            .widgetList<RiverMessageArrival>(find.byType(RiverMessageArrival))
            .every((w) => !w.animate),
        isTrue,
      );
      api.events = [...api.events, message('new', 200)];
      api.notifyListeners();
      await tester.pump();
      expect(
        tester
            .widgetList<RiverMessageArrival>(find.byType(RiverMessageArrival))
            .where((w) => w.animate)
            .length,
        1,
      );
      api.events = [message('older', 50), ...api.events];
      api.notifyListeners();
      await tester.pumpAndSettle();
      expect(
        tester
            .widgetList<RiverMessageArrival>(find.byType(RiverMessageArrival))
            .where((w) => w.animate)
            .length,
        1,
      );
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox());
    },
  );
}
