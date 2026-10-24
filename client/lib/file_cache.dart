import 'dart:async';
import 'dart:convert';
import 'dart:math';
import 'dart:typed_data';
import 'package:crypto/crypto.dart';
import 'file_models.dart';
import 'cache_io.dart'
    if (dart.library.js_interop) 'cache_web.dart'
    as platform;

const maxFileBytes = 25 * 1024 * 1024,
    maxMessageBytes = 50 * 1024 * 1024,
    cacheBudget = 256 * 1024 * 1024,
    chunkBytes = 16 * 1024;
final uuidPattern = RegExp(
  r'^[a-fA-F0-9]{8}-[a-fA-F0-9]{4}-[a-fA-F0-9]{4}-[a-fA-F0-9]{4}-[a-fA-F0-9]{12}$',
);
String safeFileName(String name) {
  final value = name.replaceAll(RegExp(r'[\x00-\x1f\x7f/\\]'), '_').trim();
  return value.isEmpty ? 'file' : value.substring(0, min(value.length, 255));
}

bool validAttachment(Json file) =>
    uuidPattern.hasMatch(file.text('id')) &&
    file.text('name').isNotEmpty &&
    file.text('name').length <= 255 &&
    !RegExp(r'[\x00-\x1f\x7f/\\]').hasMatch(file.text('name')) &&
    file.number('size') > 0 &&
    file.number('size') <= maxFileBytes &&
    file.text('mime').length <= 120 &&
    RegExp(
      r'^[a-z0-9!#$&^_.+-]+/[a-z0-9!#$&^_.+-]+$',
    ).hasMatch(file.text('mime')) &&
    RegExp(r'^[a-f0-9]{64}$').hasMatch(file.text('sha256')) &&
    file.text('scope') == 'room' &&
    uuidPattern.hasMatch(file.text('targetId'));
Uint8List filePacket(String transfer, int offset, Uint8List bytes) {
  if (!uuidPattern.hasMatch(transfer) ||
      bytes.isEmpty ||
      bytes.length > chunkBytes ||
      offset < 0) {
    throw ArgumentError('Invalid file frame');
  }
  final packet = Uint8List(44 + bytes.length)
    ..setRange(0, 40, ascii.encode('RIVR$transfer'));
  ByteData.sublistView(packet).setUint32(40, offset, Endian.big);
  packet.setRange(44, packet.length, bytes);
  return packet;
}

class FileCache {
  FileCache(this.store, {this.budget = cacheBudget});
  final platform.ByteStore store;
  final int budget;
  final Map<String, Json> _index = {};
  Future<void> _queue = Future.value();
  static Future<FileCache> create(String origin, String account) async {
    final store = await platform.createStore(
      sha256.convert(utf8.encode('$origin:$account')).toString(),
    );
    final cache = FileCache(store);
    await cache.initialize();
    return cache;
  }

  String key(Json file) => sha256
      .convert(utf8.encode('${file.text('targetId')}:${file.text('id')}'))
      .toString();
  Future<void> initialize() async {
    await store.initialize();
    try {
      final index = await store.get('index.json');
      if (index != null) {
        for (final record in records(jsonDecode(utf8.decode(index)))) {
          if (validAttachment(record)) _index[key(record)] = record;
        }
      }
    } on FormatException {
      /* Unindexed bytes cannot be served as trusted files. */
    }
  }

  Future<Uint8List?> get(Json file) async {
    if (!validAttachment(file)) return null;
    final bytes = await store.get(key(file));
    return bytes != null &&
            bytes.length == file.number('size') &&
            sha256.convert(bytes).toString() == file.text('sha256')
        ? bytes
        : null;
  }

  Future<List<Json>> save(Json file, Uint8List bytes) {
    final result = Completer<List<Json>>();
    _queue = _queue.catchError((Object _) {}).then((_) async {
      try {
        if (!validAttachment(file) ||
            bytes.length > budget ||
            bytes.length != file.number('size') ||
            sha256.convert(bytes).toString() != file.text('sha256')) {
          throw StateError('File integrity check failed.');
        }
        final evicted = <Json>[];
        var used =
            _index.values.fold(0, (n, f) => n + f.number('size')) -
            (_index[key(file)]?.number('size') ?? 0);
        final oldest = _index.values.where((f) => key(f) != key(file)).toList()
          ..sort(
            (a, b) => a.number('cachedAt').compareTo(b.number('cachedAt')),
          );
        for (final old in oldest) {
          if (used + bytes.length <= budget) break;
          await store.remove(key(old));
          used -= old.number('size');
          _index.remove(key(old));
          evicted.add(old);
        }
        await store.put(key(file), bytes);
        _index[key(file)] = {
          ...file,
          'cachedAt': DateTime.now().millisecondsSinceEpoch,
        };
        await store.put(
          'index.json',
          Uint8List.fromList(utf8.encode(jsonEncode(_index.values.toList()))),
        );
        result.complete(evicted);
      } catch (e, st) {
        result.completeError(e, st);
      }
    });
    return result.future;
  }
}
