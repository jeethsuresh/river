import 'package:flutter/material.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:river/main.dart';

const session = String.fromEnvironment('RIVER_TEST_SESSION');
const space = String.fromEnvironment('RIVER_TEST_SPACE');
void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();
  testWidgets(
    'Android live Markdown entries, authored edits, threads and reaction removal',
    (tester) async {
      await const FlutterSecureStorage().write(
        key: 'river_session',
        value: session,
      );
      await tester.pumpWidget(const RiverApp());
      Future<void> until(Finder finder) async {
        for (var i = 0; i < 90 && finder.evaluate().isEmpty; i++) {
          await tester.pump(const Duration(milliseconds: 500));
        }
        expect(finder, findsWidgets);
      }

      await until(find.text(space));
      await tester.ensureVisible(find.text(space).last);
      await tester.tap(find.text(space).last);
      await tester.pumpAndSettle();
      await until(find.text('Posts'));
      await tester.tap(find.text('Posts'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('New post'));
      await tester.pumpAndSettle();
      await tester.enterText(
        find.widgetWithText(TextFormField, 'Title'),
        'Android original entry',
      );
      await tester.enterText(
        find.widgetWithText(TextFormField, 'Body'),
        '**Android Markdown body**',
      );
      await tester.tap(find.text('Preview'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Post'));
      await tester.pumpAndSettle();
      await until(find.text('Android original entry'));
      await tester.ensureVisible(find.text('Edit').last);
      await tester.tap(find.text('Edit').last);
      await tester.pumpAndSettle();
      await tester.enterText(
        find.widgetWithText(TextFormField, 'Title'),
        'Android edited entry',
      );
      await tester.enterText(
        find.widgetWithText(TextFormField, 'Body'),
        'Android authored edit persisted',
      );
      await tester.tap(find.text('Save changes'));
      await tester.pumpAndSettle();
      await until(find.text('Android edited entry'));
      await tester.ensureVisible(find.text('Reply').last);
      await tester.tap(find.text('Reply').last);
      await tester.pumpAndSettle();
      await until(find.byTooltip('Send reply'));
      await tester.enterText(
        find.byType(TextField).last,
        'Android thread reply persisted',
      );
      await tester.tap(find.byTooltip('Send reply'));
      await tester.pumpAndSettle();
      await until(find.text('Android thread reply persisted'));
      await tester.ensureVisible(find.byTooltip('Add reaction').last);
      await tester.tap(find.byTooltip('Add reaction').last);
      await tester.pumpAndSettle();
      await tester.tap(find.text('🚀'));
      await tester.pumpAndSettle();
      await until(find.text('🚀 1'));
      await tester.tap(find.text('🚀 1'));
      await tester.pumpAndSettle();
      for (var i = 0; i < 60 && find.text('🚀 1').evaluate().isNotEmpty; i++) {
        await tester.pump(const Duration(milliseconds: 500));
      }
      expect(find.text('🚀 1'), findsNothing);
      expect(tester.takeException(), isNull);
      await const FlutterSecureStorage().delete(key: 'river_session');
    },
    skip: session.isEmpty || space.isEmpty,
  );
}
