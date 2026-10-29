import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:river/main.dart';
import 'package:river/api.dart';

void main() {
  testWidgets(
    'responsive home and group layout at phone, tablet and desktop sizes',
    (tester) async {
      for (final width in [390.0, 768.0, 1440.0]) {
        await tester.binding.setSurfaceSize(Size(width, 900));
        final api = RiverApi()
          ..loading = false
          ..user = {
            'username': 'Alice',
            'sub': 'alice',
            'user_id': '@alice:gravitas.cool',
          };
        api.groups = [
          {
            'id': 'space',
            'name': 'River space',
            'kind': 'space',
            'membership': 'join',
            'owner': true,
            'members': <Json>[],
          },
        ];
        await tester.pumpWidget(RiverApp(api: api, boot: false));
        await tester.pumpAndSettle();
        expect(find.text('Welcome, Alice.'), findsOneWidget);
        expect(tester.takeException(), isNull);
        api.selected = 'space';
        api.notifyListeners();
        await tester.pumpAndSettle();
        expect(find.text('Chat'), findsOneWidget);
        expect(tester.takeException(), isNull);
        await tester.pumpWidget(const SizedBox());
      }
      await tester.binding.setSurfaceSize(null);
    },
  );
  testWidgets(
    'signed out view offers Gravitas login and states call availability',
    (tester) async {
      final api = RiverApi()..loading = false;
      await tester.pumpWidget(RiverApp(api: api, boot: false));
      await tester.pumpAndSettle();
      expect(find.text('🔥'), findsOneWidget);
      expect(find.widgetWithText(TextField, 'Username'), findsOneWidget);
      expect(find.text('Register at gravitas.cool'), findsOneWidget);
      expect(
        find.textContaining(
          'Messages, ideas and calls, connected through Gravitas.',
        ),
        findsOneWidget,
      );
    },
  );
  testWidgets('account changes discard the previous account composer', (
    tester,
  ) async {
    final api = RiverApi()
      ..loading = false
      ..user = {'username': 'Alice', 'sub': 'alice'};
    api.groups = [
      {
        'id': 'one',
        'name': 'Private space',
        'kind': 'group',
        'membership': 'join',
        'owner': true,
        'members': <Json>[],
      },
    ];
    api.selected = 'one';
    await tester.pumpWidget(RiverApp(api: api, boot: false));
    await tester.pumpAndSettle();
    await tester.ensureVisible(find.text('Markdown'));
    await tester.tap(find.text('Markdown'));
    await tester.pumpAndSettle();
    await tester.enterText(find.byType(TextField).last, 'Private unsent draft');
    api.user = {'username': 'Bob', 'sub': 'bob'};
    api.notifyListeners();
    await tester.pumpAndSettle();
    expect(find.text('Private unsent draft'), findsNothing);
  });
  testWidgets('account changes dismiss private member sheets and dialogs', (
    tester,
  ) async {
    final api = RiverApi()
      ..loading = false
      ..user = {'sub': 'alice', 'username': 'alice'};
    api.groups = [
      {
        'id': 'one',
        'name': 'Private space',
        'kind': 'space',
        'membership': 'join',
        'owner': true,
        'members': <Json>[
          {'username': 'private-member', 'principal_id': 'member'},
        ],
      },
    ];
    api.selected = 'one';
    await tester.pumpWidget(RiverApp(api: api, boot: false));
    await tester.pumpAndSettle();
    await tester.tap(find.byTooltip('Group options'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Members'));
    await tester.pumpAndSettle();
    expect(find.text('private-member'), findsOneWidget);
    api.user = {'sub': 'bob', 'username': 'bob'};
    api.groups = [];
    api.selected = null;
    api.notifyListeners();
    await tester.pumpAndSettle();
    expect(find.text('private-member'), findsNothing);
    expect(find.text('Welcome, bob.'), findsOneWidget);
  });
}
