import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:river/username_login.dart';

void main() {
  testWidgets(
    'username supports Enter and fire while registration uses the configured domain',
    (tester) async {
      await tester.binding.setSurfaceSize(const Size(320, 700));
      addTearDown(() => tester.binding.setSurfaceSize(null));
      final submitted = <String>[];
      var registrations = 0;
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: Padding(
              padding: const EdgeInsets.all(16),
              child: UsernameLogin(
                defaultDomain: 'accounts.example',
                onSubmit: (username) async {
                  submitted.add(username);
                },
                onRegister: () async {
                  registrations++;
                },
              ),
            ),
          ),
        ),
      );
      expect(find.text('Register at accounts.example'), findsOneWidget);
      expect(
        find.text('Without a domain, sign in at accounts.example.'),
        findsOneWidget,
      );
      await tester.tap(find.text('🔥'));
      expect(submitted, isEmpty);
      await tester.enterText(find.byType(TextField), ' alice@remote.example ');
      await tester.testTextInput.receiveAction(TextInputAction.go);
      await tester.pumpAndSettle();
      expect(submitted, ['alice@remote.example']);
      await tester.enterText(find.byType(TextField), 'alice');
      await tester.tap(find.text('🔥'));
      await tester.pumpAndSettle();
      expect(submitted, ['alice@remote.example', 'alice']);
      await tester.enterText(find.byType(TextField), '');
      await tester.tap(find.text('Register at accounts.example'));
      await tester.pumpAndSettle();
      expect(registrations, 1);
      expect(tester.takeException(), isNull);
    },
  );
}
