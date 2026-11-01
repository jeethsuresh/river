import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:river/native_broker.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  test(
    'Android Store code is never requested for a different River server',
    () async {
      debugDefaultTargetPlatformOverride = TargetPlatform.android;
      addTearDown(() => debugDefaultTargetPlatformOverride = null);
      var calls = 0;
      const channel = MethodChannel('cool.gravitas.river/auth');
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(channel, (_) async {
            calls++;
            return null;
          });
      addTearDown(
        () => TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
            .setMockMethodCallHandler(channel, null),
      );
      expect(
        await authorizeNativeBroker(
          'c' * 43,
          's' * 43,
          null,
          appOrigin: 'https://other.example',
        ),
        null,
      );
      expect(calls, 0);
      expect(await authorizeNativeBroker('c' * 43, 's' * 43, null), null);
      expect(calls, 1);
    },
  );
}
