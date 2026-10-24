// ignore_for_file: invalid_use_of_internal_member
// LiveKit 2.13.1 has no public credential-update API. Keep its pinned transport
// access confined to this adapter, covered by browser/Android media tests.
import 'package:livekit_client/livekit_client.dart';
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
  final configuration = callConfiguration(result);
  room.engine.connectOptions = ConnectOptions(
    autoSubscribe: previous.autoSubscribe,
    protocolVersion: previous.protocolVersion,
    clientProtocolVersion: previous.clientProtocolVersion,
    timeouts: previous.timeouts,
    rtcConfiguration: configuration,
  );
  // Active Coturn allocations retain their authenticated session key. Install
  // fresh credentials for subsequent allocations and SDK network reconnects,
  // without replacing capture streams or interrupting Android MediaProjection.
  if (room.connectionState == ConnectionState.connected) {
    await room.engine.publisher?.pc.setConfiguration(configuration.toMap());
    await room.engine.subscriber?.pc.setConfiguration(configuration.toMap());
  }
}

void updateCallToken(Room room, String token) {
  room.engine.token = token;
}
