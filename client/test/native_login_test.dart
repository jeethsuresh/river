import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:river/api.dart';
import 'package:river/main.dart';

import 'matrix_messaging_test.dart'
    show FakeMatrixTransport, MemoryMatrixStorage, matrixProfile;

class NativeLoginFixture {
  final approval = Completer<http.Response>();
  final polling = Completer<void>();
  int sessionReads = 0;
  int pollFailures = 0;
  bool sessionUnavailable = false;
  bool sessionRejected = false;
  Json? brokerResponse;
  bool brokerRejected = false;
  int browserLaunches = 0;
  int brokerExchanges = 0;
  late final api = RiverApi(
    live: false,
    matrixEnabled: true,
    matrixStorage: MemoryMatrixStorage(),
    matrixFactory: (_) async => FakeMatrixTransport(),
    authLaunch: (_) async {
      browserLaunches++;
      return true;
    },
    brokerAuthorize: (challenge, state, username) async {
      expectSync(challenge.length, 43);
      expectSync(state.length, 43);
      return brokerResponse;
    },
    client: MockClient((request) async {
      switch (request.url.path) {
        case '/api/native/broker':
          brokerExchanges++;
          final body = jsonDecode(request.body) as Map;
          expectSync(body['code_verifier'], hasLength(43));
          expectSync(body['sub'], 'alice');
          return brokerRejected
              ? http.Response('{"error":"broker_login_failed"}', 403)
              : http.Response('{"session":"approved-session"}', 200);
        case '/api/native/new':
          return http.Response(
            jsonEncode({
              'id': 'pending',
              'label': 'ABC123',
              'url': 'https://chat.gravitas.cool/auth/native/start?id=pending',
            }),
            200,
          );
        case '/api/native/session':
          if (!polling.isCompleted) polling.complete();
          if (pollFailures > 0) {
            pollFailures--;
            throw http.ClientException('Android suspended the connection');
          }
          return approval.future;
        case '/api/session':
          sessionReads++;
          expectSync(
            request.headers['Authorization'],
            'Bearer approved-session',
          );
          if (sessionRejected) {
            return http.Response('{"error":"login required"}', 401);
          }
          return sessionUnavailable
              ? http.Response('{"error":"temporarily_unavailable"}', 503)
              : http.Response(jsonEncode({'user': matrixProfile}), 200);
        case '/api/overview':
          return http.Response('{"groups":[],"recent":[]}', 200);
        case '/api/session/refresh':
          return http.Response('{"error":"login required"}', 401);
        default:
          return http.Response(
            '{"friends":[],"requests":[],"blocked":[]}',
            200,
          );
      }
    }),
  )..loading = false;
}

