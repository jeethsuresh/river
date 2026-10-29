import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:river/api.dart';
import 'package:river/main.dart';
import 'package:river/friends_view.dart';

http.Response response(Json data) => http.Response(jsonEncode(data), 200);
const bob = {
  'username': 'bob',
  'user_id': '@bob:gravitas.cool',
  'uses_app': true,
};
const carol = {
  'username': 'carol',
  'user_id': '@carol:gravitas.cool',
  'uses_app': false,
};
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  FlutterSecureStorage.setMockInitialValues({});
  test(
    'login reads existing shared contacts without sending friend requests',
    () async {
      final methods = <String>[];
      var connected = true;
      final api = RiverApi(
        client: MockClient((r) async {
          methods.add(r.method);
          if (r.url.path == '/api/session') {
            return response({
              'user': {'sub': 'alice', 'username': 'alice'},
            });
          }
          if (r.url.path == '/api/overview') {
            return response({'groups': [], 'recent': []});
          }
          if (r.url.path == '/api/friends') {
            return response({
              'friends': connected ? [bob] : [],
              'other_contacts': connected ? [carol] : [bob, carol],
              'requests': [],
              'blocked': [],
            });
          }
          throw StateError('Unexpected path: ${r.url.path}');
        }),
      );
      await api.boot();
      expect(api.friends.single['username'], 'bob');
      expect(api.otherContacts.single['username'], 'carol');
      expect(api.requests, isEmpty);
      expect(methods.every((m) => m == 'GET'), isTrue);
      // Revoking the peer's app permission changes the projection, not the contact.
      connected = false;
      await api.refresh();
      expect(api.friends, isEmpty);
      expect(api.otherContacts, hasLength(2));
      api.dispose();
    },
  );

  testWidgets(
    'shared contacts and friends are clear at phone, tablet and desktop widths',
    (tester) async {
      for (final width in [320.0, 768.0, 1440.0]) {
        await tester.binding.setSurfaceSize(Size(width, 1200));
        final api = RiverApi(matrixEnabled: false)
          ..user = {'sub': 'alice'}
          ..loading = false
          ..friends = [bob]
          ..otherContacts = [carol];
        await tester.pumpWidget(
          MaterialApp(
            home: Scaffold(
              body: FriendsView(app: api, onConversation: () {}),
            ),
          ),
        );
        expect(
          find.textContaining(
            'Contact requests, removals and blocks apply across your apps.',
          ),
          findsOneWidget,
        );
        await tester.ensureVisible(find.text('bob'));
        expect(find.text('Message'), findsOneWidget);
        await tester.ensureVisible(find.text('carol'));
        await tester.pumpAndSettle();
        expect(find.text('Other Gravitas contacts · 1'), findsOneWidget);
        expect(find.text('Remove contact everywhere'), findsWidgets);
        expect(tester.takeException(), isNull);
        await tester.pumpWidget(const SizedBox());
        api.dispose();
      }
      await tester.binding.setSurfaceSize(null);
    },
  );

  testWidgets(
    'expired contact consent keeps shared lists private and offers reconnect',
    (tester) async {
      final api = RiverApi(matrixEnabled: false)
        ..user = {'sub': 'alice'}
        ..loading = false
        ..friendsStatus = 403
        ..friendsError =
            'Reconnect with Gravitas to approve the new permissions.';
      await tester.binding.setSurfaceSize(const Size(390, 900));
      await tester.pumpWidget(RiverApp(api: api, boot: false));
      expect(
        find.text(
          'Reconnect with Gravitas to approve contacts access and find your River friends.',
        ),
        findsOneWidget,
      );
      expect(find.text('Reconnect'), findsOneWidget);
      await tester.pumpWidget(const SizedBox());
      await tester.binding.setSurfaceSize(null);
    },
  );
}
