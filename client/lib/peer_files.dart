import 'dart:async';
import 'dart:convert';
import 'dart:math';
import 'package:crypto/crypto.dart';
import 'package:file_picker/file_picker.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_webrtc/flutter_webrtc.dart';
import 'package:mime/mime.dart';
import 'package:uuid/uuid.dart';
import 'api.dart';
import 'file_cache.dart';
import 'file_models.dart';
import 'peer_mesh.dart';

class TransferStatus {
  const TransferStatus(this.phase, [this.progress = 0, this.detail]);
  final String phase;
  final double progress;
  final String? detail;
}

class PeerFiles extends ChangeNotifier {
  PeerFiles(this.api, this.origin, this.cache, {this.meshAdapter});
  static Future<PeerFiles> create(
    RiverApi api,
    Uri origin,
    String account,
  ) async {
    final cache = await FileCache.create(api.uri('/').origin, account);
    return PeerFiles(api, origin, cache);
  }

  final RiverApi api;
  final Uri origin;
  final FileCache cache;
  final PeerMesh Function(PeerMesh)? meshAdapter;
  final Map<String, _FileScopeClient> _scopes = {};
  final Map<String, TransferStatus> states = {};
  final Set<String> _preparing = {};
  bool active = true, closed = false;
  int slots = 0;
  TransferStatus status(Json file) =>
      states[file.text('id')] ?? const TransferStatus('locating');
  void state(String id, String phase, [double progress = 0, String? detail]) {
    if (!closed) {
      states[id] = TransferStatus(phase, progress, detail);
      notifyListeners();
    }
  }

  Future<void> setScopes(List<FileScope> scopes, {required bool active}) async {
    final wanted = scopes.map((scope) => scope.key).toSet();
    for (final key in _scopes.keys.toList()) {
      if (!wanted.contains(key)) await _scopes.remove(key)!.close();
    }
    for (final scope in scopes) {
      _scopes.putIfAbsent(scope.key, () => _FileScopeClient(this, scope));
    }
    this.active = active;
    for (final scope in _scopes.values) {
      scope.setActive(active);
    }
  }

  void setActive(bool value) {
    active = value;
    for (final scope in _scopes.values) {
      scope.setActive(value);
    }
  }

  Future<List<Json>> pick(
    FileScope scope, {
    List<Json> existing = const [],
  }) async {
    final selection = await FilePicker.pickFiles(
      allowMultiple: true,
      withData: true,
    );
    if (selection == null) return [];
    if (selection.files.length + existing.length > 5) {
      throw StateError('Choose up to five files per message.');
    }
    if (selection.files.fold(0, (sum, file) => sum + file.size) +
            existing.fold(0, (sum, file) => sum + file.number('size')) >
        maxMessageBytes) {
      throw StateError('Keep attachments under 50 MB per message.');
    }
    final results = <Json>[];
    for (final picked in selection.files) {
      if (picked.size < 1 ||
          picked.size > maxFileBytes ||
          picked.bytes == null) {
        throw StateError('Choose a non-empty file up to 25 MB.');
      }
      final source = picked.bytes!;
      final file = <String, dynamic>{
        'id': const Uuid().v4(),
        'name': safeFileName(picked.name),
        'size': source.length,
        'mime':
            lookupMimeType(picked.name)?.toLowerCase() ??
            'application/octet-stream',
        'sha256': sha256.convert(source).toString(),
        'scope': scope.kind,
        'targetId': scope.id,
      };
      for (final old in await cache.save(file, source)) {
        state(
          old.text('id'),
          'removed',
          0,
          'Local copy removed to make space.',
        );
      }
      results.add(file);
      state(file.text('id'), 'ready', 1);
    }
    return results;
  }

  Future<void> expect(Json file) async {
    if (closed || !validAttachment(file) || !_preparing.add(file.text('id'))) {
      return;
    }
    try {
      await _scopes[FileScope(file.text('scope'), file.text('targetId')).key]
          ?.expect(file);
    } finally {
      _preparing.remove(file.text('id'));
    }
  }

