import 'dart:typed_data';
import 'package:flutter_webrtc/flutter_webrtc.dart' as rtc;

Future<Uint8List> captureMatrixQrFrame(rtc.MediaStreamTrack track) async =>
    (await track.captureFrame()).asUint8List();
