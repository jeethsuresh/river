import 'dart:async';
import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:river/api.dart';
import 'package:river/connection_health.dart';
import 'package:river/main.dart';

import 'matrix_messaging_test.dart' show MemoryMatrixStorage, matrixProfile;
import 'messaging_flows_test.dart' show FlowTransport, device;

void main() {
  setUp(() => FlutterSecureStorage.setMockInitialValues({}));

  testWidgets(
    'short API errors stay quiet; sustained errors show a scoped warning',
    (tester) async {
      var status = 503;
      final api =
          RiverApi(
              live: false,
              client: MockClient((_) async => http.Response('{}', status)),
            )
            ..loading = false
            ..user = {'sub': 'alice', 'username': 'Alice'};
      await tester.pumpWidget(RiverApp(api: api, boot: false));
      await expectLater(api.request('/api/test'), throwsA(isA<ApiException>()));
      await tester.pump();
      expect(api.reconnecting, isTrue);
      expect(api.networkUnavailable, isFalse);
      expect(find.byKey(const ValueKey('network-unavailable')), findsNothing);
      await tester.pump(ConnectionHealth.grace);
      expect(find.byKey(const ValueKey('network-unavailable')), findsNothing);
      await expectLater(api.request('/api/test'), throwsA(isA<ApiException>()));
      await tester.pumpAndSettle();
      expect(find.text('River is reconnecting…'), findsOneWidget);
      expect(find.text('Network unavailable'), findsNothing);
      expect(api.readOnly, isFalse);
      status = 200;
      await api.request('/api/test');
      await tester.pumpAndSettle();
      expect(find.byKey(const ValueKey('network-unavailable')), findsNothing);
      await tester.pumpWidget(const SizedBox());
    },
  );

  testWidgets(
    'a delayed API failure does not override a newer healthy response',
    (tester) async {
      final slow = Completer<http.Response>();
      final api = RiverApi(
        live: false,
        client: MockClient(
          (r) => r.url.path == '/api/overview'
              ? slow.future
              : Future.value(http.Response('{}', 200)),
        ),
      );
      addTearDown(api.dispose);
      final pending = api.refresh();
      await api.request('/api/healthy');
      slow.complete(http.Response('{}', 503));
      await pending;
      expect(api.reconnecting, isFalse);
      expect(api.error, isNull);
      await tester.pump(const Duration(seconds: 30));
      expect(api.connectionWarning, isNull);
    },
  );

  testWidgets(
    'Matrix warnings survive healthy API responses and Retry syncs messaging',
    (tester) async {
      final engine = FlowTransport();
      final saved = await device(engine);
      final api =
          RiverApi(
              live: false,
              matrixEnabled: true,
              matrixStorage: saved.storage,
              matrixFactory: (_) async => engine,
              client: MockClient(
                (r) async => http.Response(
                  jsonEncode({
                    'groups': [],
                    'recent': [],
                    'friends': [],
                    'requests': [],
                    'blocked': [],
                  }),
                  200,
                ),
              ),
            )
            ..loading = false
            ..user = matrixProfile;
      await api.matrix.bind(matrixProfile);
      saved.dispose();
      await tester.pumpWidget(RiverApp(api: api, boot: false));
      engine.offline = true;
      await expectLater(api.matrix.syncNow(), throwsStateError);
      await tester.pump();
      expect(api.connectionWarning, isNull);
      await tester.pump(ConnectionHealth.grace);
      await expectLater(api.matrix.syncNow(), throwsStateError);
      await tester.pumpAndSettle();
      expect(find.text('Matrix messaging is reconnecting…'), findsOneWidget);
      await api.request('/api/healthy');
      await tester.pumpAndSettle();
      expect(find.text('Matrix messaging is reconnecting…'), findsOneWidget);
      engine.offline = false;
      await tester.tap(find.text('Retry'));
      await tester.pumpAndSettle();
      expect(api.reconnecting, isFalse);
      expect(find.byKey(const ValueKey('network-unavailable')), findsNothing);
      expect(engine.syncs, greaterThanOrEqualTo(3));
      await tester.pumpWidget(const SizedBox());
    },
  );

  testWidgets(
    'a River outage does not put healthy Matrix messaging into read-only mode',
    (tester) async {
      var status = 503;
      final engine = FlowTransport();
      final saved = await device(engine);
      final api = RiverApi(
        live: false,
        matrixEnabled: true,
        matrixStorage: saved.storage,
        matrixFactory: (_) async => engine,
        client: MockClient((_) async => http.Response('{}', status)),
      )..user = matrixProfile;
      addTearDown(api.dispose);
      await api.matrix.bind(matrixProfile);
      saved.dispose();
      await expectLater(api.request('/api/test'), throwsA(isA<ApiException>()));
      await tester.pump(ConnectionHealth.grace);
      await expectLater(api.request('/api/test'), throwsA(isA<ApiException>()));
      expect(api.connectionWarning, 'River is reconnecting…');
      expect(api.readOnly, isFalse);
      await api.matrix.syncNow();
      expect(api.connectionWarning, 'River is reconnecting…');
      engine.offline = true;
      await expectLater(api.matrix.syncNow(), throwsStateError);
      await tester.pump(ConnectionHealth.grace);
      await expectLater(api.matrix.syncNow(), throwsStateError);
      expect(
        api.connectionWarning,
        'River and Matrix messaging are reconnecting…',
      );
      status = 200;
      await api.request('/api/test');
      expect(api.connectionWarning, 'Matrix messaging is reconnecting…');
      engine.offline = false;
      await api.matrix.syncNow();
      expect(api.connectionWarning, isNull);
    },
  );

  testWidgets('permission errors do not turn into connection warnings', (
    tester,
  ) async {
    final api = RiverApi(
      live: false,
      matrixStorage: MemoryMatrixStorage(),
      client: MockClient(
        (_) async => http.Response('{"error":"forbidden"}', 403),
      ),
    );
    addTearDown(api.dispose);
    await expectLater(
      api.request('/api/friends'),
      throwsA(isA<ApiException>()),
    );
    await tester.pump(const Duration(seconds: 30));
    expect(api.reconnecting, isFalse);
    expect(api.connectionWarning, isNull);
  });

  testWidgets('permission errors remain visible while Matrix reconnects', (
    tester,
  ) async {
    final engine = FlowTransport();
    final saved = await device(engine);
    final api =
        RiverApi(
            live: false,
            matrixEnabled: true,
            matrixStorage: saved.storage,
            matrixFactory: (_) async => engine,
            client: MockClient(
              (_) async => http.Response('{"error":"forbidden"}', 403),
            ),
          )
          ..loading = false
          ..user = matrixProfile;
    await api.matrix.bind(matrixProfile);
    saved.dispose();
    engine.offline = true;
    await expectLater(api.matrix.syncNow(), throwsStateError);
    await tester.pump(ConnectionHealth.grace);
    await expectLater(api.matrix.syncNow(), throwsStateError);
    await api.refresh();
    await tester.pumpWidget(RiverApp(api: api, boot: false));
    await tester.pumpAndSettle();
    expect(find.text('Matrix messaging is reconnecting…'), findsOneWidget);
    expect(
      find.text('You no longer have permission for this action.'),
      findsOneWidget,
    );
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets(
    'old Matrix reads cannot undo recovery or affect a disconnected account',
    (tester) async {
      final matrix = await device(FlowTransport());
      await matrix.bind(matrixProfile);
      final delayed = Completer<Json>();
      final reading = expectLater(
        matrix.readNetwork((_) => delayed.future),
        throwsStateError,
      );
      await matrix.syncNow();
      delayed.completeError(StateError('RIVER_NETWORK_UNAVAILABLE'));
      await reading;
      expect(matrix.reconnecting, isFalse);
      final priorAccount = Completer<Json>();
      final oldRead = expectLater(
        matrix.readNetwork((_) => priorAccount.future),
        throwsStateError,
      );
      await matrix.disconnect();
      priorAccount.completeError(StateError('RIVER_NETWORK_UNAVAILABLE'));
      await oldRead;
      expect(matrix.reconnecting, isFalse);
      expect(matrix.networkUnavailable, isFalse);
      matrix.dispose();
    },
  );
}
