import 'package:flutter/material.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:river/main.dart';

const session = String.fromEnvironment('RIVER_TEST_SESSION');
void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();
  testWidgets(
    'Android secure-storage session, live group and message round trip',
    (tester) async {
      await const FlutterSecureStorage().write(
        key: 'river_session',
        value: session,
      );
      await tester.pumpWidget(const RiverApp());
      Future<void> until(Finder f) async {
        for (var i = 0; i < 60 && f.evaluate().isEmpty; i++) {
          await tester.pump(const Duration(milliseconds: 500));
        }
        expect(f, findsWidgets);
      }

      await until(find.text('Create a space'));
      await tester.ensureVisible(find.text('Create a space'));
      await tester.tap(find.text('Create a space'));
      await tester.pumpAndSettle();
      await tester.enterText(
        find.byType(TextField),
        'Android verification space',
      );
      await tester.tap(find.text('Continue'));
      await tester.pumpAndSettle();
      await until(find.text('Chat'));
      await tester.enterText(
        find.byType(TextField).last,
        'Android renderer to Gravitas round trip',
      );
      await tester.tap(find.byTooltip('Send'));
      await tester.pumpAndSettle();
      await until(find.text('Android renderer to Gravitas round trip'));
      expect(tester.takeException(), isNull);
      await const FlutterSecureStorage().delete(key: 'river_session');
    },
    skip: session.isEmpty,
  );
}
