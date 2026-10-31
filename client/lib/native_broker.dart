import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

Future<Map<String, dynamic>?> authorizeNativeBroker(
  String challenge,
  String state,
  String? username,
) async {
  if (kIsWeb || defaultTargetPlatform != TargetPlatform.android) return null;
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
