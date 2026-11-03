import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:livekit_client/livekit_client.dart';
import 'package:river/api.dart';

typedef RegisterMediaTest =
    void Function(
      String name,
      Future<void> Function() run, {
      required bool skip,
      required Timeout timeout,
    });
void mediaScenarios(
  RegisterMediaTest register, {
  bool native = false,
  Future<void> Function(RiverApi)? display,
}) {
  register(
    'shared call client exchanges real camera and audio tracks through Go-issued SFU credentials',
    () async {
      RiverApi api() {
        final transport = http.Client();
        final a = RiverApi(
          live: false,
          client: MockClient((r) async {
            final next =
                http.Request(
                    r.method,
                    Uri.parse(
                      'http://127.0.0.1:57890',
                    ).replace(path: r.url.path, query: r.url.query),
                  )
                  ..headers.addAll(r.headers)
                  ..bodyBytes = r.bodyBytes;
            return http.Response.fromStream(await transport.send(next));
          }),
        );
        a.user = {
          'sub': 'local-test',
          'username': 'local-test',
          'user_id': '@local:gravitas.test',
        };
        a.loading = false;
        return a;
      }

      final a = api(), b = api();
      if (!native) {
        // This headless transport test has no visible video tile. Disable the
        // SDK's expected off-screen pause while checking decoded frame growth.
        a.calls.adaptiveStreamForTesting = false;
        b.calls.adaptiveStreamForTesting = false;
      }
      final target = <String, dynamic>{
        'id': '11111111-1111-4111-8111-111111111111',
        'name': 'Synthetic media test',
        'kind': 'dm',
      };
      try {
        await a.calls.join(target);
        await b.calls.join(target);
        await display?.call(b);
        await a.calls.toggleCamera();
        if (!native) await b.calls.toggleCamera();
        Future<void> until(bool Function() ready) async {
          for (var i = 0; i < 100 && !ready(); i++) {
            await Future<void>.delayed(const Duration(milliseconds: 200));
          }
          expect(ready(), isTrue);
        }

        bool subscribed(RiverApi x) =>
            x.calls.room!.remoteParticipants.values.any(
              (p) =>
                  p.videoTrackPublications.any(
                    (t) => t.track is RemoteVideoTrack,
                  ) &&
                  p.audioTrackPublications.any(
                    (t) => t.track is RemoteAudioTrack,
                  ),
            );
        await until(
          () =>
              (native
                  ? a.calls.room!.remoteParticipants.values.any(
                      (p) => p.audioTrackPublications.any(
                        (t) => t.track is RemoteAudioTrack,
                      ),
                    )
                  : subscribed(a)) &&
              subscribed(b),
        );
        final video =
            b
                    .calls
                    .room!
                    .remoteParticipants
                    .values
                    .first
                    .videoTrackPublications
                    .first
                    .track
                as RemoteVideoTrack;
        num frames = 0;
        for (var i = 0; i < 40 && frames == 0; i++) {
          await Future<void>.delayed(const Duration(milliseconds: 200));
          frames = (await video.getReceiverStats())?.framesDecoded ?? 0;
        }
        expect(frames, greaterThan(0));
        if (const bool.fromEnvironment('RIVER_TEST_TURN')) {
          await a.calls.renewTransport();
          await b.calls.renewTransport();
          expect(a.calls.error, isNull, reason: '${a.calls.controlFailure}');
          expect(b.calls.error, isNull, reason: '${b.calls.controlFailure}');
          await until(() => subscribed(b));
          final resumed =
              b
                      .calls
                      .room!
                      .remoteParticipants
                      .values
                      .first
                      .videoTrackPublications
                      .first
                      .track
                  as RemoteVideoTrack;
          final before = (await resumed.getReceiverStats())?.framesDecoded ?? 0;
          for (var i = 0; i < 60; i++) {
            await Future<void>.delayed(const Duration(milliseconds: 200));
            if (((await resumed.getReceiverStats())?.framesDecoded ?? 0) >
                before) {
              break;
            }
          }
          expect(
            (await resumed.getReceiverStats())?.framesDecoded ?? 0,
            greaterThan(before),
          );
        }
        await a.calls.toggleMute();
        expect(a.calls.muted, isTrue);
        await a.calls.toggleMute();
        expect(a.calls.muted, isFalse);
        await b.calls.toggleDeafen();
        expect(b.calls.deafened, isTrue);
        await b.calls.toggleDeafen();
        expect(b.calls.deafened, isFalse);
        expect(a.calls.chat, isNotNull);
        if (native && const bool.fromEnvironment('RIVER_TEST_SCREEN')) {
          await a.calls.toggleSharing();
          expect(a.calls.error, isNull, reason: '${a.calls.controlFailure}');
          await display?.call(b);
          expect(a.calls.sharing, isTrue);
          await until(
            () => b.calls.room!.remoteParticipants.values.any(
              (p) => p.videoTrackPublications.any(
                (t) =>
                    t.source == TrackSource.screenShareVideo &&
                    t.track is RemoteVideoTrack,
              ),
            ),
          );
          final screen =
              b
                      .calls
                      .room!
                      .remoteParticipants
                      .values
                      .first
                      .videoTrackPublications
                      .firstWhere(
                        (t) => t.source == TrackSource.screenShareVideo,
                      )
                      .track
                  as RemoteVideoTrack;
          num screenFrames = 0;
          for (var i = 0; i < 50 && screenFrames == 0; i++) {
            await Future<void>.delayed(const Duration(milliseconds: 200));
            screenFrames =
                (await screen.getReceiverStats())?.framesDecoded ?? 0;
          }
          expect(screenFrames, greaterThan(0));
          if (const bool.fromEnvironment('RIVER_TEST_TURN')) {
            await a.calls.renewTransport();
            expect(a.calls.error, isNull, reason: '${a.calls.controlFailure}');
            expect(a.calls.sharing, isTrue);
            await until(
              () => b.calls.room!.remoteParticipants.values.any(
                (p) => p.videoTrackPublications.any(
                  (t) =>
                      t.source == TrackSource.screenShareVideo &&
                      t.track is RemoteVideoTrack,
                ),
              ),
            );
            final resumedScreen =
                b
                        .calls
                        .room!
                        .remoteParticipants
                        .values
                        .first
                        .videoTrackPublications
                        .firstWhere(
                          (t) => t.source == TrackSource.screenShareVideo,
                        )
                        .track
                    as RemoteVideoTrack;
            num decoded = 0;
            for (var i = 0; i < 60 && decoded == 0; i++) {
              await Future<void>.delayed(const Duration(milliseconds: 200));
              decoded =
                  (await resumedScreen.getReceiverStats())?.framesDecoded ?? 0;
            }
            expect(decoded, greaterThan(0));
          }
          await a.calls.toggleSharing();
          expect(a.calls.sharing, isFalse);
        }
        await a.calls.leave();
        await until(() => b.calls.room!.remoteParticipants.isEmpty);
        expect(a.calls.active, isFalse);
      } finally {
        await a.calls.leave();
        await b.calls.leave();
        a.dispose();
        b.dispose();
      }
    },
    skip: !const bool.fromEnvironment('RIVER_LOCAL_MEDIA_TEST'),
    timeout: Timeout(Duration(minutes: native ? 8 : 3)),
  );
}
