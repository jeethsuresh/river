import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:river/api.dart';
import 'package:river/workspace_widgets.dart';

class PickerApi extends RiverApi {
  PickerApi() : super(live: false, matrixEnabled: false);
  List<String>? chosen;
  String? contextId;
  @override
  Future<void> conversation(
    String name,
    List<String> members, {
    String? contextId,
  }) async {
    chosen = members;
    this.contextId = contextId;
  }
}

void main() {
  testWidgets(
    'space picker selects group members independently of contacts and excludes self',
    (tester) async {
      tester.view.physicalSize = const Size(390, 844);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      final api = PickerApi()
        ..user = {'sub': 'alice', 'user_id': '@alice:gravitas.cool'};
      final group = <String, dynamic>{
        'id': 'space',
        'name': 'Workshop',
        'members': [
          {
            'principal_id': 'alice',
            'username': 'Alice',
            'user_id': '@alice:gravitas.cool',
          },
          {
            'principal_id': 'bob',
            'username': 'Bob',
            'user_id': '@bob:gravitas.cool',
          },
        ],
      };
      await tester.pumpWidget(
        MaterialApp(
          home: Builder(
            builder: (context) => Scaffold(
              body: TextButton(
                onPressed: () => showDialog<void>(
                  context: context,
                  builder: (_) =>
                      ConversationPicker(app: api, contextGroup: group),
                ),
                child: const Text('Open'),
              ),
            ),
          ),
        ),
      );
      await tester.tap(find.text('Open'));
      await tester.pumpAndSettle();
      expect(api.friends, isEmpty);
      expect(find.text('Bob'), findsOneWidget);
      expect(find.text('Alice'), findsNothing);
      expect(find.text('Find a group member'), findsOneWidget);
      await tester.tap(find.text('Bob'));
      await tester.pump();
      await tester.tap(find.text('Start conversation'));
      await tester.pumpAndSettle();
      expect(api.chosen, ['@bob:gravitas.cool']);
      expect(api.contextId, 'space');
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox());
      api.dispose();
    },
  );

  test(
    'single-peer contextual conversation does not reuse a private DM',
    () async {
      Json? submitted;
      final api = RiverApi(
        live: false,
        matrixEnabled: false,
        client: MockClient((r) async {
          expect(r.url.path, '/api/conversations');
          submitted = jsonDecode(r.body) as Json;
          return http.Response('{"id":"new-conversation"}', 200);
        }),
      );
      // No signed-in account means opening the result needs no background refresh.
      await api.conversation('Planning', [
        '@bob:gravitas.cool',
      ], contextId: 'space');
      expect(submitted?['context_id'], 'space');
      expect(submitted?['member_ids'], ['@bob:gravitas.cool']);
      expect(api.selected, 'new-conversation');
      api.dispose();
    },
  );

  testWidgets(
    'hierarchy shows authorized containment separately from context placement',
    (tester) async {
      final api = RiverApi(
        live: false,
        matrixEnabled: false,
        client: MockClient((r) async {
          expect(r.url.path, '/api/groups/conversation/subgroups');
          return http.Response(
            jsonEncode({
              'participant_count': 2,
              'containing_groups': [
                {'id': 'containing', 'name': 'Shared group'},
              ],
              'contained_groups': [],
              'same_participant_groups': [],
            }),
            200,
          );
        }),
      );
      String? opened;
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: SubgroupDetails(
              app: api,
              group: const {
                'id': 'conversation',
                'name': 'Planning',
                'context_id': 'other',
              },
              open: (id) => opened = id,
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      expect(find.text('2 participants'), findsOneWidget);
      expect(find.text('Shared group'), findsOneWidget);
      expect(find.text('other'), findsNothing);
      await tester.tap(find.text('Shared group'));
      expect(opened, 'containing');
      await tester.pumpWidget(const SizedBox());
      api.dispose();
    },
  );
}
