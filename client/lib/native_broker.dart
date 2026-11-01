import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'desktop_broker.dart' as desktop;

Future<Map<String, dynamic>?> authorizeNativeBroker(
  String challenge,
  String state,
  String? username, {
  String appOrigin = 'https://chat.gravitas.cool',
}) async {
  if (kIsWeb) return null;
  if ([
    TargetPlatform.macOS,
    TargetPlatform.windows,
    TargetPlatform.linux,
  ].contains(defaultTargetPlatform)) {
    return desktop.authorize(appOrigin, challenge, state, username);
  }
  if (defaultTargetPlatform != TargetPlatform.android ||
      appOrigin != 'https://chat.gravitas.cool') {
    return null;
  }
  try {
    final result = await const MethodChannel('cool.gravitas.river/auth')
        .invokeMapMethod<String, dynamic>('broker', {
          'challenge': challenge,
          'state': state,
          'username': username,
        });
    if (result?['status'] == 'cancelled') {
      throw StateError('Sign-in cancelled.');
    }
    return result?['status'] == 'authorized' ? result : null;
  } on MissingPluginException {
    return null;
  } on PlatformException {
    return null;
  }
}