  Future<void> publish(Json file) async {
    final client =
        _scopes[FileScope(file.text('scope'), file.text('targetId')).key];
    if (client == null) return;
    client.known[file.text('id')] = file;
    state(file.text('id'), 'ready', 1);
    client.mesh?.send({'type': 'attachment', 'attachmentId': file.text('id')});
    for (final peer in client.mesh?.filePeers ?? <String>[]) {
      await client.mesh!.control(peer, {
        'type': 'offer',
        'id': file.text('id'),
      });
    }
  }

  Future<void> retry(Json file) async {
    final client =
        _scopes[FileScope(file.text('scope'), file.text('targetId')).key];
    client?.failed.remove(file.text('id'));
    states.remove(file.text('id'));
    await client?.expect(file);
  }

  Future<void> close() async {
    closed = true;
    for (final scope in _scopes.values) {
      await scope.close();
    }
    _scopes.clear();
  }
}

class _Incoming {
  _Incoming(this.file, this.peer, this.transfer)
    : bytes = Uint8List(file.number('size'));
  final Json file;
  final String peer, transfer;
  final Uint8List bytes;
  int offset = 0;
  bool started = false, verifying = false;
  Timer? timer;
}

class _FileScopeClient {
  _FileScopeClient(this.owner, this.scope);
  final PeerFiles owner;
  final FileScope scope;
  PeerMesh? mesh;
  bool active = false,
      stopped = false,
      connecting = false,
      denied = false,
      peerFailed = false;
  int failures = 0;
  Timer? reconnect;
  final Map<String, Json> known = {};
  final Map<String, Set<String>> offers = {}, failed = {};
  final Map<String, _Incoming> incoming = {};
  final Map<String, Timer> discovery = {}, retries = {};
  final Map<String, (String, bool)> outgoing = {};
  final Map<String, (DateTime, int)> rates = {};
  final Map<String, Future<void>> queues = {};
  bool get missing => known.keys.any(
    (id) => !['ready', 'removed'].contains(owner.states[id]?.phase),
  );
  void setActive(bool value) {
    if (value == active) return;
    active = value;
    if (value) {
      unawaited(connect());
    } else {
      reconnect?.cancel();
      reconnect = null;
      final previous = mesh;
      mesh = null;
      unawaited(previous?.close());
      for (final id in incoming.keys.toList()) {
        fail(id, 'Download paused while River is inactive.');
      }
    }
  }

  Future<void> connect() async {
    if (!active || stopped || denied || connecting || mesh != null) return;
    connecting = true;
    try {
      final credentials = await owner.api.request('/api/rtc');
      if (!active || stopped) return;
      final configured = PeerMesh(
        origin: owner.origin,
        room: scope.id,
        scope: scope.kind,
        token: owner.api.token ?? '',
        iceServers: (credentials['iceServers'] as List?) ?? [],
        iceTransportPolicy:
            credentials['iceTransportPolicy'] as String? ?? 'all',
        iceConfiguration: () => owner.api.request('/api/rtc'),
        error: (message) {
          peerFailed = true;
          if (missing || message.startsWith('River signaling')) {
            scheduleReconnect();
          }
        },
        onPeer: (peer, online) {
          if (online) {
            for (final id in known.keys) {
              failed[id]?.remove(peer);
              if (owner.states[id]?.phase != 'ready') discover(id);
            }
          } else {
            for (final item in incoming.values.toList()) {
              if (item.peer == peer) {
                fail(item.file.text('id'), 'The sending member disconnected.');
              }
            }
          }
        },
        onAttachment: (id) => unawaited(announcement(id)),
        onData: (peer, data) {
          queues[peer] = (queues[peer] ?? Future.value())
              .then((_) => receive(peer, data))
              .catchError((Object _) {
                /* Malformed data cannot crash another transfer or the UI. */
              });
        },
      );
      final next = owner.meshAdapter?.call(configured) ?? configured;
      mesh = next;
      await next.connect();
      if (!active || stopped) {
        await next.close();
        if (mesh == next) mesh = null;
        return;
      }
      final feed = await owner.api.request('/api/groups/${scope.id}/files');
      for (final file in feed.rows('attachments')) {
        await expect(file);
      }
    } on ApiException catch (e) {
      if ([401, 403, 404].contains(e.status)) {
        denied = true;
        await mesh?.close();
        mesh = null;
      } else {
        scheduleReconnect();
      }
    } on Object {
      scheduleReconnect();
    } finally {
      connecting = false;
    }
  }

