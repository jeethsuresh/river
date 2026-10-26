import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:markdown/markdown.dart' as md;
import 'package:river/cache_io.dart';
import 'package:river/content_widgets.dart';
import 'package:river/media.dart';
import 'package:river/media_widgets.dart';
import 'package:river/rich_composer.dart';

void main() {
  test('media links reject local and executable sources', () {
    for (final url in [
      'file:///secret',
      'assets/a.png',
      'data:image/png;base64,AA',
      'javascript:alert(1)',
      '//host/a.gif',
      'https://u:p@host/a.png',
      r'https://host\a.gif',
    ]) {
      expect(mediaUri(url), isNull);
    }
    expect(isImageLink('https://host/party.GIF?download=1'), isTrue);
    expect(isImageLink('https://host/a.jpg#image'), isTrue);
    expect(isImageLink('https://host/page'), isFalse);
    expect(stickerReactionUrl('sticker:javascript:alert(1)'), isNull);
  });

  test('sticker identity and complex URLs survive Markdown round trips', () {
    const url = 'https://host/a(b).gif?size=1&token=x';
    final nodes = md.Document().parseLines([mediaMarkdown(url, sticker: true)]);
    final image = ((nodes.single as md.Element).children!.single as md.Element);
    expect(image.attributes['src'], url);
    expect(image.attributes['title'], stickerTitle);
    expect(mediaMarkdown(url), isNot(contains(stickerTitle)));
  });

  test('saved stickers persist bytes separately and can be removed', () async {
    final directory = await Directory.systemTemp.createTemp(
      'river-sticker-test-',
    );
    addTearDown(() => directory.delete(recursive: true));
    final library = StickerLibrary(() async => ByteStore(directory));
    final bytes = Uint8List.fromList([71, 73, 70, 56, 57, 97]);
    await Future.wait([
      library.save('https://host/a.gif', bytes),
      library.save('https://host/a.gif', bytes),
    ]);
    expect(library.items, hasLength(1));
    final reloaded = StickerLibrary(() async => ByteStore(directory));
    await reloaded.load();
    expect(reloaded.items.single.bytes, bytes);
    await reloaded.remove(reloaded.items.single);
    final empty = StickerLibrary(() async => ByteStore(directory));
    await empty.load();
    expect(empty.items, isEmpty);
    await expectLater(empty.save('file:///secret', bytes), throwsStateError);
    expect(empty.items, isEmpty);
  });

  test(
    'media downloads are anonymous and bounded and retain animated bytes',
    () async {
      final gif = base64Decode(
        'R0lGODlhAQABAIAAAAAAAP///yH5BAEAAAAALAAAAAABAAEAAAIBRAA7',
      );
      final client = MockClient((request) async {
        expect(request.headers.keys, isNot(contains('authorization')));
        return http.Response.bytes(gif, 200);
      });
      expect(await downloadMedia('https://host/a.gif', client: client), gif);
      final oversized = MockClient.streaming(
        (_, _) async => http.StreamedResponse(
          const Stream.empty(),
          200,
          contentLength: maxMediaBytes + 1,
        ),
      );
      await expectLater(
        downloadMedia('https://host/a.gif', client: oversized),
        throwsStateError,
      );
      final failure = MockClient((_) async => http.Response('missing', 404));
      await expectLater(
        downloadMedia('https://host/missing.gif', client: failure),
        throwsStateError,
      );
    },
  );

  testWidgets(
    'bare GIFs and Markdown images render, stickers have a distinct contour and actions',
    (tester) async {
      await tester.binding.setSurfaceSize(const Size(1000, 1600));
      addTearDown(() => tester.binding.setSurfaceSize(null));
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: RichBody(
              'https://host/a.gif?x=1\n\n![photo](https://host/b.jpg)\n\n${mediaMarkdown('https://host/c.png', sticker: true)}',
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      final media = tester
          .widgetList<LinkedMedia>(find.byType(LinkedMedia))
          .toList();
      expect(media, hasLength(3));
      expect(media.where((m) => m.sticker), hasLength(1));
      expect(find.byType(StickerImage), findsOneWidget);
      expect(find.text('Make sticker'), findsNWidgets(2));
      expect(find.text('Save sticker'), findsOneWidget);
      expect(find.textContaining('Convert to image'), findsNothing);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'insert image is available in the shared composer and preserves a failed draft',
    (tester) async {
      final controller = TextEditingController(text: 'Existing draft');
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(body: RichComposer(controller: controller)),
        ),
      );
      await tester.tap(find.byTooltip('Insert image or GIF'));
      await tester.pumpAndSettle();
      await tester.enterText(
        find.widgetWithText(TextField, 'Image or GIF URL'),
        'file:///private.png',
      );
      await tester.tap(find.text('Insert'));
      await tester.pumpAndSettle();
      expect(find.text('Use an HTTP or HTTPS image URL.'), findsOneWidget);
      expect(controller.text, 'Existing draft');
      await tester.enterText(
        find.widgetWithText(TextField, 'Image or GIF URL'),
        'https://host/a.gif',
      );
      await tester.tap(find.text('Insert'));
      await tester.pumpAndSettle();
      expect(controller.text, contains('Existing draft'));
      expect(controller.text, contains('![Image](<https://host/a.gif>)'));
      expect(find.text('Markdown'), findsOneWidget);
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox());
      controller.dispose();
    },
  );

  testWidgets(
    'Matrix and sticker reaction state can be removed; guests cannot mutate',
    (tester) async {
      bool? active;
      const key = 'sticker:https://host/a.gif';
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: ReactionBar(
              summary: const [
                {'key': key, 'count': 1, 'active': true},
              ],
              change: (_, value) async => active = value,
            ),
          ),
        ),
      );
      await tester.tap(find.byTooltip('Remove sticker reaction'));
      await tester.pumpAndSettle();
      expect(active, false);
      active = null;
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: ReactionBar(
              enabled: false,
              summary: const [
                {'key': '👍', 'count': 2},
              ],
              change: (_, value) async => active = value,
            ),
          ),
        ),
      );
      expect(
        tester.widget<IconButton>(find.byType(IconButton)).onPressed,
        isNull,
      );
      expect(active, isNull);
      expect(tester.takeException(), isNull);
    },
  );
}
