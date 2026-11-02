import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

class StoreNotifications {
  static bool get supported =>
      !kIsWeb && defaultTargetPlatform == TargetPlatform.android;
  static const channel = MethodChannel('cool.gravitas.river/notifications');
  static Future<Map<String, dynamic>> call(
    String method, [
    Map<String, dynamic>? arguments,
  ]) async {
    if (!supported) return {};
    try {
      return await channel.invokeMapMethod<String, dynamic>(
            method,
            arguments,
          ) ??
          {};
    } on MissingPluginException {
      return {};
    } on PlatformException {
      return {};
    }
  }

  static Future<Map<String, dynamic>> bind(Map<String, dynamic> profile) =>
      call('bind', {'issuer': profile['issuer'], 'subject': profile['sub']});
  static Future<void> clear() async {
    await call('clear');
  }
}
