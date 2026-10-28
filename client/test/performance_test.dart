import 'dart:convert';
import 'dart:async' show Completer;
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:river/api.dart';
import 'package:river/performance.dart';

void main() {
  test(
    'conversation opens while an unrelated account refresh is blocked',
    () async {
      final contacts = Completer<void>();
      final api = RiverApi(
        live: false,
        client: MockClient((r) async {
          if (r.url.path == '/api/friends') {
            await contacts.future;
            return http.Response(
              '{"friends":[],"requests":[],"blocked":[]}',
              200,
            );
          }
          if (r.url.path == '/api/overview') {
            return http.Response(
              '{"groups":[{"id":"room","kind":"group","membership":"join"}],"recent":[]}',
              200,
            );
          }
          return http.Response(
            '{"events":[{"event_id":"message","origin_server_ts":1}],"next_cursor":null}',
            200,
          );
        }),
      );
      api.user = {'issuer': 'https://example.org', 'sub': 'alice'};
      api.groups = [
        {'id': 'room', 'kind': 'group', 'membership': 'join'},
      ];
      final refresh = api.refresh();
      await Future<void>.delayed(Duration.zero);
      expect(api.busy, true);
      await api.open('room').timeout(const Duration(seconds: 1));
      expect(api.events.single['event_id'], 'message');
      contacts.complete();
      await refresh;
      api.dispose();
    },
  );

  test(
    'late history for the same room cannot replace a reopened timeline',
    () async {
      final pages = <Completer<http.Response>>[];
      final api = RiverApi(
        live: false,
        client: MockClient((r) {
          final page = Completer<http.Response>();
          pages.add(page);
          return page.future;
        }),
      );
      api.user = {'issuer': 'https://example.org', 'sub': 'alice'};
      api.groups = [
        for (final id in ['a', 'b']) {'id': id, 'membership': 'join'},
      ];
      final first = api.open('a');
      await Future<void>.delayed(Duration.zero);
      final second = api.open('b');
      await Future<void>.delayed(Duration.zero);
      final current = api.open('a');
      await Future<void>.delayed(Duration.zero);
      http.Response page(String id) => http.Response(
        jsonEncode({
          'events': [
            {'event_id': id, 'origin_server_ts': 1},
          ],
        }),
        200,
      );
      pages[2].complete(page('current'));
      await current;
      pages[0].complete(page('stale'));
      pages[1].complete(page('other'));
      await Future.wait([first, second]);
      expect(api.events.single['event_id'], 'current');
      api.dispose();
    },
  );

  test('latency samples are bounded and record failures', () async {
    RiverPerformance.clear();
    for (var n = 0; n < 300; n++) {
      await RiverPerformance.measure('fixture', () async {});
    }
    await expectLater(
      RiverPerformance.measure('failure', () async {
        throw StateError('fixture');
      }),
      throwsStateError,
    );
    final snapshot = RiverPerformance.snapshot();
    expect((snapshot['fixture'] as Map)['count'], 255);
    expect((snapshot['failure'] as Map)['failures'], 1);
    RiverPerformance.clear();
  });

  test('profile foreground operations over a delayed network', () async {
    final paths = <String>[];
    final api = RiverApi(
      live: true,
      matrixEnabled: false,
      client: MockClient((r) async {
        paths.add(r.url.path);
        await Future<void>.delayed(const Duration(milliseconds: 40));
        return http.Response(
          jsonEncode(switch (r.url.path) {
            '/api/overview' => {
              'groups': [
                {
                  'id': 'room',
                  'kind': 'group',
                  'membership': 'join',
                  'members': [],
                },
              ],
              'recent': [],
            },
            '/api/home' => {
              'catch_up': [],
              'threads': [],
              'recent_entries': [],
            },
            '/api/friends' => {'friends': [], 'requests': [], 'blocked': []},
            '/api/calls' => {'calls': []},
            '/api/presence' => {'online': []},
            '/api/groups/room/events' => {'events': [], 'next_cursor': null},
            _ => {'event_id': r'$sent'},
          }),
          200,
        );
      }),
    );
    api.user = {
      'issuer': 'https://example.org',
      'sub': 'alice',
      'user_id': '@alice:example.org',
    };
    await api.refresh();
    paths.clear();
    final watch = Stopwatch()..start();
    await api.open('room');
    // ignore: avoid_print
    print(
      'PERF open_us=${watch.elapsedMicroseconds} requests=${paths.length} paths=$paths',
    );
    expect(paths, ['/api/groups/room/events']);
    paths.clear();
    watch.reset();
    await api.send('room', 'm.room.message', {
      'body': 'fixture',
      'msgtype': 'm.text',
    }, 'txn');
    // ignore: avoid_print
    print(
      'PERF send_us=${watch.elapsedMicroseconds} requests=${paths.length} paths=$paths',
    );
    expect(paths, ['/api/groups/room/events/m.room.message/txn']);
    expect(api.events.single['event_id'], r'$sent');
    api.dispose();
  });
}
