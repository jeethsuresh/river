import 'dart:async';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:river/live_updates.dart';

void main() {
  test('expired live access renews on reconnect without logging out', () async {
    var preparations = 0, requests = 0, logouts = 0;
    final stream = StreamController<List<int>>();
    final live = LiveUpdates(
      url: Uri.parse('https://example.org/api/live'),
      prepare: () async {
        preparations++;
      },
      headers: () => {},
      changed: () {},
      revoked: () {
        logouts++;
      },
      client: MockClient.streaming((_, _) async {
        requests++;
        return requests == 1
            ? http.StreamedResponse(Stream.value(<int>[]), 401)
            : http.StreamedResponse(stream.stream, 200);
      }),
    );
    await live.connect();
    await Future<void>.delayed(const Duration(milliseconds: 1100));
    expect(preparations, 2);
    expect(requests, 2);
    expect(logouts, 0);
    live.close();
    await stream.close();
  });

  test(
    'a revoked event rechecks the session and outages keep credentials',
    () async {
      var preparations = 0, logouts = 0;
      final stream = StreamController<List<int>>();
      final live = LiveUpdates(
        url: Uri.parse('https://example.org/api/live'),
        prepare: () async {
          preparations++;
          if (preparations > 1) throw StateError('temporarily unavailable');
        },
        headers: () => {},
        changed: () {},
        revoked: () {
          logouts++;
        },
        client: MockClient.streaming(
          (_, _) async => http.StreamedResponse(stream.stream, 200),
        ),
      );
      await live.connect();
      stream.add('event: revoked\n\n'.codeUnits);
      await Future<void>.delayed(Duration.zero);
      await Future<void>.delayed(const Duration(milliseconds: 1100));
      expect(preparations, 2);
      expect(logouts, 0);
      live.close();
      await stream.close();
    },
  );
}
