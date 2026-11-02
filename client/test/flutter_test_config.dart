import 'dart:async';
import 'package:flutter_test/flutter_test.dart';
import 'package:river/store_notifications.dart';

Future<void> testExecutable(FutureOr<void> Function() testMain) async {
  TestWidgetsFlutterBinding.ensureInitialized();
  // Flutter unit tests have no Android process. Native delivery and Binder
  // authentication are exercised separately by the installed-device CI test.
  TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
      .setMockMethodCallHandler(StoreNotifications.channel, (_) async => null);
  await testMain();
}
