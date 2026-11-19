import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:river/username_login.dart';

void main() {
  for (final accessRequired in [true, false]) {
    testWidgets(
      'Existing account action waits for one explicit tap ($accessRequired)',
      (tester) async {
        var started = 0;
        final completed = Completer<void>();
        await tester.pumpWidget(
          MaterialApp(
            home: Scaffold(
              body: UsernameLogin(
                defaultDomain: 'gravitas.cool',
                onSubmit: (_) async {},
                onRegister: () async {},
                onContinue: () {
                  started++;
                  return completed.future;
                },
                accessRequired: accessRequired,
              ),
            ),
          ),
        );
        expect(find.byType(TextField), findsNothing);
        expect(started, 0);
        final action = find.text(
          accessRequired ? 'Grant access' : 'Continue with Gravitas',
        );
        await tester.tap(action);
        await tester.tap(action);
        await tester.pump();
        expect(find.text('Connecting…'), findsOneWidget);
        expect(started, 1);
        completed.complete();
        await tester.pumpAndSettle();
        await tester.tap(find.text('Use another account'));
        await tester.pumpAndSettle();
        expect(find.byType(TextField), findsOneWidget);
      },
    );
  }
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
