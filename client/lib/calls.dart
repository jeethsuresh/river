import 'dart:async';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter_webrtc/flutter_webrtc.dart' as rtc;
import 'package:livekit_client/livekit_client.dart';
import 'api.dart';

class RiverCalls extends ChangeNotifier {
  RiverCalls(this.api);
  final RiverApi api;
  static const native = MethodChannel('cool.gravitas.river/call');
  Room? room;
  Json? target;
  String? member, identity, error;
  Timer? heartbeat;
  EventsListener<RoomEvent>? listener;
  bool busy = false,
      deafened = false,
      speaker = true,
      _beating = false,
      _disposed = false;
  int _epoch = 0;
  Future<void>? _leaving;
  bool get android =>
      !kIsWeb && defaultTargetPlatform == TargetPlatform.android;
  bool get active => room != null;
  bool get muted => !(room?.localParticipant?.isMicrophoneEnabled() ?? false);
  bool get cameraOn => room?.localParticipant?.isCameraEnabled() ?? false;
  bool get sharing => room?.localParticipant?.isScreenShareEnabled() ?? false;
  Future<void> service({bool projection = false}) async {
    if (android) {
      await native.invokeMethod('start', {
        'camera': cameraOn,
        'projection': projection,
      });
    }
  }

  Future<void> join(Json next) async {
    if (busy || active && target?['id'] == next['id']) return;
    busy = true;
    error = null;
    notifyListeners();
    try {
      await leave();
      final epoch = ++_epoch;
      final id =
          transactionId().substring(0, 32) + transactionId().substring(0, 11);
      member = id;
      target = next;
      final result = await api.request(
        '/api/groups/${next['id']}/rtc',
        method: 'POST',
        body: {'action': 'join', 'member_id': id},
      );
      if (epoch != _epoch) {
        await api.request(
          '/api/groups/${next['id']}/rtc',
          method: 'POST',
          body: {'action': 'leave', 'member_id': id},
        );
        return;
      }
      identity = result['identity'] as String;
      if (android) {
        final permission = await rtc.navigator.mediaDevices.getUserMedia({
          'audio': true,
          'video': false,
        });
        for (final track in permission.getTracks()) {
          await track.stop();
        }
        await permission.dispose();
        await service();
      }
      final media = Room(
        roomOptions: const RoomOptions(adaptiveStream: true, dynacast: true),
      );
      room = media;
      media.addListener(changed);
      listener = media.createListener()
        ..on<RoomDisconnectedEvent>((_) {
          error = 'The call ended or access changed.';
          unawaited(leave());
        })
        ..on<TrackSubscribedEvent>((event) {
          if (deafened && event.track is AudioTrack) {
            unawaited(event.publication.unsubscribe());
          }
        });
      await media.connect(
        result['transport_url'] as String,
        result['jwt'] as String,
      );
      if (epoch != _epoch) {
        await media.disconnect();
        await media.dispose();
        return;
      }
      await media.localParticipant?.setMicrophoneEnabled(true);
      if (android) {
        await AudioManager.instance.setSpeakerOutputPreferred(speaker);
      }
      heartbeat = Timer.periodic(
        const Duration(seconds: 20),
        (_) => unawaited(beat()),
      );
      await api.refresh();
    } catch (_) {
      await leave();
      error =
          'Could not join this call. Check microphone permission, your connection and River access, then try again.';
      rethrow;
    } finally {
      busy = false;
      notifyListeners();
    }
  }

  Future<void> beat() async {
    if (target == null || member == null || _beating) return;
    _beating = true;
    try {
      await api.request(
        '/api/groups/${target!['id']}/rtc',
        method: 'POST',
        body: {'action': 'renew', 'member_id': member},
      );
    } catch (_) {
      error = 'Call access could not be renewed. Please rejoin.';
      await leave();
    } finally {
      _beating = false;
      notifyListeners();
    }
  }

  void changed() {
    if (!_disposed) notifyListeners();
  }

  Future<void> control(Future<void> Function() action) async {
    if (busy || room == null) return;
    busy = true;
    error = null;
    notifyListeners();
    try {
      await action();
    } catch (_) {
      error = 'That media change failed. Check permission and try again.';
    } finally {
      busy = false;
      notifyListeners();
    }
  }

  Future<void> toggleMute() => control(() async {
    await room?.localParticipant?.setMicrophoneEnabled(muted);
  });
  Future<void> toggleCamera() => control(() async {
    final enabled = !cameraOn;
    // Android must grant camera permission before changing foreground service type.
    await room?.localParticipant?.setCameraEnabled(enabled);
    try {
      await service(projection: sharing);
    } catch (_) {
      await room?.localParticipant?.setCameraEnabled(false);
      rethrow;
    }
  });
  Future<void> toggleSharing() => control(() async {
    final enabled = !sharing;
    if (android && enabled) {
      if (!await rtc.Helper.requestCapturePermission()) {
        throw StateError('Screen capture declined');
      }
      await service(projection: true);
    }
    try {
      await room?.localParticipant?.setScreenShareEnabled(enabled);
    } catch (_) {
      await service(projection: false);
      rethrow;
    }
    if (!enabled) await service(projection: false);
  });
  Future<void> toggleSpeaker() => control(() async {
    await AudioManager.instance.setSpeakerOutputPreferred(!speaker);
    speaker = !speaker;
  });
  Future<void> switchCamera() => control(() async {
    final track = room?.localParticipant
        ?.getTrackPublicationBySource(TrackSource.camera)
        ?.track;
    if (track is LocalVideoTrack &&
        track.currentOptions is CameraCaptureOptions) {
      final current =
          (track.currentOptions as CameraCaptureOptions).cameraPosition;
      await track.setCameraPosition(
        current == CameraPosition.front
            ? CameraPosition.back
            : CameraPosition.front,
      );
    }
  });
  Future<void> toggleDeafen() => control(() async {
    deafened = !deafened;
    for (final participant
        in room?.remoteParticipants.values ?? <RemoteParticipant>[]) {
      for (final publication in participant.audioTrackPublications) {
        if (deafened) {
          await publication.unsubscribe();
        } else {
          await publication.subscribe();
        }
      }
    }
  });
  Future<void> leave() {
    if (_leaving != null) return _leaving!;
    final operation = _leave();
    _leaving = operation;
    return operation.whenComplete(() => _leaving = null);
  }

  Future<void> _leave() async {
    _epoch++;
    final previous = room, oldTarget = target, oldMember = member;
    room = null;
    target = null;
    member = null;
    identity = null;
    heartbeat?.cancel();
    heartbeat = null;
    await listener?.dispose();
    listener = null;
    previous?.removeListener(changed);
    try {
      await previous?.disconnect();
    } catch (_) {
      /* Always release native resources. */
    }
    try {
      await previous?.dispose();
    } catch (_) {
      /* The SDK may have completed disposal. */
    }
    if (android) {
      try {
        await native.invokeMethod('stop');
      } catch (_) {
        /* The OS can stop an already-ended service. */
      }
    }
    if (oldTarget != null && oldMember != null) {
      try {
        await api.request(
          '/api/groups/${oldTarget['id']}/rtc',
          method: 'POST',
          body: {'action': 'leave', 'member_id': oldMember},
        );
      } catch (_) {
        /* The SFU reaper also enforces the expiring, centrally checked lease. */
      }
    }
    deafened = false;
    notifyListeners();
  }

  @override
  void notifyListeners() {
    if (!_disposed) super.notifyListeners();
  }

  @override
  void dispose() {
    _disposed = true;
    unawaited(leave());
    super.dispose();
  }
}
