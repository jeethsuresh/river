import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';
import 'package:crypto/crypto.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_webrtc/flutter_webrtc.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:river/api.dart';
import 'package:river/cache_io.dart';
import 'package:river/file_cache.dart';
import 'package:river/file_models.dart';
import 'package:river/peer_files.dart';
import 'package:river/peer_mesh.dart';

class WirePeer extends PeerMesh {
  WirePeer(PeerMesh config, this.id, this.network)
    : super(
        origin: config.origin,
        room: config.room,
        token: '',
        scope: config.scope,
        error: config.error,
        onPeer: config.onPeer,
        onData: config.onData,
        onAttachment: config.onAttachment,
      );
  final String id;
  final Map<String, WirePeer> network;
  @override
  Future<void> connect() async {
    network[id] = this;
    for (final peer in network.values.toList()) {
      if (peer.id != id) {
        onPeer?.call(peer.id, true);
        peer.onPeer?.call(id, true);
      }
    }
  }

  @override
  List<String> get filePeers => network.keys.where((p) => p != id).toList();
  @override
  Future<bool> control(String peer, Json value) async {
    network[peer]?.onData?.call(id, RTCDataChannelMessage(jsonEncode(value)));
    return network.containsKey(peer);
  }

  @override
  Future<void> chunk(String peer, Uint8List packet) async {
    network[peer]?.onData?.call(id, RTCDataChannelMessage.fromBinary(packet));
  }

  @override
  void send(Json value) {
    for (final p in network.values.toList()) {
      if (p.id != id) p.onAttachment?.call(value['attachmentId'] as String);
    }
  }

  @override
  Future<void> close() async {
    network.remove(id);
    for (final p in network.values.toList()) {
      p.onPeer?.call(id, false);
    }
  }
}

void main() {
  const room = '00000000-0000-0000-0000-000000000001';
  final bytes = Uint8List.fromList(utf8.encode('hello'));
  Json manifest(String id) => {
    'id': id,
    'name': 'notes.txt',
    'size': 5,
    'mime': 'text/plain',
    'sha256': sha256.convert(bytes).toString(),
    'scope': 'room',
    'targetId': room,
  };
  test(
    'cache verifies digest, persists per account, and evicts within its budget',
    () async {
      final dir = await Directory.systemTemp.createTemp('river-files-');
      addTearDown(() => dir.delete(recursive: true));
      final cache = FileCache(ByteStore(dir), budget: 8);
      await cache.initialize();
      final first = manifest('00000000-0000-0000-0000-000000000002'),
          second = manifest('00000000-0000-0000-0000-000000000003');
      await cache.save(first, bytes);
      expect(await cache.get(first), bytes);
      expect((await cache.save(second, bytes)).single['id'], first['id']);
      expect(await cache.get(first), isNull);
      await expectLater(
        cache.save({...second, 'sha256': List.filled(64, '0').join()}, bytes),
        throwsStateError,
      );
      final reopened = FileCache(ByteStore(dir), budget: 8);
      await reopened.initialize();
      expect(await reopened.get(second), bytes);
      await File(
        '${dir.path}/${cache.key(second)}',
      ).writeAsBytes([1, 2, 3, 4, 5]);
      expect(await reopened.get(second), isNull);
    },
  );
  test(
    'returning members automatically receive and retain a verified peer copy after the original sender leaves',
    () async {
      final dir = await Directory.systemTemp.createTemp('river-peer-');
      addTearDown(() => dir.delete(recursive: true));
      final file = manifest('00000000-0000-0000-0000-000000000004');
      final api = RiverApi(
        client: MockClient(
          (r) async => http.Response(
            jsonEncode(
              r.url.path == '/api/rtc'
                  ? {'iceServers': []}
                  : r.url.queryParameters.containsKey('file_id')
                  ? {'attachment': file}
                  : {
                      'attachments': [file],
                    },
            ),
            200,
          ),
        ),
      );
      addTearDown(api.dispose);
      final network = <String, WirePeer>{};
      Future<PeerFiles> client(String id) async {
        final cache = FileCache(ByteStore(Directory('${dir.path}/$id')));
        await cache.initialize();
        return PeerFiles(
          api,
          Uri.parse('https://river.test'),
          cache,
          meshAdapter: (m) => WirePeer(m, id, network),
        );
      }

      Future<void> ready(PeerFiles files) async {
        final until = DateTime.now().add(const Duration(seconds: 5));
        while (files.status(file).phase != 'ready' &&
            DateTime.now().isBefore(until)) {
          await Future<void>.delayed(const Duration(milliseconds: 10));
        }
        expect(files.status(file).phase, 'ready');
      }

      final sender = await client('sender');
      await sender.cache.save(file, bytes);
      await sender.setScopes([const FileScope('room', room)], active: true);
      final receiver = await client('receiver');
      await receiver.setScopes([const FileScope('room', room)], active: true);
      await ready(receiver);
      expect(await receiver.cache.get(file), bytes);
      await sender.close();
      sender.dispose();
      final returning = await client('returning');
      await returning.setScopes([const FileScope('room', room)], active: true);
      await ready(returning);
      expect(await returning.cache.get(file), bytes);
      await receiver.close();
      receiver.dispose();
      await returning.close();
      returning.dispose();
    },
  );
}
