import 'dart:async';
import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:flutter_quill/flutter_quill.dart' as q;
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:river/api.dart';
import 'package:river/content_widgets.dart';
import 'package:river/rich_composer.dart';

void main() {
  testWidgets('post policy persists before waiting for the final snapshot', (
    tester,
  ) async {
    final snapshot = Completer<void>();
    var reads = 0;
    final writes = <String>[];
    final api = RiverApi(
      client: MockClient((r) async {
        if (r.method == 'PUT') {
          writes.add('entry');
          return http.Response('{"event_id":"post-id"}', 200);
        }
        if (r.url.path.endsWith('/publication')) {
          writes.add('policy');
          expect((jsonDecode(r.body) as Json)['event_id'], 'post-id');
          return http.Response('{}', 200);
        }
        if (r.url.path == '/api/overview') {
          reads++;
          await snapshot.future;
          return http.Response('{"groups":[],"recent":[]}', 200);
        }
        return http.Response('{"friends":[],"requests":[],"blocked":[]}', 200);
      }),
    )..user = {'issuer': 'https://gravitas.cool', 'sub': 'alice'};
    api.groups = [
      {'id': 'space', 'kind': 'space'},
    ];
    await tester.binding.setSurfaceSize(const Size(1000, 1000));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    await tester.pumpWidget(
      MaterialApp(
        localizationsDelegates:
            q.FlutterQuillLocalizations.localizationsDelegates,
        home: Builder(
          builder: (context) => Scaffold(
            body: TextButton(
              onPressed: () => showDialog<void>(
                context: context,
                builder: (_) => EntryEditor(app: api, room: 'space'),
              ),
              child: const Text('Open'),
            ),
          ),
        ),
      ),
    );
    await tester.tap(find.text('Open'));
    await tester.pumpAndSettle();
    await tester.enterText(
      find.widgetWithText(TextFormField, 'Title'),
      'New post',
    );
    await tester.ensureVisible(
      find.descendant(
        of: find.byType(RichComposer),
        matching: find.text('Markdown'),
      ),
    );
    await tester.tap(
      find.descendant(
        of: find.byType(RichComposer),
        matching: find.text('Markdown'),
      ),
    );
    await tester.pumpAndSettle();
    await tester.enterText(
      find.descendant(
        of: find.byType(RichComposer),
        matching: find.byType(TextField),
      ),
      'Post body',
    );
    await tester.tap(find.text('Post'));
    for (var i = 0; i < 10; i++) {
      await tester.pump(const Duration(milliseconds: 10));
    }
    expect(writes, [
      'entry',
      'policy',
    ], reason: 'A slow read must not block the post visibility policy write.');
    expect(find.byType(EntryEditor), findsOneWidget);
    snapshot.complete();
    await tester.pumpAndSettle();
    expect(reads, 1);
    expect(find.byType(EntryEditor), findsNothing);
    await tester.pumpWidget(const SizedBox());
    api.dispose();
  });
  testWidgets(
    'retry after policy failure edits the persisted post instead of duplicating it',
    (tester) async {
      var entries = 0, edits = 0, policies = 0, reads = 0;
      final api = RiverApi(
        client: MockClient((r) async {
          if (r.method == 'PUT') {
            entries++;
            return http.Response('{"event_id":"post-id"}', 200);
          }
          if (r.url.path.endsWith('/entry')) {
            edits++;
            expect((jsonDecode(r.body) as Json)['event_id'], 'post-id');
            return http.Response('{}', 200);
          }
          if (r.url.path.endsWith('/publication')) {
            policies++;
            expect((jsonDecode(r.body) as Json)['event_id'], 'post-id');
            return policies == 1
                ? http.Response('{"error":"unavailable"}', 503)
                : http.Response('{}', 200);
          }
          if (r.url.path == '/api/overview') {
            reads++;
            return http.Response('{"groups":[],"recent":[]}', 200);
          }
          return http.Response(
            '{"friends":[],"requests":[],"blocked":[]}',
            200,
          );
        }),
      )..user = {'issuer': 'https://gravitas.cool', 'sub': 'alice'};
      api.groups = [
        {'id': 'space', 'kind': 'space'},
      ];
      await tester.binding.setSurfaceSize(const Size(1000, 1000));
      addTearDown(() => tester.binding.setSurfaceSize(null));
      await tester.pumpWidget(
        MaterialApp(
          localizationsDelegates:
              q.FlutterQuillLocalizations.localizationsDelegates,
          home: Builder(
            builder: (context) => Scaffold(
              body: TextButton(
                onPressed: () => showDialog<void>(
                  context: context,
                  builder: (_) => EntryEditor(app: api, room: 'space'),
                ),
                child: const Text('Open'),
              ),
            ),
          ),
        ),
      );
      await tester.tap(find.text('Open'));
      await tester.pumpAndSettle();
      await tester.enterText(
        find.widgetWithText(TextFormField, 'Title'),
        'Kept draft',
      );
      await tester.ensureVisible(
        find.descendant(
          of: find.byType(RichComposer),
          matching: find.text('Markdown'),
        ),
      );
      await tester.tap(
        find.descendant(
          of: find.byType(RichComposer),
          matching: find.text('Markdown'),
        ),
      );
      await tester.pumpAndSettle();
      await tester.enterText(
        find.descendant(
          of: find.byType(RichComposer),
          matching: find.byType(TextField),
        ),
        'Kept body',
      );
      await tester.tap(find.text('Post'));
      await tester.pumpAndSettle();
      expect(find.textContaining('Your draft is kept.'), findsOneWidget);
      expect(entries, 1);
      expect(reads, 0);
      await tester.tap(find.text('Post'));
      await tester.pumpAndSettle();
      expect(entries, 1);
      expect(edits, 1);
      expect(policies, 2);
      expect(reads, 1);
      expect(find.byType(EntryEditor), findsNothing);
      await tester.pumpWidget(const SizedBox());
      api.dispose();
    },
  );
}