  void scheduleReconnect() {
    if (!active || stopped || denied || reconnect != null) return;
    reconnect = Timer(
      Duration(seconds: min(300, pow(2, min(failures++, 9)).toInt())),
      () async {
        reconnect = null;
        final previous = mesh;
        mesh = null;
        await previous?.close();
        if (active && !stopped) unawaited(connect());
      },
    );
  }

  Future<Json?> lookup(String id) async {
    if (!uuidPattern.hasMatch(id) || stopped) return null;
    final file = object(
      (await owner.api.request(
        '/api/groups/${scope.id}/files?file_id=$id',
      ))['attachment'],
    );
    return validAttachment(file) &&
            file.text('scope') == scope.kind &&
            file.text('targetId') == scope.id
        ? file
        : null;
  }

  Future<void> announcement(String id) async {
    try {
      final file = await lookup(id);
      if (file != null) await expect(file);
    } on ApiException {
      /* Wait for membership/catch-up, never poll endlessly. */
    }
  }

  Future<void> expect(Json file) async {
    if (stopped ||
        !validAttachment(file) ||
        file.text('scope') != scope.kind ||
        file.text('targetId') != scope.id) {
      return;
    }
    final id = file.text('id'), previous = known[file.text('id')];
    if (previous != null &&
        (previous.text('sha256') != file.text('sha256') ||
            previous.number('size') != file.number('size'))) {
      return;
    }
    known[id] = file;
    if (await owner.cache.get(file) != null) {
      owner.state(id, 'ready', 1);
      return;
    }
    if (incoming.containsKey(id) ||
        discovery.containsKey(id) ||
        retries.containsKey(id) ||
        owner.states[id]?.phase == 'removed') {
      return;
    }
    if (peerFailed) {
      peerFailed = false;
      scheduleReconnect();
    }
    discover(id);
  }

  void discover(String id) {
    if (!active ||
        stopped ||
        incoming.containsKey(id) ||
        owner.states[id]?.phase == 'ready') {
      return;
    }
    discovery.remove(id)?.cancel();
    owner.state(id, 'locating', 0, 'Looking for an online copy');
    for (final peer in mesh?.filePeers ?? <String>[]) {
      unawaited(mesh!.control(peer, {'type': 'want', 'id': id}));
    }
    discovery[id] = Timer(const Duration(seconds: 15), () {
      discovery.remove(id);
      if (incoming.containsKey(id) || owner.states[id]?.phase == 'ready') {
        return;
      }
      owner.state(
        id,
        'unavailable',
        0,
        'No online copy yet. River retries automatically.',
      );
      retryLater(id);
    });
    drain();
  }

  void retryLater(String id) {
    if (stopped || !active || retries.containsKey(id)) return;
    retries[id] = Timer(const Duration(minutes: 2), () {
      retries.remove(id);
      if (mesh?.filePeers.isNotEmpty ?? false) {
        failed.remove(id);
        discover(id);
      }
    });
  }