void main() {
  setUp(() => FlutterSecureStorage.setMockInitialValues({}));

  testWidgets('browser device approval reaches required messaging setup', (
    tester,
  ) async {
    final f = NativeLoginFixture();
    await tester.pumpWidget(RiverApp(api: f.api, boot: false));
    await tester.enterText(find.byType(TextField), 'alice');
    await tester.tap(find.text('🔥'));
    await tester.pump();
    await f.polling.future;
    f.approval.complete(http.Response('{"session":"approved-session"}', 200));
    await tester.pumpAndSettle();
    expect(f.api.user, matrixProfile);
    expect(find.byKey(const ValueKey('required-matrix-setup')), findsOneWidget);
    expect(find.text('🔥'), findsNothing);
    expect(await f.api.storage.read(key: 'river_native_pending'), isNull);
    expect(await f.api.storage.read(key: 'river_session'), 'approved-session');
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets(
    'signed-in Private Store completes account login without a browser',
    (tester) async {
      final f = NativeLoginFixture()
        ..brokerResponse = {
          'code': 'one-use-code',
          'sub': 'alice',
          'session_id': '11111111-1111-4111-8111-111111111111',
        };
      await tester.pumpWidget(RiverApp(api: f.api, boot: false));
      await tester.enterText(find.byType(TextField), 'alice');
      await tester.tap(find.text('🔥'));
      await tester.pumpAndSettle();
      expect(f.api.user, matrixProfile);
      expect(f.brokerExchanges, 1);
      expect(f.browserLaunches, 0);
      expect(
        find.byKey(const ValueKey('required-matrix-setup')),
        findsOneWidget,
      );
      expect(await f.api.storage.read(key: 'river_native_pending'), isNull);
      await tester.pumpWidget(const SizedBox());
    },
  );

  testWidgets('broker rejection falls back to normal browser approval', (
    tester,
  ) async {
    final f = NativeLoginFixture()
      ..brokerResponse = {
        'code': 'one-use-code',
        'sub': 'alice',
        'session_id': '11111111-1111-4111-8111-111111111111',
      }
      ..brokerRejected = true;
    await tester.pumpWidget(RiverApp(api: f.api, boot: false));
    await tester.enterText(find.byType(TextField), 'alice');
    await tester.tap(find.text('🔥'));
    await tester.pump();
    await f.polling.future;
    f.approval.complete(http.Response('{"session":"approved-session"}', 200));
    await tester.pumpAndSettle();
    expect(f.api.user, matrixProfile);
    expect(f.brokerExchanges, 1);
    expect(f.browserLaunches, 1);
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('resume retries loading a device session after an IAM outage', (
    tester,
  ) async {
    final f = NativeLoginFixture()..sessionUnavailable = true;
    await tester.pumpWidget(RiverApp(api: f.api, boot: false));
    await tester.enterText(find.byType(TextField), 'alice');
    await tester.tap(find.text('🔥'));
    await tester.pump();
    await f.polling.future;
    f.approval.complete(http.Response('{"session":"approved-session"}', 200));
    await tester.pumpAndSettle();
    expect(f.api.token, 'approved-session');
    expect(f.api.user, isNull);
    expect(await f.api.storage.read(key: 'river_native_pending'), isNull);
    expect(find.byKey(const ValueKey('finish-native-sign-in')), findsOneWidget);
    expect(find.text('Retry sign-in'), findsOneWidget);
    expect(find.text('🔥'), findsNothing);

    f.sessionUnavailable = false;
    await f.api.resumeAuthentication();
    await tester.pumpAndSettle();
    expect(f.api.user, matrixProfile);
    expect(find.byKey(const ValueKey('required-matrix-setup')), findsOneWidget);
    expect(find.text('🔥'), findsNothing);
    expect(f.sessionReads, greaterThan(1));
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('a suspended browser approval poll retries its saved verifier', (
    tester,
  ) async {
    final f = NativeLoginFixture()..pollFailures = 1;
    await tester.pumpWidget(RiverApp(api: f.api, boot: false));
    await tester.enterText(find.byType(TextField), 'alice');
    await tester.tap(find.text('🔥'));
    await tester.pump();
    await f.polling.future;
    expect(await f.api.storage.read(key: 'river_native_pending'), isNotNull);
    f.approval.complete(http.Response('{"session":"approved-session"}', 200));
    await tester.pump(const Duration(seconds: 2));
    await tester.pumpAndSettle();
    expect(f.api.user, matrixProfile);
    expect(find.byKey(const ValueKey('required-matrix-setup')), findsOneWidget);
    expect(await f.api.storage.read(key: 'river_native_pending'), isNull);
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('retry completes sign-in without requesting another approval', (
    tester,
  ) async {
    final f = NativeLoginFixture()..sessionUnavailable = true;
    await tester.pumpWidget(RiverApp(api: f.api, boot: false));
    final signingIn = f.api.login(username: 'alice');
    await tester.pump();
    await f.polling.future;
    f.approval.complete(http.Response('{"session":"approved-session"}', 200));
    await tester.pumpAndSettle();
    await signingIn;
    expect(find.byKey(const ValueKey('finish-native-sign-in')), findsOneWidget);
    expect(f.api.error, isNull);
    f.sessionUnavailable = false;
    await tester.tap(find.text('Retry sign-in'));
    await tester.pumpAndSettle();
    expect(f.api.user, matrixProfile);
    expect(find.byKey(const ValueKey('required-matrix-setup')), findsOneWidget);
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('an expired approval reports the failure beside the username', (
    tester,
  ) async {
    final f = NativeLoginFixture();
    await tester.pumpWidget(RiverApp(api: f.api, boot: false));
    await tester.enterText(find.byType(TextField), 'alice');
    await tester.tap(find.text('🔥'));
    await tester.pump();
    await f.polling.future;
    f.approval.complete(http.Response('{"error":"expired"}', 403));
    await tester.pumpAndSettle();
    expect(f.api.user, isNull);
    expect(f.api.token, isNull);
    expect(find.text('Unable to connect. Please try again.'), findsOneWidget);
    expect(await f.api.storage.read(key: 'river_native_pending'), isNull);
    expect(f.api.pairingLabel, isNull);
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('a rejected session requires a fresh sign-in', (tester) async {
    final f = NativeLoginFixture()..sessionRejected = true;
    await tester.pumpWidget(RiverApp(api: f.api, boot: false));
    final signingIn = f.api.login(username: 'alice');
    await tester.pump();
    await f.polling.future;
    f.approval.complete(http.Response('{"session":"approved-session"}', 200));
    await tester.pumpAndSettle();
    await signingIn;
    expect(f.sessionReads, 1, reason: '${f.api.error}');
    expect(f.api.token, isNull);
    expect(f.api.user, isNull);
    expect(await f.api.storage.read(key: 'river_session'), isNull);
    expect(find.byKey(const ValueKey('finish-native-sign-in')), findsNothing);
    expect(find.text('🔥'), findsOneWidget);
    await tester.pumpWidget(const SizedBox());
  });

  test(
    'logout during Store authorization cannot restore the account',
    () async {
      final approval = Completer<Json?>();
      final api = RiverApi(
        live: false,
        brokerAuthorize: (_, _, _) => approval.future,
        client: MockClient(
          (_) async => throw StateError('Unexpected exchange'),
        ),
      );
      final signingIn = api.login(username: 'alice');
      final rejected = expectLater(
        signingIn,
        throwsA(
          isA<ApiException>().having((e) => e.code, 'code', 'session_changed'),
        ),
      );
      await api.logout();
      approval.complete({
        'code': 'one-use',
        'sub': 'alice',
        'session_id': 'family',
      });
      await rejected;
      expect(api.user, isNull);
      expect(await api.storage.read(key: 'river_session'), isNull);
      api.dispose();
    },
  );
}
