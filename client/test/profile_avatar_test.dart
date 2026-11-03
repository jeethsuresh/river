import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:river/matrix_messaging.dart';
import 'package:river/profile_avatar.dart';
import 'matrix_api_test.dart' show RoomTransport, connected;
import 'matrix_messaging_test.dart'
    show MemoryMatrixStorage, matrixHarness, matrixProfile;

final png = base64Decode(
  'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR4nGP4////fwAJ+wP9KobjigAAAABJRU5ErkJggg==',
);

class PictureTransport extends RoomTransport {
  final downloads = <MatrixJson>[];
  bool fail = false;
  Uint8List? result;
  Completer<void>? gate;
  String? avatarUrl = 'mxc://remote/avatar';
  @override
  Future<MatrixJson> action(MatrixJson payload) async {
    if (payload['action'] != 'avatar') return super.action(payload);
    downloads.add(payload);
    await gate?.future;
    if (fail) throw StateError('Picture unavailable');
    // Ruma's Base64 serialization intentionally omits padding.
    return {'data': base64Encode(result ?? png).replaceAll('=', '')};
  }

  @override
  Future<MatrixJson> sync() async {
    final snapshot = await super.sync();
    snapshot['rooms'] = <MatrixJson>[
      {
        ...(snapshot['rooms'] as List).single as MatrixJson,
        'avatar_url': avatarUrl,
        'heroes': <MatrixJson>[
          {
            'user_id': '@bob:remote',
            'username': 'Bob',
            'avatar_url': avatarUrl,
          },
        ],
      },
      {
        'room_id': '!external:remote',
        'name': 'External',
        'kind': 'dm',
        'membership': 'join',
        'parents': [],
        'avatar_url': avatarUrl,
      },
    ];
    return snapshot;
  }
}

void main() {
  test('room and contact pictures update and clear with Matrix sync', () async {
    final engine = PictureTransport();
    final app = await connected(engine, []);
    expect(app.group('local')?['avatar_url'], engine.avatarUrl);
    expect(app.personAvatar('@bob:remote'), engine.avatarUrl);
    expect(app.displayName('@bob:remote'), 'Bob');
    expect(app.group('!external:remote')?['matrix_only'], isTrue);
    app.group('local')!['members'] = <MatrixJson>[
      {
        'user_id': '@bob:remote',
        'username': 'Bob',
        'avatar_url': engine.avatarUrl,
      },
    ];
    engine.avatarUrl = 'mxc://remote/new-avatar';
    await app.matrix.syncNow();
    expect(app.group('local')?['avatar_url'], engine.avatarUrl);
    expect(app.personAvatar('@bob:remote'), engine.avatarUrl);
    expect(app.group('!external:remote')?['matrix_only'], isTrue);
    engine.avatarUrl = null;
    await app.matrix.syncNow();
    expect(app.group('local')?['avatar_url'], isNull);
    expect(app.personAvatar('@bob:remote'), isNull);
    app.dispose();
  });
  test(
    'avatar requests are shared, cached, and retry after failures',
    () async {
      final engine = PictureTransport()..gate = Completer<void>();
      final matrix = matrixHarness(MemoryMatrixStorage(), engine);
      await matrix.bind(matrixProfile);
      await matrix.connect();
      final first = matrix.avatar('mxc://remote/avatar');
      final second = matrix.avatar('mxc://remote/avatar');
      expect(engine.downloads, hasLength(1));
      engine.gate!.complete();
      expect(await first, png);
      expect(await second, png);
      expect(await matrix.avatar('mxc://remote/avatar'), png);
      expect(engine.downloads, hasLength(1));
      expect(engine.downloads.single['action'], 'avatar');
      expect(await matrix.avatar('https://remote/avatar'), isNull);
      expect(engine.downloads, hasLength(1));
      engine.fail = true;
      expect(await matrix.avatar('mxc://remote/missing'), isNull);
      engine.fail = false;
      expect(await matrix.avatar('mxc://remote/missing'), png);
      expect(engine.downloads, hasLength(3));
      matrix.dispose();
    },
  );
  test('a delayed picture cannot cross an account or device change', () async {
    final engine = PictureTransport()..gate = Completer<void>();
    final matrix = matrixHarness(MemoryMatrixStorage(), engine);
    await matrix.bind(matrixProfile);
    await matrix.connect();
    final old = matrix.avatar('mxc://remote/avatar');
    await matrix.disconnect();
    engine.gate!.complete();
    expect(await old, isNull);
    await matrix.bind(matrixProfile);
    await matrix.connect();
    expect(await matrix.avatar('mxc://remote/avatar'), png);
    expect(engine.downloads, hasLength(2));
    matrix.dispose();
  });
  test(
    'oversized pictures are rejected and avatar memory stays bounded',
    () async {
      final engine = PictureTransport()
        ..result = Uint8List(2 * 1024 * 1024 + 1);
      final matrix = matrixHarness(MemoryMatrixStorage(), engine);
      await matrix.bind(matrixProfile);
      await matrix.connect();
      expect(await matrix.avatar('mxc://remote/large'), isNull);
      engine.result = Uint8List(2 * 1024 * 1024);
      for (var i = 0; i < 5; i++) {
        await matrix.avatar('mxc://remote/$i');
      }
      await matrix.avatar('mxc://remote/0');
      expect(
        engine.downloads,
        hasLength(7),
        reason: 'Evict the oldest picture after 8 MiB',
      );
      matrix.dispose();
    },
  );
  testWidgets('pictures keep the Matrix badge and clear when removed', (
    tester,
  ) async {
    final engine = PictureTransport();
    final app = await connected(engine, []);
    Widget avatar(String? url) => MaterialApp(
      home: Center(
        child: RiverProfileAvatar(
          app: app,
          name: 'Bob',
          avatarUrl: url,
          matrix: true,
        ),
      ),
    );
    await tester.pumpWidget(avatar('mxc://remote/avatar'));
    await tester.pumpAndSettle();
    expect(find.byType(Image), findsOneWidget);
    expect(find.byTooltip('Matrix'), findsOneWidget);
    await tester.pumpWidget(avatar(null));
    await tester.pumpAndSettle();
    expect(find.byType(Image), findsNothing);
    expect(find.text('B'), findsOneWidget);
    expect(find.byTooltip('Matrix'), findsOneWidget);
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox());
    app.dispose();
  });
  testWidgets('missing and corrupt pictures keep initials and the badge', (
    tester,
  ) async {
    final engine = PictureTransport()..fail = true;
    final app = await connected(engine, []);
    Widget avatar(String url) => MaterialApp(
      home: Center(
        child: RiverProfileAvatar(
          app: app,
          name: 'Bob',
          avatarUrl: url,
          matrix: true,
        ),
      ),
    );
    await tester.pumpWidget(avatar('mxc://remote/missing'));
    await tester.pumpAndSettle();
    expect(find.text('B'), findsOneWidget);
    expect(find.byTooltip('Matrix'), findsOneWidget);
    engine.fail = false;
    engine.result = Uint8List.fromList([1, 2, 3]);
    await tester.pumpWidget(avatar('mxc://remote/corrupt'));
    await tester.pumpAndSettle();
    expect(find.text('B'), findsOneWidget);
    expect(find.byTooltip('Matrix'), findsOneWidget);
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox());
    app.dispose();
  });
}