  void drain() {
    if (!active || stopped) return;
    for (final entry in offers.entries) {
      final id = entry.key;
      if (incoming.containsKey(id) || owner.states[id]?.phase == 'ready') {
        continue;
      }
      final file = known[id];
      if (file == null) continue;
      final peer = entry.value
          .where(
            (peer) =>
                (mesh?.filePeers.contains(peer) ?? false) &&
                !(failed[id]?.contains(peer) ?? false) &&
                !incoming.values.any((transfer) => transfer.peer == peer),
          )
          .firstOrNull;
      if (peer == null) continue;
      if (owner.slots >= 2) {
        discovery.remove(id)?.cancel();
        owner.state(id, 'queued');
        continue;
      }
      owner.slots++;
      discovery.remove(id)?.cancel();
      retries.remove(id)?.cancel();
      final item = _Incoming(file, peer, const Uuid().v4());
      incoming[id] = item;
      item.timer = Timer(
        const Duration(seconds: 30),
        () => fail(id, 'The transfer timed out.'),
      );
      owner.state(id, 'receiving');
      unawaited(
        mesh!
            .control(peer, {'type': 'get', 'id': id, 'transfer': item.transfer})
            .then((sent) {
              if (!sent) fail(id, 'The peer disconnected.');
            }),
      );
    }
  }

  void release(_Incoming item) {
    item.timer?.cancel();
    owner.slots = max(0, owner.slots - 1);
    for (final client in owner._scopes.values) {
      scheduleMicrotask(client.drain);
    }
  }

  void fail(String id, String detail) {
    final item = incoming.remove(id);
    if (item == null) return;
    release(item);
    failed.putIfAbsent(id, () => {}).add(item.peer);
    unawaited(
      mesh?.control(item.peer, {
        'type': 'cancel',
        'id': id,
        'transfer': item.transfer,
      }),
    );
    owner.state(id, 'unavailable', 0, detail);
    drain();
    retryLater(id);
  }

  Future<void> receive(String peer, RTCDataChannelMessage raw) async {
    if (stopped) return;
    if (raw.isBinary) {
      receivePacket(peer, raw.binary);
      return;
    }
    if (raw.text.length > 2048) return;
    Json control;
    try {
      control = object(jsonDecode(raw.text));
    } on FormatException {
      return;
    }
    final id = control.text('id');
    if (!uuidPattern.hasMatch(id)) return;
    final type = control.text('type'), transfer = control.text('transfer');
    if (type == 'cancel') {
      if (outgoing[peer]?.$1 == transfer) outgoing[peer] = (transfer, true);
      return;
    }
    if (type == 'want' || type == 'get') {
      final previous = rates[peer], now = DateTime.now();
      final count =
          previous != null && now.difference(previous.$1).inSeconds < 60
          ? previous.$2 + 1
          : 1;
      rates[peer] = (previous != null && count > 1 ? previous.$1 : now, count);
      if (count > 150) return;
      if (type == 'get') {
        if (uuidPattern.hasMatch(transfer)) unawaited(send(peer, id, transfer));
        return;
      }
      final file = await lookup(id);
      if (file != null && await owner.cache.get(file) != null) {
        await mesh?.control(peer, {'type': 'offer', 'id': id});
      }
      return;
    }
    if (type == 'offer') {
      if (!known.containsKey(id)) await announcement(id);
      if (known.containsKey(id)) {
        offers.putIfAbsent(id, () => {}).add(peer);
        drain();
      }
      return;
    }
    final item = incoming[id];
    if (item == null || item.peer != peer || item.transfer != transfer) return;
    if (type == 'begin') {
      if (item.started || control.number('size') != item.bytes.length) {
        fail(id, 'Invalid transfer size.');
        return;
      }
      item.started = true;
    } else if (type == 'missing') {
      fail(id, 'That member no longer has this copy.');
    } else if (type == 'end' && !item.verifying) {
      if (!item.started || item.offset != item.bytes.length) {
        fail(id, 'Incomplete file received.');
        return;
      }
      item.verifying = true;
      item.timer?.cancel();
      owner.state(id, 'verifying', 1);
      try {
        for (final file in await owner.cache.save(item.file, item.bytes)) {
          owner.state(
            file.text('id'),
            'removed',
            0,
            'Local copy removed to make space.',
          );
        }
        if (stopped || incoming[id] != item) return;
        incoming.remove(id);
        release(item);
        offers.remove(id);
        failed.remove(id);
        owner.state(id, 'ready', 1);
        for (final other in mesh?.filePeers ?? <String>[]) {
          await mesh!.control(other, {'type': 'offer', 'id': id});
        }
      } on Object {
        fail(id, 'Could not verify or save the file.');
      }
    }
  }

