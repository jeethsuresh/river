// Test-only positive browser/IndexedDB/QR interoperability entry point.
import 'dart:convert';
import 'dart:typed_data';
import 'dart:ui' as ui;
import 'package:http/http.dart' as http;
import 'package:river_matrix/river_matrix.dart';
import 'package:web/web.dart' as web;
import 'package:river/matrix_security_widgets.dart' show MatrixQrPainter;

typedef Json = Map<String, dynamic>;
const homeserver = 'https://native.test:8448';
final client = http.Client();
final prefix = DateTime.now().microsecondsSinceEpoch.toString();
var sequence = 0;
Future<Json> request(
  String method,
  String path, {
  Json? body,
  String? token,
}) async {
  final response = await client.send(
    http.Request(method, Uri.parse('$homeserver$path'))
      ..headers.addAll({
        'Content-Type': 'application/json',
        if (token != null) 'Authorization': 'Bearer $token',
      })
      ..body = body == null ? '' : jsonEncode(body),
  );
  final data = jsonDecode(await response.stream.bytesToString()) as Json;
  if (response.statusCode >= 400) {
    throw StateError('Matrix test request failed: ${data['errcode']}');
  }
  return data;
}

Future<Json> login(String device) => request(
  'POST',
  '/_matrix/client/v3/login',
  body: {
    'type': 'm.login.password',
    'identifier': {'type': 'm.id.user', 'user': 'deactclient'},
    'password': 'password123',
    'device_id': 'WEB-$device-$prefix',
  },
);
Future<MatrixConnection> open(Json session, String name) =>
    MatrixConnection.open(
      homeserver: homeserver,
      expectedUser: session['user_id'] as String,
      store: 'river-browser-$prefix-$name',
      storeKey: 'isolated-browser-store-key-$prefix-long-enough',
      session: jsonEncode(session),
    );
Future<void> sync(MatrixConnection engine, Json session) async {
  // A harmless test-only event makes long-polls return immediately, while
  // exercising the exact production binary and its normal 20-second timeout.
  await request(
    'PUT',
    '/_matrix/client/v3/sendToDevice/cool.gravitas.test.heartbeat/$prefix-${sequence++}',
    token: session['access_token'] as String,
    body: {
      'messages': {
        session['user_id']: {session['device_id']: {}},
      },
    },
  );
  await engine.sync_();
}

Future<void> verify(bool condition, String detail) async {
  if (!condition) throw StateError(detail);
}

Future<bool> hasBody(MatrixConnection engine, String room) async {
  final history = jsonDecode(await engine.history(room: room)) as Json;
  return (history['events'] as List).any(
    (e) => e['content']['body'] == 'browser history before QR',
  );
}

