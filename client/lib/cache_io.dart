import 'dart:io';
import 'dart:typed_data';
import 'package:path_provider/path_provider.dart';

class ByteStore {
  ByteStore(this.root);
  final Directory root;
  Future<void> initialize() => root.create(recursive: true);
  Future<Uint8List?> get(String key) async {
    final f = File('${root.path}/$key');
    return await f.exists() ? f.readAsBytes() : null;
  }

  Future<void> put(String key, Uint8List value) async {
    final next = File('${root.path}/$key.next');
    await next.writeAsBytes(value, flush: true);
    await next.rename('${root.path}/$key');
  }

  Future<void> remove(String key) async {
    final f = File('${root.path}/$key');
    if (await f.exists()) await f.delete();
  }
}

Future<ByteStore> createStore(String account) async {
  final parent = await getApplicationSupportDirectory();
  return ByteStore(Directory('${parent.path}/river/files/$account'));
}