  void receivePacket(String peer, Uint8List bytes) {
    if (bytes.length <= 44 ||
        bytes.length > 44 + chunkBytes ||
        ascii.decode(bytes.sublist(0, 4), allowInvalid: true) != 'RIVR') {
      return;
    }
    final transfer = ascii.decode(bytes.sublist(4, 40), allowInvalid: true);
    final item = incoming.values
        .where((item) => item.peer == peer && item.transfer == transfer)
        .firstOrNull;
    if (item == null || item.verifying) return;
    final offset = ByteData.sublistView(bytes).getUint32(40, Endian.big),
        count = bytes.length - 44;
    if (!item.started ||
        offset != item.offset ||
        offset + count > item.bytes.length) {
      fail(item.file.text('id'), 'Invalid or out-of-order file data.');
      return;
    }
    item.bytes.setRange(offset, offset + count, bytes, 44);
    item.offset += count;
    item.timer?.cancel();
    item.timer = Timer(
      const Duration(seconds: 30),
      () => fail(item.file.text('id'), 'The transfer stalled.'),
    );
    owner.state(
      item.file.text('id'),
      'receiving',
      item.offset / item.bytes.length,
    );
  }

  Future<void> send(String peer, String id, String transfer) async {
    if (outgoing.containsKey(peer) || stopped) {
      await mesh?.control(peer, {
        'type': 'missing',
        'id': id,
        'transfer': transfer,
      });
      return;
    }
    outgoing[peer] = (transfer, false);
    try {
      final file = await lookup(id),
          copy = file == null ? null : await owner.cache.get(file);
      if (file == null || copy == null || stopped) {
        await mesh?.control(peer, {
          'type': 'missing',
          'id': id,
          'transfer': transfer,
        });
        return;
      }
      await mesh?.control(peer, {
        'type': 'begin',
        'id': id,
        'transfer': transfer,
        'size': file.number('size'),
      });
      var offset = 0;
      while (offset < file.number('size')) {
        if (stopped ||
            outgoing[peer]?.$2 == true ||
            !(mesh?.filePeers.contains(peer) ?? false)) {
          return;
        }
        final bytes = Uint8List.sublistView(
          copy,
          offset,
          min(offset + chunkBytes, copy.length),
        );
        if (bytes.isEmpty) throw StateError('Local copy changed.');
        await mesh!.chunk(peer, filePacket(transfer, offset, bytes));
        offset += bytes.length;
      }
      await mesh?.control(peer, {
        'type': 'end',
        'id': id,
        'transfer': transfer,
      });
    } on Object {
      await mesh?.control(peer, {
        'type': 'missing',
        'id': id,
        'transfer': transfer,
      });
    } finally {
      if (outgoing[peer]?.$1 == transfer) outgoing.remove(peer);
    }
  }

  Future<void> close() async {
    stopped = true;
    active = false;
    reconnect?.cancel();
    for (final timer in [...discovery.values, ...retries.values]) {
      timer.cancel();
    }
    for (final item in incoming.values) {
      item.timer?.cancel();
      owner.slots = max(0, owner.slots - 1);
    }
    incoming.clear();
    await mesh?.close();
    mesh = null;
  }
}