Future<void> main() async {
  final result = web.document.createElement('pre')..id = 'matrix-interop';
  web.document.body!.append(result);
  var phase = 'initialize';
  void progress(String value) {
    phase = value;
    result.textContent = 'RIVER_MATRIX_WEB_PENDING: $value';
  }

  progress(phase);
  try {
    await RustLib.init();
    final firstSession = await login('A');
    var first = await open(firstSession, 'A');
    await sync(first, firstSession);
    progress('setup encrypted recovery');
    var setup = jsonDecode(await first.setupRecovery()) as Json;
    if (setup['authentication'] is Map) {
      setup =
          jsonDecode(
                await first.setupRecovery(
                  authentication: jsonEncode({
                    'type': 'm.login.password',
                    'session': setup['authentication']['session'],
                    'identifier': {
                      'type': 'm.id.user',
                      'user': firstSession['user_id'],
                    },
                    'password': 'password123',
                  }),
                ),
              )
              as Json;
    }
    await verify(setup['recovery_key'] is String, 'Recovery was not enabled');
    progress('encrypted send');
    final created = await request(
      'POST',
      '/_matrix/client/v3/createRoom',
      token: firstSession['access_token'] as String,
      body: {
        'initial_state': [
          {
            'type': 'm.room.encryption',
            'state_key': '',
            'content': {'algorithm': 'm.megolm.v1.aes-sha2'},
          },
        ],
      },
    );
    final room = created['room_id'] as String;
    await sync(first, firstSession);
    final sent =
        jsonDecode(
              await first.send(
                room: room,
                eventType: 'm.room.message',
                content: jsonEncode({
                  'msgtype': 'm.text',
                  'body': 'browser history before QR',
                }),
                transaction: 'browser-$prefix',
              ),
            )
            as Json;
    final raw = await request(
      'GET',
      '/_matrix/client/v3/rooms/${Uri.encodeComponent(room)}/event/${Uri.encodeComponent(sent['event_id'] as String)}',
      token: firstSession['access_token'] as String,
    );
    await verify(
      raw['type'] == 'm.room.encrypted' &&
          !jsonEncode(raw['content']).contains('browser history before QR'),
      'Homeserver received plaintext',
    );
    await sync(first, firstSession);
    progress('encrypted IndexedDB reopen');
    final saved = jsonDecode(await first.credentials()) as Json;
    await first.close(logout: false);
    first.dispose();
    first = await open(saved, 'A');
    await sync(first, saved);
    await verify(
      await hasBody(first, room),
      'Encrypted local state was not restored',
    );
    progress('QR verification');
    final secondSession = await login('B');
    final second = await open(secondSession, 'B');
    await sync(second, secondSession);
    final flow =
        (jsonDecode(
                  await first.requestVerification(
                    device: secondSession['device_id'] as String,
                  ),
                )
                as Json)['id']
            as String;
    await sync(second, secondSession);
    await second.verificationAction(flow: flow, action: 'accept');
    await sync(first, saved);
    final code = jsonDecode(await first.verificationQr(flow: flow)) as Json;
    final recorder = ui.PictureRecorder();
    MatrixQrPainter(code).paint(ui.Canvas(recorder), const ui.Size(400, 400));
    final image = await recorder.endRecording().toImage(400, 400);
    final png = await image.toByteData(format: ui.ImageByteFormat.png);
    image.dispose();
    await second.scanVerificationImage(
      flow: flow,
      bytes: png!.buffer.asUint8List(),
    );
    await sync(first, saved);
    final before = jsonDecode(await first.security()) as Json;
    await verify(
      (before['requests'] as List).any(
        (r) => r['id'] == flow && r['scanned'] == true,
      ),
      'The production QR painter was not scanned',
    );
    await verify(
      !(before['devices'] as List).any(
        (d) =>
            d['device_id'] == secondSession['device_id'] &&
            d['verified'] == true,
      ),
      'Scanning granted trust without confirmation',
    );
    await first.verificationAction(flow: flow, action: 'confirm_qr');
    progress('QR key transfer and historical decryption');
    var recovered = false;
    for (var attempt = 0; attempt < 20; attempt++) {
      await sync(second, secondSession);
      await sync(first, saved);
      if (await hasBody(second, room)) {
        recovered = true;
        break;
      }
      await Future<void>.delayed(const Duration(milliseconds: 100));
    }
    await verify(recovered, 'QR did not recover the old encrypted message');
    progress('encrypted attachment');
    final attachment =
        jsonDecode(
              await first.sendAttachment(
                room: room,
                name: 'proof.bin',
                contentType: 'application/octet-stream',
                bytes: Uint8List.fromList([7, 8, 9]),
                transaction: 'file-$prefix',
              ),
            )
            as Json;
    await sync(second, secondSession);
    final history = jsonDecode(await second.history(room: room)) as Json;
    final file =
        (history['events'] as List).firstWhere(
              (e) => e['event_id'] == attachment['event_id'],
            )
            as Json;
    final bytes = await second.downloadAttachment(
      content: jsonEncode(file['content']),
    );
    await verify(
      base64Encode(bytes) == base64Encode([7, 8, 9]),
      'Browser attachment decryption failed',
    );
    await first.close(logout: true);
    first.dispose();
    await second.close(logout: true);
    second.dispose();
    result.textContent = 'RIVER_MATRIX_WEB_CRYPTO_PASS';
  } catch (e) {
    result.textContent = 'RIVER_MATRIX_WEB_CRYPTO_FAIL ($phase): $e';
  } finally {
    client.close();
  }
}
