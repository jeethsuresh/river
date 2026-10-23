import 'dart:async';
import 'dart:convert';
import 'package:web_socket_channel/web_socket_channel.dart';
import 'signal_socket_io.dart'
    if (dart.library.js_interop) 'signal_socket_web.dart';
import 'dart:typed_data';
import 'package:flutter_webrtc/flutter_webrtc.dart';
import 'package:flutter/foundation.dart' show visibleForTesting;
import 'file_models.dart';

/// Wire compatible with lib/webrtc.ts. The Worker carries signaling, not media.
class PeerMesh {
  PeerMesh({
    required this.origin,
    required this.room,
    required this.token,
    this.stream,
    this.iceServers = const [],
    this.scope,
    required this.error,
    this.onStream,
    this.onPeer,
    this.onData,
    this.onAttachment,
    this.peerFactory,
    this.signalWriter,
  });
  final Uri origin;
  final String room, token;
  final String? scope;
  MediaStream? stream;
  final List<dynamic> iceServers;
  final void Function(String) error;
  final void Function(String, MediaStream?)? onStream;
  final void Function(String, bool)? onPeer;
  final void Function(String, RTCDataChannelMessage)? onData;
  final void Function(String)? onAttachment;
  @visibleForTesting
  final Future<RTCPeerConnection> Function(Map<String, dynamic>)? peerFactory;
  @visibleForTesting
  final void Function(Json)? signalWriter;
  final Map<String, RTCPeerConnection> peers = {};
  final Map<String, RTCDataChannel> channels = {};
  final Map<String, List<RTCIceCandidate>> _ice = {};
  final Map<String, Future<void>> _queues = {};
  final Set<String> _makingOffer = {},
      _ignored = {},
      _needsOffer = {},
      _remoteReady = {};
  final Map<String, String> _senderKinds = {};
  WebSocketChannel? _socket;
  String _self = '';
  bool _closed = false;
  Future<void> connect() async {
    final socket = signalSocket(
      origin.replace(
        scheme: origin.scheme == 'http' ? 'ws' : 'wss',
        path: '/api/groups/$room/files/signal',
        query: null,
      ),
      token,
    );
    await socket.ready.timeout(const Duration(seconds: 20));
    if (_closed) {
      await socket.sink.close();
      return;
    }
    _socket = socket;
    socket.stream.listen(
      (raw) {
        if (raw is! String || raw.length > 100000) return;
        try {
          final message = object(jsonDecode(raw));
          final from = message.text('from', '__membership');
          _queues[from] = (_queues[from] ?? Future.value())
              .then((_) => handleSignal(message))
              .catchError((Object _) {
                if (!_closed) {
                  error(
                    'Unable to negotiate the peer connection. Leave and rejoin to retry.',
                  );
                }
              });
        } on FormatException {
          /* Ignore unknown frames. */
        }
      },
      onError: (Object _) {
        if (!_closed) error('River signaling disconnected. Please retry.');
      },
      onDone: () {
        if (!_closed) error('River signaling disconnected. Please retry.');
      },
    );
  }

  void send(Json value) {
    if (!_closed && signalWriter != null) {
      signalWriter!(value);
      return;
    }
    if (!_closed && _socket != null) {
      _socket!.sink.add(jsonEncode(value));
    }
  }

  Future<RTCPeerConnection> _create(String id, {bool initiator = false}) async {
    final existing = peers[id];
    if (existing != null) return existing;
    final configuration = <String, dynamic>{
      'iceServers': iceServers,
      'iceTransportPolicy': 'all',
      'sdpSemantics': 'unified-plan',
    };
    final peer =
        await (peerFactory?.call(configuration) ??
            createPeerConnection(configuration));
    if (_closed) {
      await peer.close();
      throw StateError('Closed');
    }
    peers[id] = peer;
    for (final track in stream?.getTracks() ?? <MediaStreamTrack>[]) {
      final sender = await peer.addTrack(track, stream!);
      _senderKinds[sender.senderId] = track.kind!;
    }
    peer.onIceCandidate = (candidate) {
      if (candidate.candidate?.isNotEmpty ?? false) {
        send({'type': 'ice', 'to': id, 'candidate': candidate.toMap()});
      }
    };
    peer.onTrack = (event) {
      if (event.streams.isNotEmpty) onStream?.call(id, event.streams.first);
    };
    peer.onConnectionState = (state) {
      if (state == RTCPeerConnectionState.RTCPeerConnectionStateFailed) {
        unawaited(remove(id));
        error(
          'A direct peer connection could not be established. Check your connection and River’s TURN configuration.',
        );
      }
    };
    if (scope != null) {
      peer.onDataChannel = (channel) => _bind(id, channel);
      if (initiator) {
        _bind(
          id,
          await peer.createDataChannel(
            'river-files-v1',
            RTCDataChannelInit()..ordered = true,
          ),
        );
      }
    }
    return peer;
  }

