import 'dart:js_interop';
import 'dart:typed_data';
import 'package:web/web.dart' as web;

class ByteStore {
  ByteStore(this.account);
  final String account;
  late web.Cache _cache;
  Future<void> initialize() async {
    _cache = await web.window.caches.open('river-files-v1-$account').toDart;
  }

  web.Request request(String key) => web.Request(
    Uri.base.resolve('/_river_local/$account/$key').toString().toJS,
  );
  Future<Uint8List?> get(String key) async {
    final r = await _cache.match(request(key)).toDart;
    if (r == null) return null;
    return (await r.arrayBuffer().toDart).toDart.asUint8List();
  }

  Future<void> put(String key, Uint8List value) async {
    await _cache.put(request(key), web.Response(value.toJS)).toDart;
  }

  Future<void> remove(String key) async {
    await _cache.delete(request(key)).toDart;
  }
}

Future<ByteStore> createStore(String account) async => ByteStore(account);
