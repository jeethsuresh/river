import 'dart:async';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:river/api.dart';
import 'package:river/main.dart';
import 'package:river/rich_composer.dart';
import 'package:river/store_notifications.dart';
import 'matrix_messaging_test.dart' show MemoryMatrixStorage;

class StartingBubbleApi extends RiverApi {
  StartingBubbleApi() : super(live: false, matrixEnabled: false);
  final start = Completer<void>();
  int opens = 0, resumes = 0;
  @override
  Future<void> boot() async {
    await start.future;
    loading = false;
    notifyListeners();
  }

  @override
  Future<void> resumeAuthentication() async => resumes++;
  @override
  Future<void> openStoreNotification(Json notification) async => opens++;
}

class BubbleNavigationApi extends RiverApi {
  BubbleNavigationApi()
    : super(
        live: false,
        matrixEnabled: false,
        matrixStorage: MemoryMatrixStorage(),
      );
  @override
  Future<void> refresh() async {}
  @override
  Future<void> resumeAuthentication() async {}
  @override
  Future<void> open(String? id) async {
    selected = id;
    notifyListeners();
  }
}

class ResumingBubbleApi extends BubbleNavigationApi {
  final firstResume = Completer<void>();
  int resumes = 0;
  @override
  Future<void> resumeAuthentication() async {
    if (++resumes == 1) await firstResume.future;
  }
}