  void _bind(String id, RTCDataChannel channel) {
    if (channel.label != 'river-files-v1' ||
        channels.containsKey(id) ||
        _closed) {
      unawaited(channel.close());
      return;
    }
    channels[id] = channel;
    channel.bufferedAmountLowThreshold = 128 * 1024;
    channel.onDataChannelState = (state) {
      if (state == RTCDataChannelState.RTCDataChannelOpen) {
        onPeer?.call(id, true);
      }
      if (state == RTCDataChannelState.RTCDataChannelClosed) {
        channels.remove(id);
        onPeer?.call(id, false);
      }
    };
    channel.onMessage = (data) => onData?.call(id, data);
  }

  @visibleForTesting
  Future<void> handleSignal(Json message) async {
    if (_closed) return;
    final type = message.text('type');
    final from = message.text('from');
    if (type == 'welcome') {
      _self = message.text('peerId');
      for (final id in (message['peers'] as List? ?? []).cast<String>()) {
        final peer = await _create(id, initiator: scope != null);
        await _offer(id, peer);
      }
    } else if (type == 'offer') {
      final peer = await _create(from);
      // flutter_webrtc's cached getter starts null and updates asynchronously.
      // Ask the native connection instead of inventing a first-offer collision.
      final state = await peer.getSignalingState();
      final collision =
          _makingOffer.contains(from) ||
          state != RTCSignalingState.RTCSignalingStateStable;
      if (collision && _self.compareTo(from) > 0) {
        _ignored.add(from);
        _ice.remove(from);
        return;
      }
      _ignored.remove(from);
      if (collision &&
          state == RTCSignalingState.RTCSignalingStateHaveLocalOffer) {
        await peer.setLocalDescription(RTCSessionDescription('', 'rollback'));
      }
      final description = object(message['description']);
      await peer.setRemoteDescription(
        RTCSessionDescription(
          description.text('sdp'),
          description.text('type'),
        ),
      );
      _remoteReady.add(from);
      await _flush(from, peer);
      final answer = await peer.createAnswer();
      await peer.setLocalDescription(answer);
      send({
        'type': 'answer',
        'to': from,
        'description': (await peer.getLocalDescription())!.toMap(),
      });
      if (_needsOffer.remove(from)) await _offer(from, peer);
    } else if (type == 'answer' && peers[from] != null) {
      final peer = peers[from]!;
      final description = object(message['description']);
      await peer.setRemoteDescription(
        RTCSessionDescription(
          description.text('sdp'),
          description.text('type'),
        ),
      );
      _remoteReady.add(from);
      await _flush(from, peer);
      if (_needsOffer.remove(from)) await _offer(from, peer);
    } else if (type == 'ice' && !_ignored.contains(from)) {
      final candidate = object(message['candidate']);
      final ice = RTCIceCandidate(
        candidate.text('candidate'),
        candidate['sdpMid'] as String?,
        (candidate['sdpMLineIndex'] as num?)?.toInt(),
      );
      if (peers[from] != null && _remoteReady.contains(from)) {
        await _addCandidate(peers[from]!, ice);
      } else {
        final queue = _ice.putIfAbsent(from, () => []);
        if (queue.length < 64) queue.add(ice);
      }
    } else if (type == 'peer-left') {
      await remove(message.text('peerId'));
    } else if (type == 'attachment') {
      onAttachment?.call(message.text('attachmentId'));
    }
  }

