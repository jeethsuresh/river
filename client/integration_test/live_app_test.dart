import 'package:flutter/material.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:river/main.dart';

const session = String.fromEnvironment('RIVER_TEST_SESSION');
const friend = String.fromEnvironment('RIVER_TEST_FRIEND');
void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();
  testWidgets(
    'Android live channels, friend acceptance and direct messages',
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
      await until(find.byTooltip('Send'));
      expect(find.text('lobby'), findsWidgets);
      await tester.enterText(
        find.byType(TextField).last,
        'Android renderer to Gravitas round trip',
      );
      await tester.tap(find.byTooltip('Send'));
      await tester.pumpAndSettle();
      await until(find.text('Android renderer to Gravitas round trip'));
      Future<void> navigate(String label) async {
        await tester.tap(find.byTooltip('Open navigation menu'));
        await tester.pumpAndSettle();
        await tester.ensureVisible(find.text(label).last);
        await tester.tap(find.text(label).last);
        await tester.pumpAndSettle();
      }

      await navigate('Android verification space');
      await until(find.byTooltip('Group options'));
      await tester.tap(find.byTooltip('Group options'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('New text channel'));
      await tester.pumpAndSettle();
      await tester.enterText(find.byType(TextField).last, 'native-projects');
      await tester.tap(find.text('Continue'));
      await tester.pumpAndSettle();
      await until(find.text('native-projects'));
      await until(find.byTooltip('Send'));
      expect(
        find.text('Android renderer to Gravitas round trip'),
        findsNothing,
      );
      await tester.enterText(
        find.byType(TextField).last,
        'Android separate channel round trip',
      );
      await tester.tap(find.byTooltip('Send'));
      await tester.pumpAndSettle();
      await until(find.text('Android separate channel round trip'));
      if (friend.isNotEmpty) {
        await navigate('Friends');
        await until(find.text(friend));
        await tester.ensureVisible(find.text('Accept'));
        await tester.tap(find.text('Accept'));
        await tester.pumpAndSettle();
        await until(find.text('Message'));
        await tester.ensureVisible(find.text('Message'));
        await tester.tap(find.text('Message'));
        await tester.pumpAndSettle();
        await until(find.byTooltip('Send'));
        await tester.enterText(
          find.byType(TextField).last,
          'Android friend direct message',
        );
        await tester.tap(find.byTooltip('Send'));
        await tester.pumpAndSettle();
        await until(find.text('Android friend direct message'));
      }
      expect(tester.takeException(), isNull);
      await const FlutterSecureStorage().delete(key: 'river_session');
    },
    skip: session.isEmpty,
  );
}
