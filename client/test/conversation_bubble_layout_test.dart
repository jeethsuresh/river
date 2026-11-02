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

void main() {
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
