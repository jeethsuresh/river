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
        final api =
            RiverApi()
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
        expect(find.text('Welcome to your river, Alice.'), findsOneWidget);
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
      expect(find.text('Continue with Gravitas'), findsOneWidget);
      expect(find.textContaining('Calls are coming later'), findsOneWidget);
    },
  );
  testWidgets('account changes discard the previous account composer', (
    tester,
  ) async {
    final api =
        RiverApi()
          ..loading = false
          ..user = {'username': 'Alice', 'sub': 'alice'};
    api.groups = [
      {
        'id': 'one',
        'name': 'Private space',
        'kind': 'space',
        'membership': 'join',
        'owner': true,
        'members': <Json>[],
      },
    ];
    api.selected = 'one';
    await tester.pumpWidget(RiverApp(api: api, boot: false));
    await tester.pumpAndSettle();
    await tester.enterText(find.byType(TextField), 'Private unsent draft');
    api.user = {'username': 'Bob', 'sub': 'bob'};
    api.notifyListeners();
    await tester.pumpAndSettle();
    expect(find.text('Private unsent draft'), findsNothing);
  });
}
