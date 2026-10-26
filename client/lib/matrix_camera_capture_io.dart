import 'dart:io';
import 'dart:typed_data';
import 'package:flutter_webrtc/flutter_webrtc.dart' as rtc;
import 'package:path_provider/path_provider.dart';

Future<Uint8List> captureMatrixQrFrame(rtc.MediaStreamTrack track) async {
  // flutter_webrtc's native capture writes a temporary PNG. Remove it as soon
  // as the image is in memory so verification secrets do not linger on disk.
  final temporary = await getTemporaryDirectory();
  final file = File('${temporary.path}/captureFrame.png');
  try {
    return (await track.captureFrame()).asUint8List();
  } finally {
    if (await file.exists()) await file.delete();
  }
}
