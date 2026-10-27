import 'dart:async';
import 'dart:convert';
import 'dart:ui' as ui;
import 'dart:typed_data';
import 'package:crypto/crypto.dart';
import 'package:http/http.dart' as http;
import 'package:markdown/markdown.dart' as md;
import 'package:flutter/foundation.dart' show kIsWeb;
import 'cache_io.dart'
    if (dart.library.js_interop) 'cache_web.dart'
    as platform;

const stickerTitle = 'river-sticker';
const stickerReactionPrefix = 'sticker:';
const maxMediaBytes = 25 * 1024 * 1024;

String mediaFetchUrl(String url) => kIsWeb
    ? Uri.base
          .resolve('/api/public/media')
          .replace(queryParameters: {'url': url})
          .toString()
    : url;

Uri? mediaUri(String value) {
  if (utf8.encode(value).length > 2048 ||
      value.contains('\\') ||
      RegExp(r'[\s\x00-\x1f\x7f]').hasMatch(value)) {
    return null;
  }
  final uri = Uri.tryParse(value);
  return uri != null &&
          ['https', 'http'].contains(uri.scheme) &&
          uri.host.isNotEmpty &&
          uri.userInfo.isEmpty
      ? uri
      : null;
}

bool isImageLink(String value) {
  final uri = mediaUri(value);
  return uri != null &&
      RegExp(
        r'\.(gif|png|jpe?g|webp|avif|bmp)$',
        caseSensitive: false,
      ).hasMatch(uri.path);
}

String? stickerReactionUrl(String key) =>
    key.startsWith(stickerReactionPrefix) &&
        mediaUri(key.substring(stickerReactionPrefix.length)) != null
    ? key.substring(stickerReactionPrefix.length)
    : null;

String mediaMarkdown(String url, {bool sticker = false}) {
  if (mediaUri(url) == null) {
    throw ArgumentError('Use an HTTP or HTTPS image URL.');
  }
  // Angle destinations preserve query strings and parentheses in Markdown.
  final escaped = url.replaceAll('<', '%3C').replaceAll('>', '%3E');
  return '![${sticker ? 'Sticker' : 'Image'}](<$escaped>${sticker ? ' "$stickerTitle"' : ''})';
}

/// Image URLs remain portable Markdown on the wire. Never interpret code spans,
/// local paths or arbitrary HTML as media.
class MediaLinkSyntax extends md.InlineSyntax {
  MediaLinkSyntax() : super(r'https?://[^\s<>]+');
  @override
  bool onMatch(md.InlineParser parser, Match match) {
    final raw = match[0]!;
    final url = raw.replaceFirst(RegExp(r'[.,!?;:)]+$'), '');
    if (!isImageLink(url)) return false;
    parser.addNode(
      md.Element.empty('img')
        ..attributes['src'] = url
        ..attributes['alt'] = 'Image',
    );
    if (url.length < raw.length) {
      parser.addNode(md.Text(raw.substring(url.length)));
    }
    return true;
  }
}

class SavedSticker {
  const SavedSticker(this.url, this.bytes);
  final String url;
  final Uint8List bytes;
  String get id => sha256.convert(utf8.encode(url)).toString();
}

/// Saved sticker bytes are deliberately outside the room attachment cache.
/// They remain available offline and never acquire an image conversion action.
class StickerLibrary {
  StickerLibrary(this.openStore);
  final Future<platform.ByteStore> Function() openStore;
  static final device = StickerLibrary(
    () => platform.createStore('stickers-v1'),
  );
  platform.ByteStore? _store;
  final List<SavedSticker> _items = [];
  Future<void>? _loading;
  Future<void> _queue = Future.value();
  List<SavedSticker> get items => List.unmodifiable(_items);

  Future<void> load() => _loading ??= _load().catchError((Object error) {
    _loading = null;
    throw error;
  });

  Future<void> _load() async {
    final store = await openStore();
    await store.initialize();
    final index = await store.get('index.json');
    final loaded = <SavedSticker>[];
    if (index != null) {
      for (final url
          in (jsonDecode(utf8.decode(index)) as List).whereType<String>()) {
        if (mediaUri(url) == null) continue;
        final id = sha256.convert(utf8.encode(url)).toString();
        final bytes = await store.get(id);
        if (bytes != null && bytes.length <= maxMediaBytes) {
          loaded.add(SavedSticker(url, bytes));
        }
      }
    }
    _store = store;
    _items
      ..clear()
      ..addAll(loaded);
  }

  Future<void> save(String url, Uint8List bytes) {
    final next = _queue.catchError((Object _) {}).then((_) async {
      await load();
      if (mediaUri(url) == null ||
          bytes.isEmpty ||
          bytes.length > maxMediaBytes) {
        throw StateError('Choose an image smaller than 25 MiB.');
      }
      if (_items.any((s) => s.url == url)) return;
      if (_items.length >= 100 ||
          _items.fold(0, (int n, s) => n + s.bytes.length) + bytes.length >
              128 * 1024 * 1024) {
        throw StateError(
          'Your sticker library is full. Remove a sticker first.',
        );
      }
      final sticker = SavedSticker(url, bytes);
      await _store!.put(sticker.id, bytes);
      await _writeIndex([..._items, sticker]);
      _items.add(sticker);
    });
    _queue = next;
    return next;
  }

