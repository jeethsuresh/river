// ignore_for_file: implementation_imports, invalid_use_of_internal_member
// The SDK adapter is version-pinned and covered by real browser/Android media tests.
import 'package:livekit_client/livekit_client.dart';
// LiveKit 2.13.1 has no public credential-update API. Keep the pinned SDK
// reconnect reason confined to this adapter and exercise it in real media tests.
import 'package:livekit_client/src/types/internal.dart'
    show ClientDisconnectReason;
import 'api.dart';

RTCConfiguration callConfiguration(Json result) => RTCConfiguration(
  iceTransportPolicy: result['iceTransportPolicy'] == 'relay'
      ? RTCIceTransportPolicy.relay
      : RTCIceTransportPolicy.all,
  iceServers: [
    for (final ice in ((result['iceServers'] as List?) ?? []).cast<Json>())
      RTCIceServer(
        urls: (ice['urls'] as List).cast<String>(),
        username: ice['username'] as String?,
        credential: ice['credential'] as String?,
      ),
  ],
);

Future<void> renewCallTransport(Room room, Json result) async {
  if (result['jwt'] is String) room.engine.token = result['jwt'] as String;
  final previous = room.connectOptions;
  room.engine.connectOptions = ConnectOptions(
    autoSubscribe: previous.autoSubscribe,
    protocolVersion: previous.protocolVersion,
    clientProtocolVersion: previous.clientProtocolVersion,
    timeouts: previous.timeouts,
    rtcConfiguration: callConfiguration(result),
  );
  // The SDK applies both ICE configurations and renegotiates the existing
  // publisher/subscriber transports, preserving tracks and the call membership.
  // Clean up the old signaling socket before resuming; otherwise its close
  // callback can race the replacement connection and mark it disconnected.
  await room.engine.signalClient.cleanUp();
  room.engine.fullReconnectOnNext = true;
  await room.engine.handleReconnect(ClientDisconnectReason.reconnect);
  for (var i = 0; i < 150; i++) {
    await Future<void>.delayed(const Duration(milliseconds: 100));
    if (!room.engine.isPendingReconnect && room.connectionState == ConnectionState.connected) return;
  }
  throw StateError('The call could not reconnect with fresh credentials.');
}

void updateCallToken(Room room, String token) {
  room.engine.token = token;
}
