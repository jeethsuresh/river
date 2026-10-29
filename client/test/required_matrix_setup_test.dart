import 'dart:async';
import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:river/api.dart';
import 'package:river/main.dart';
import 'package:river/rich_composer.dart';
import 'matrix_messaging_test.dart'
    show FakeMatrixTransport, MemoryMatrixStorage, matrixProfile;

class SetupFixture {
  final storage = MemoryMatrixStorage();
  final engine = FakeMatrixTransport();
  int launches = 0;
  bool openBrowser = true;
  Completer<void>? poll;
  late final api =
      RiverApi(
          live: false,
          matrixEnabled: true,
          matrixStorage: storage,
          matrixFactory: (_) async => engine,
          matrixStoreLocation: (name) async => name,
          authLaunch: (_) async {
            launches++;
            return openBrowser;
          },
          client: MockClient((request) async {
            final value = switch (request.url.path) {
              '/api/matrix/link' => {
                'id': 'setup',
                'url': 'https://river.example/matrix/link',
                'expires_at':
                    DateTime.now().millisecondsSinceEpoch ~/ 1000 + 300,
                'homeserver': matrixProfile['issuer'],
                'user_id': matrixProfile['user_id'],
              },
              '/api/matrix/poll' => await (() async {
                await poll?.future;
                return {
                  'login_token': 'one-use',
                  'homeserver': matrixProfile['issuer'],
                  'user_id': matrixProfile['user_id'],
                };
              })(),
              _ => {
                'groups': [],
                'recent': [],
                'friends': [],
                'requests': [],
                'blocked': [],
              },
            };
            return http.Response(jsonEncode(value), 200);
          }),
        )
        ..user = {...matrixProfile, 'username': 'Alice'}
        ..loading = false;
}

void main() {
  setUp(() => FlutterSecureStorage.setMockInitialValues({}));

  for (final width in [320.0, 1200.0]) {
    testWidgets(
      'first login requires Matrix before opening conversations at $width',
      (tester) async {
        await tester.binding.setSurfaceSize(Size(width, 760));
        addTearDown(() => tester.binding.setSurfaceSize(null));
        final f = SetupFixture();
        await tester.pumpWidget(RiverApp(api: f.api, boot: false));
        await tester.pumpAndSettle();
        expect(
          find.byKey(const ValueKey('required-matrix-setup')),
          findsOneWidget,
        );
        expect(find.byType(RiverShell), findsNothing);
        expect(find.byType(RichComposer), findsNothing);
        expect(f.launches, 0);
        await tester.binding.handlePopRoute();
        await tester.pumpAndSettle();
        expect(
          find.byKey(const ValueKey('required-matrix-setup')),
          findsOneWidget,
        );
        await tester.tap(find.byKey(const ValueKey('complete-matrix-setup')));
        await tester.pumpAndSettle();
        expect(f.api.matrixConnected, true);
        expect(f.launches, 1);
        expect(
          find.byKey(const ValueKey('required-matrix-setup')),
          findsNothing,
        );
        expect(find.byType(RiverShell), findsOneWidget);
        await tester.pumpWidget(const SizedBox());
      },
    );
  }

  testWidgets('failed browser approval stays in setup and can retry', (
    tester,
  ) async {
    final f = SetupFixture()..openBrowser = false;
    await tester.pumpWidget(RiverApp(api: f.api, boot: false));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('complete-matrix-setup')));
    await tester.pumpAndSettle();
    expect(find.byType(RiverShell), findsNothing);
    expect(
      find.text('Matrix sign-in failed. Please try again.'),
      findsOneWidget,
    );
    f.openBrowser = true;
    await tester.tap(find.byKey(const ValueKey('complete-matrix-setup')));
    await tester.pumpAndSettle();
    expect(f.api.matrixConnected, true);
    expect(find.byType(RiverShell), findsOneWidget);
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('cancelled Matrix approval never unlocks the account', (
    tester,
  ) async {
    final f = SetupFixture()..poll = Completer<void>();
    await tester.pumpWidget(RiverApp(api: f.api, boot: false));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('complete-matrix-setup')));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 50));
    await tester.tap(find.text('Cancel connection'));
    await tester.pump();
    f.poll!.complete();
    await tester.pumpAndSettle();
    expect(f.api.matrixConnected, false);
    expect(find.byType(RiverShell), findsNothing);
    expect(find.byKey(const ValueKey('required-matrix-setup')), findsOneWidget);
    expect(
      tester
          .widget<FilledButton>(
            find.byKey(const ValueKey('complete-matrix-setup')),
          )
          .onPressed,
      isNotNull,
    );
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets(
    'a restored Matrix device opens River without a second approval',
    (tester) async {
      final f = SetupFixture();
      await f.api.connectMessaging();
      expect(f.launches, 1);
      final restored =
          RiverApi(
              live: false,
              matrixEnabled: true,
              matrixStorage: f.storage,
              matrixFactory: (_) async => FakeMatrixTransport(),
            )
            ..user = Map.of(matrixProfile)
            ..loading = false;
      await restored.matrix.bind(matrixProfile);
      await tester.pumpWidget(RiverApp(api: restored, boot: false));
      await tester.pumpAndSettle();
      expect(find.byKey(const ValueKey('required-matrix-setup')), findsNothing);
      expect(find.byType(RiverShell), findsOneWidget);
      expect(f.launches, 1);
      await tester.pumpWidget(const SizedBox());
      f.api.dispose();
    },
  );

  testWidgets('signing out from required setup returns to login', (
    tester,
  ) async {
    final f = SetupFixture();
    await tester.pumpWidget(RiverApp(api: f.api, boot: false));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Sign out'));
    await tester.pumpAndSettle();
    expect(f.api.user, isNull);
    expect(find.text('🔥'), findsOneWidget);
    expect(find.byKey(const ValueKey('required-matrix-setup')), findsNothing);
    await tester.pumpWidget(const SizedBox());
  });
}
