import 'dart:async';
import 'dart:convert';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:river/api.dart';

void main() {
  test(
    'refresh requested during an in-flight read waits for its fresh read',
    () async {
      final firstRead = Completer<void>();
      var overviewReads = 0;
      final api = RiverApi(
        live: false,
        client: MockClient((r) async {
          if (r.url.path == '/api/overview') {
            final read = ++overviewReads;
            if (read == 1) await firstRead.future;
            return http.Response(
              jsonEncode({
                'groups': [
                  {'id': 'room', 'kind': 'space', 'name': 'snapshot $read'},
                ],
                'recent': [],
              }),
              200,
            );
          }
          return http.Response(
            '{"friends":[],"requests":[],"blocked":[]}',
            200,
          );
        }),
      );
      api.user = {'issuer': 'https://gravitas.cool', 'sub': 'alice'};
      final initial = api.refresh();
      await Future<void>.delayed(Duration.zero);
      var secondFinished = false;
      final afterMutation = api.refresh().then((_) {
        secondFinished = true;
      });
      await Future<void>.delayed(Duration.zero);
      expect(
        secondFinished,
        isFalse,
        reason:
            'An action must not observe stale state while its requested refresh is still queued.',
      );
      firstRead.complete();
      await Future.wait([initial, afterMutation]);
      expect(overviewReads, 2);
      expect(api.groups.single['name'], 'snapshot 2');
      api.dispose();
    },
  );
}