void main() {
  testWidgets('a delayed authentication resume cannot reopen an older bubble', (
    tester,
  ) async {
    debugDefaultTargetPlatformOverride = TargetPlatform.android;
    final messenger =
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
    final pending = ['first', 'second'];
    messenger.setMockMethodCallHandler(StoreNotifications.channel, (
      call,
    ) async {
      if (call.method == 'takeOpen' && pending.isNotEmpty) {
        return {'subject': 'alice', 'room_id': '!${pending.removeAt(0)}:home'};
      }
      return null;
    });
    final app = ResumingBubbleApi()
      ..loading = false
      ..user = {
        'issuer': 'https://gravitas.cool',
        'sub': 'alice',
        'user_id': '@alice:home',
      }
      ..groups = [
        for (final id in ['first', 'second'])
          {
            'id': id,
            'room_id': '!$id:home',
            'name': id,
            'kind': 'dm',
            'membership': 'join',
            'members': <Json>[],
          },
      ];
    Future<void> opened() {
      final done = Completer<void>();
      messenger.handlePlatformMessage(
        StoreNotifications.channel.name,
        const StandardMethodCodec().encodeMethodCall(
          const MethodCall('opened', {}),
        ),
        (_) => done.complete(),
      );
      return done.future;
    }

    try {
      await tester.pumpWidget(RiverApp(api: app, boot: false));
      final first = opened();
      await tester.pump();
      final second = opened();
      await tester.pumpAndSettle();
      await second;
      expect(app.selected, 'second');
      app.firstResume.complete();
      await tester.pumpAndSettle();
      await first;
      expect(app.selected, 'second');
    } finally {
      if (!app.firstResume.isCompleted) app.firstResume.complete();
      await tester.pumpWidget(const SizedBox());
      debugDefaultTargetPlatformOverride = null;
      messenger.setMockMethodCallHandler(StoreNotifications.channel, null);
    }
  });
  testWidgets(
    'lifecycle resume waits for account restoration before taking a bubble',
    (tester) async {
      debugDefaultTargetPlatformOverride = TargetPlatform.android;
      final messenger =
          TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
      var pending = true;
      messenger.setMockMethodCallHandler(StoreNotifications.channel, (
        call,
      ) async {
        if (call.method == 'takeOpen' && pending) {
          pending = false;
          return {'subject': 'alice', 'room_id': '!chat:home'};
        }
        return null;
      });
      final app = StartingBubbleApi();
      try {
        await tester.pumpWidget(RiverApp(api: app));
        tester.binding.handleAppLifecycleStateChanged(
          AppLifecycleState.inactive,
        );
        tester.binding.handleAppLifecycleStateChanged(
          AppLifecycleState.resumed,
        );
        await tester.pump();
        expect(app.resumes, 0);
        expect(app.opens, 0);
        expect(pending, isTrue);
        app.start.complete();
        await tester.pumpAndSettle();
        expect(app.resumes, 1);
        expect(app.opens, 1);
      } finally {
        if (!app.start.isCompleted) app.start.complete();
        await tester.pumpWidget(const SizedBox());
        debugDefaultTargetPlatformOverride = null;
        messenger.setMockMethodCallHandler(StoreNotifications.channel, null);
      }
    },
  );
  testWidgets(
    'switching to a bubble reveals its chat above an existing route',
    (tester) async {
      debugDefaultTargetPlatformOverride = TargetPlatform.android;
      final messenger =
          TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
      messenger.setMockMethodCallHandler(
        StoreNotifications.channel,
        (_) async => {'subject': 'alice', 'room_id': '!chat:home'},
      );
      final app = BubbleNavigationApi()
        ..loading = false
        ..user = {
          'issuer': 'https://gravitas.cool',
          'sub': 'alice',
          'user_id': '@alice:home',
        }
        ..groups = [
          {
            'id': 'chat',
            'room_id': '!chat:home',
            'name': 'Weekend plans',
            'kind': 'dm',
            'membership': 'join',
            'members': <Json>[],
          },
        ];
      try {
        await tester.pumpWidget(RiverApp(api: app, boot: false));
        await tester.pumpAndSettle();
        unawaited(
          tester
              .state<NavigatorState>(find.byType(Navigator).first)
              .push<void>(
                MaterialPageRoute<void>(
                  builder: (_) => const Scaffold(body: Text('Another thread')),
                ),
              ),
        );
        await tester.pumpAndSettle();
        expect(find.text('Another thread'), findsOneWidget);
        final delivered = Completer<void>();
        messenger.handlePlatformMessage(
          StoreNotifications.channel.name,
          const StandardMethodCodec().encodeMethodCall(
            const MethodCall('opened', {}),
          ),
          (_) => delivered.complete(),
        );
        await tester.pumpAndSettle();
        await delivered.future;
        expect(find.text('Another thread'), findsNothing);
        expect(app.selected, 'chat');
        expect(find.byType(RichComposer), findsOneWidget);
        await tester.pumpWidget(const SizedBox());
      } finally {
        debugDefaultTargetPlatformOverride = null;
        messenger.setMockMethodCallHandler(StoreNotifications.channel, null);
      }
    },
  );
  testWidgets('an early bubble open waits for account restoration', (
    tester,
  ) async {
    debugDefaultTargetPlatformOverride = TargetPlatform.android;
    final messenger =
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
    var pending = true;
    messenger.setMockMethodCallHandler(StoreNotifications.channel, (
      call,
    ) async {
      if (call.method == 'takeOpen' && pending) {
        pending = false;
        return {'subject': 'alice', 'room_id': '!chat:home'};
      }
      return null;
    });
    final app = StartingBubbleApi();
    final delivered = Completer<void>();
    try {
      await tester.pumpWidget(RiverApp(api: app));
      messenger.handlePlatformMessage(
        StoreNotifications.channel.name,
        const StandardMethodCodec().encodeMethodCall(
          const MethodCall('opened', {}),
        ),
        (_) => delivered.complete(),
      );
      await tester.pump();
      expect(app.resumes, 0);
      expect(app.opens, 0);
      app.start.complete();
      await tester.pumpAndSettle();
      await delivered.future;
      expect(app.resumes, 1);
      expect(app.opens, 1);
      await tester.pumpWidget(const SizedBox());
    } finally {
      debugDefaultTargetPlatformOverride = null;
      messenger.setMockMethodCallHandler(StoreNotifications.channel, null);
    }
  });
  testWidgets('bubble chat keeps the composer visible with the keyboard open', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(360, 640);
    tester.view.devicePixelRatio = 1;
    tester.view.viewInsets = const FakeViewPadding(bottom: 280);
    addTearDown(tester.view.reset);
    final app = RiverApi(live: false, matrixStorage: MemoryMatrixStorage())
      ..loading = false
      ..user = {'sub': 'alice', 'user_id': '@alice:home', 'username': 'Alice'}
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
      ..events = [
        {
          'event_id': r'$latest',
          'type': 'm.room.message',
          'sender': '@bob:home',
          'origin_server_ts': 1,
          'content': {'body': 'See you soon'},
        },
      ];
    await tester.pumpWidget(RiverApp(api: app, boot: false));
    await tester.pumpAndSettle();
    final composer = find.byType(RichComposer);
    expect(composer, findsOneWidget);
    expect(tester.getBottomLeft(composer).dy, lessThanOrEqualTo(360));
    expect(find.byKey(const ValueKey('message-timeline')), findsOneWidget);
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox());
  });
}