  Future<void> _flush(String id, RTCPeerConnection peer) async {
    for (final candidate in _ice.remove(id) ?? <RTCIceCandidate>[]) {
      await _addCandidate(peer, candidate);
    }
  }

  Future<void> _addCandidate(
    RTCPeerConnection peer,
    RTCIceCandidate candidate,
  ) async {
    try {
      await peer.addCandidate(candidate);
    } on Object {
      // As in Railyard, an unsupported/mDNS route must not prevent an answer
      // or discard the remaining LAN/server-reflexive candidates.
    }
  }

  Future<void> _offer(String id, RTCPeerConnection peer) async {
    if (_closed || peers[id] != peer) return;
    if (_makingOffer.contains(id) ||
        await peer.getSignalingState() !=
            RTCSignalingState.RTCSignalingStateStable) {
      _needsOffer.add(id);
      return;
    }
    _makingOffer.add(id);
    try {
      final offer = await peer.createOffer();
      if (_closed || peers[id] != peer) return;
      await peer.setLocalDescription(offer);
      send({
        'type': 'offer',
        'to': id,
        'description': (await peer.getLocalDescription())!.toMap(),
      });
    } finally {
      _makingOffer.remove(id);
    }
  }

  Future<void> updateStream(MediaStream next) async {
    stream = next;
    for (final entry in peers.entries.toList()) {
      final remaining = [...next.getTracks()];
      for (final sender in await entry.value.getSenders()) {
        final kind = sender.track?.kind ?? _senderKinds[sender.senderId];
        final index = remaining.indexWhere((track) => track.kind == kind);
        await sender.replaceTrack(index < 0 ? null : remaining.removeAt(index));
      }
      for (final track in remaining) {
        final sender = await entry.value.addTrack(track, next);
        _senderKinds[sender.senderId] = track.kind!;
      }
      if (remaining.isNotEmpty) await _offer(entry.key, entry.value);
    }
  }

  List<String> get filePeers => channels.entries
      .where((e) => e.value.state == RTCDataChannelState.RTCDataChannelOpen)
      .map((e) => e.key)
      .toList();
  Future<bool> control(String id, Json value) async {
    final channel = channels[id];
    if (channel?.state != RTCDataChannelState.RTCDataChannelOpen) return false;
    try {
      await channel!.send(RTCDataChannelMessage(jsonEncode(value)));
      return true;
    } on Object {
      return false;
    }
  }

  Future<void> chunk(String id, Uint8List packet) async {
    final channel = channels[id];
    if (channel == null ||
        channel.state != RTCDataChannelState.RTCDataChannelOpen) {
      throw StateError('Peer disconnected');
    }
    if ((channel.bufferedAmount ?? 0) > 256 * 1024) {
      final ready = Completer<void>();
      channel.onBufferedAmountLow = (_) {
        if (!ready.isCompleted) ready.complete();
      };
      try {
        if ((await channel.getBufferedAmount()) > 128 * 1024) {
          await ready.future.timeout(const Duration(seconds: 20));
        }
      } finally {
        channel.onBufferedAmountLow = null;
      }
    }
    if (_closed || channel.state != RTCDataChannelState.RTCDataChannelOpen) {
      throw StateError('Peer disconnected');
    }
    await channel.send(RTCDataChannelMessage.fromBinary(packet));
  }

  Future<void> remove(String id) async {
    _ice.remove(id);
    _remoteReady.remove(id);
    _ignored.remove(id);
    _needsOffer.remove(id);
    _makingOffer.remove(id);
    final channel = channels.remove(id);
    if (channel != null) {
      await channel.close();
      onPeer?.call(id, false);
    }
    final peer = peers.remove(id);
    if (peer != null) {
      peer.onConnectionState = null;
      await peer.close();
      await peer.dispose();
    }
    onStream?.call(id, null);
  }

  Future<void> close() async {
    _closed = true;
    await _socket?.sink.close();
    _socket = null;
    for (final id in peers.keys.toList()) {
      await remove(id);
    }
  }
}