  Future<void> remove(SavedSticker sticker) {
    final next = _queue.catchError((Object _) {}).then((_) async {
      await load();
      final kept = _items.where((s) => s.url != sticker.url).toList();
      await _writeIndex(kept);
      _items
        ..clear()
        ..addAll(kept);
      await _store!.remove(sticker.id);
    });
    _queue = next;
    return next;
  }

  Future<void> _writeIndex(List<SavedSticker> items) => _store!.put(
    'index.json',
    Uint8List.fromList(
      utf8.encode(jsonEncode(items.map((s) => s.url).toList())),
    ),
  );
}

/// Public linked images use the same platform byte store as peer attachments.
/// They have a separate index/budget so loading images cannot evict files that
/// this device is advertising to peers. URL identities and bytes are verified.
class LinkedImageCache {
  LinkedImageCache(this.store, {this.budget = 128 * 1024 * 1024});
  final platform.ByteStore store;
  static Future<LinkedImageCache>? _public;
  static Future<Uint8List> loadPublic(String url) async {
    LinkedImageCache cache;
    try {
      cache = await (_public ??= platform
          .createStore('public-linked-images-v1')
          .then((store) => LinkedImageCache(store)));
    } catch (_) {
      _public = null;
      return downloadMedia(url);
    }
    return cache.load(url);
  }

  final int budget;
  final _index = <String, Map<String, dynamic>>{};
  final _pending = <String, Future<Uint8List>>{};
  Future<void>? _ready;
  Future<void> _queue = Future.value();

  Future<void> _initialize() => _ready ??= (() async {
    await store.initialize();
    final bytes = await store.get('linked-images.json');
    if (bytes == null) return;
    final data = jsonDecode(utf8.decode(bytes)) as Map;
    for (final entry in data.entries) {
      final record = (entry.value as Map).cast<String, dynamic>();
      if (RegExp(r'^image-[a-f0-9]{64}$').hasMatch(entry.key as String) &&
          record['size'] is int &&
          record['size'] > 0 &&
          record['size'] <= maxMediaBytes &&
          record['sha256'] is String &&
          record['saved_at'] is int) {
        _index[entry.key as String] = record;
      }
    }
  })();

  Future<Uint8List> load(String url, {http.Client? client}) {
    if (mediaUri(url) == null) {
      return Future.error(StateError('Unsupported image link'));
    }
    return _pending.putIfAbsent(url, () async {
      try {
        final key = 'image-${sha256.convert(utf8.encode(url))}';
        var usable = true;
        try {
          await _initialize();
          final record = _index[key], bytes = await store.get(key);
          if (record != null &&
              bytes != null &&
              bytes.length == record['size'] &&
              sha256.convert(bytes).toString() == record['sha256']) {
            return bytes;
          }
        } catch (_) {
          usable = false;
        }
        final bytes = await downloadMedia(url, client: client);
        final codec = await ui.instantiateImageCodec(bytes);
        codec.dispose();
        if (usable && bytes.length <= budget) {
          final next = _queue.catchError((Object _) {}).then((_) async {
            var used = _index.entries
                .where((e) => e.key != key)
                .fold(0, (int n, e) => n + (e.value['size'] as int));
            final oldest = _index.keys.where((k) => k != key).toList()
              ..sort(
                (a, b) => (_index[a]!['saved_at'] as int).compareTo(
                  _index[b]!['saved_at'] as int,
                ),
              );
            for (final old in oldest) {
              if (used + bytes.length <= budget) break;
              await store.remove(old);
              used -= _index.remove(old)!['size'] as int;
            }
            await store.put(key, bytes);
            _index[key] = {
              'size': bytes.length,
              'sha256': sha256.convert(bytes).toString(),
              'saved_at': DateTime.now().millisecondsSinceEpoch,
            };
            await store.put(
              'linked-images.json',
              Uint8List.fromList(utf8.encode(jsonEncode(_index))),
            );
          });
          _queue = next;
          // An unavailable disk must not hide an image fetched successfully.
          try {
            await next;
          } catch (_) {}
        }
        return bytes;
      } finally {
        _pending.remove(url);
      }
    });
  }
}

Future<Uint8List> downloadMedia(String url, {http.Client? client}) async {
  final uri = mediaUri(url);
  if (uri == null) throw StateError('Use an HTTP or HTTPS image URL.');
  final transport = client ?? http.Client();
  try {
    final response = await transport
        .send(http.Request('GET', Uri.parse(mediaFetchUrl(uri.toString()))))
        .timeout(const Duration(seconds: 20));
    if (response.statusCode != 200 ||
        (response.contentLength ?? 0) > maxMediaBytes) {
      throw StateError(
        'Unable to load this image, or it is larger than 25 MiB.',
      );
    }
    final builder = BytesBuilder(copy: false);
    await for (final chunk in response.stream.timeout(
      const Duration(seconds: 20),
    )) {
      if (builder.length + chunk.length > maxMediaBytes) {
        throw StateError('Choose an image smaller than 25 MiB.');
      }
      builder.add(chunk);
    }
    return builder.takeBytes();
  } finally {
    if (client == null) transport.close();
  }
}
