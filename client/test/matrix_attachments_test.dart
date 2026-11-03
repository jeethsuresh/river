import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_quill/flutter_quill.dart'
    show FlutterQuillLocalizations;
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:river/api.dart';
import 'package:river/call_chat.dart';
import 'package:river/content_widgets.dart';
import 'package:river/matrix_attachment_widgets.dart';
import 'package:river/matrix_messaging.dart';

import 'matrix_api_test.dart' show RoomTransport, connected;
import 'ui_refresh_test.dart' show ReviewRoom;

class AttachmentTransport extends RoomTransport {
  bool encrypted = true;
  final uploads = <({String room, String name, int size})>[];
  @override
  Future<MatrixJson> sync() async {
    final result = await super.sync();
    (result['rooms'] as List).single['encrypted'] = encrypted;
    return result;
  }

  @override
  Future<MatrixJson> sendAttachment(
    String room,
    String name,
    String mime,
    Uint8List bytes,
    String txn,
  ) async {
    uploads.add((room: room, name: name, size: bytes.length));
    return super.sendAttachment(room, name, mime, bytes, txn);
  }
}

Widget screen(Widget child) => MaterialApp(
  localizationsDelegates: FlutterQuillLocalizations.localizationsDelegates,
  home: child,
);

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const picker = MethodChannel('miguelruivo.flutter.plugins.filepicker');
  late Uint8List bytes;
  late int size;
  final errors = <Object>[];

  setUp(() {
    bytes = Uint8List.fromList([1, 2, 3]);
    size = bytes.length;
    errors.clear();
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(picker, (call) async {
          expect(call.method, 'any');
          expect(call.arguments['allowMultipleSelection'], false);
          expect(call.arguments['withData'], true);
          return [
            {'name': 'proof.bin', 'size': size, 'bytes': bytes},
          ];
        });
  });
  tearDown(() {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(picker, null);
  });

  Future<void> open(WidgetTester tester, RiverApi api) async {
    await tester.pumpWidget(
      screen(
        Builder(
          builder: (context) => Scaffold(
            body: FilledButton(
              onPressed: () async {
                try {
                  await sendMatrixAttachment(context, api, 'local');
                } catch (e) {
                  errors.add(e);
                }
              },
              child: const Text('Attach'),
            ),
          ),
        ),
      ),
    );
    await tester.tap(find.text('Attach'));
    await tester.pumpAndSettle();
  }

  testWidgets(
    'the picker confirms a 32 MiB file and sends only through Matrix',
    (tester) async {
      final engine = AttachmentTransport(), requests = <http.Request>[];
      final api = await connected(engine, requests);
      addTearDown(api.dispose);
      bytes = Uint8List(32 * 1024 * 1024);
      size = bytes.length;
      await open(tester, api);
      expect(find.textContaining('Encrypted for this room'), findsOneWidget);
      expect(engine.uploads, isEmpty);
      await tester.tap(find.text('Send'));
      await tester.pumpAndSettle();
      expect(errors, isEmpty);
      expect(engine.uploads.single, (
        room: '!room:remote',
        name: 'proof.bin',
        size: 32 * 1024 * 1024,
      ));
      expect(requests.where((r) => r.method != 'GET'), isEmpty);
    },
  );

  testWidgets('empty and oversized files fail before confirmation or upload', (
    tester,
  ) async {
    final engine = AttachmentTransport(), api = await connected(engine, []);
    addTearDown(api.dispose);
    for (final invalid in [0, 32 * 1024 * 1024 + 1]) {
      size = invalid;
      await open(tester, api);
      expect(find.text('Send attachment'), findsNothing);
      expect(errors.last, isA<StateError>());
      expect(errors.last.toString(), contains('32 MiB'));
    }
    expect(engine.uploads, isEmpty);
  });

  test('API size checks prevent bypassing the picker', () async {
    final engine = AttachmentTransport(), api = await connected(engine, []);
    addTearDown(api.dispose);
    for (final invalid in [Uint8List(0), Uint8List(32 * 1024 * 1024 + 1)]) {
      await expectLater(
        api.sendMatrixFile(
          'local',
          'proof.bin',
          'application/octet-stream',
          invalid,
        ),
        throwsStateError,
      );
    }
    expect(engine.uploads, isEmpty);
  });

  test(
    'legacy manifests are rejected in both encrypted and unencrypted rooms',
    () async {
      for (final encrypted in [true, false]) {
        final engine = AttachmentTransport()..encrypted = encrypted;
        final requests = <http.Request>[];
        final api = await connected(engine, requests);
        await expectLater(
          api.send('local', 'm.room.message', {
            'msgtype': 'm.text',
            'body': 'Old file',
            'cool.gravitas.river.attachments': [
              {'name': 'proof.bin'},
            ],
          }, 'legacy'),
          throwsStateError,
        );
        expect(engine.sends, 0);
        expect(requests.where((r) => r.method != 'GET'), isEmpty);
        await api.matrix.disconnect();
        await expectLater(
          api.sendMatrixFile(
            'local',
            'proof.bin',
            'application/octet-stream',
            bytes,
          ),
          throwsStateError,
        );
        expect(engine.uploads, isEmpty);
        expect(requests.where((r) => r.url.path.contains('/files')), isEmpty);
        api.dispose();
      }
    },
  );

  testWidgets(
    'old attachment messages retain names without download or retry controls',
    (tester) async {
      final api = await connected(AttachmentTransport(), []);
      addTearDown(api.dispose);
      await tester.pumpWidget(
        screen(
          Scaffold(
            body: ContentCard(
              app: api,
              room: 'local',
              reply: () {},
              event: {
                'event_id': r'$old',
                'sender': '@alice:example.org',
                'type': 'm.room.message',
                'origin_server_ts': 0,
                'content': {
                  'body': 'Old file',
                  'cool.gravitas.river.attachments': [
                    {'name': 'proof.bin'},
                  ],
                },
              },
            ),
          ),
        ),
      );
      expect(find.text('proof.bin'), findsOneWidget);
      expect(
        find.textContaining('old peer attachment is unavailable'),
        findsOneWidget,
      );
      expect(find.byTooltip('Retry file transfer'), findsNothing);
      expect(find.byTooltip('Download attachment'), findsNothing);
    },
  );

  testWidgets(
    'call chat uses Matrix and cancels a pending confirmation when the call ends',
    (tester) async {
      final engine = AttachmentTransport(), api = await connected(engine, []);
      api.calls
        ..room = ReviewRoom()
        ..chat = 'local'
        ..target = {'id': 'parent', 'name': 'Call'};
      addTearDown(api.dispose);
      await tester.pumpWidget(screen(CallChatScreen(api: api, room: 'local')));
      await tester.pumpAndSettle();
      await tester.tap(find.byTooltip('Attach files'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Send'));
      await tester.pumpAndSettle();
      expect(engine.uploads, hasLength(1));
      await tester.tap(find.byTooltip('Attach files'));
      await tester.pumpAndSettle();
      api.calls
        ..room = null
        ..chat = null
        ..changed();
      await tester.pumpAndSettle();
      await tester.tap(find.text('Send'));
      await tester.pumpAndSettle();
      expect(engine.uploads, hasLength(1));
      expect(
        find.text('Join the call to read and send messages here.'),
        findsOneWidget,
      );
      await tester.pumpWidget(const SizedBox());
    },
  );
}
