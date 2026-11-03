import 'dart:async';
import 'package:flutter/services.dart';
import 'api.dart';

/// One Dart isolate and Matrix device serve headless jobs, the app and bubbles.
/// Foreground boot waits for cold restoration; later previews reuse that boot.
class NotificationRuntime {
  NotificationRuntime(this.app, this.show);
  static const channel = MethodChannel(
    'cool.gravitas.river/notification-runtime',
  );
  final RiverApi app;
  final void Function(Future<void> startup) show;
  Future<void> _queue = Future.value();
  Future<void>? _startup;

  Future<void> start() async {
    channel.setMethodCallHandler((call) async {
      if (call.method == 'show') {
        open();
        return null;
      }
      if (call.method != 'preview' || call.arguments is! Map) return null;
      final ticket = (call.arguments as Map).cast<String, dynamic>();
      final foreground = _startup;
      final task = _queue.then((_) async {
        try {
          return await app.notificationPreview(
            ticket,
            restore: foreground == null,
          );
        } catch (_) {
          // Offline, missing keys, expired sessions and locked keystores keep
          // the generic native alert. Never log private message material.
          return <String, dynamic>{};
        }
      });
      _queue = task.then<void>((_) {}, onError: (Object _, StackTrace _) {});
      return task;
    });
    final foreground = await channel.invokeMethod<bool>('ready') ?? false;
    if (foreground) open();
  }

  void open() {
    if (_startup != null) return;
    _startup = _queue.then((_) => app.boot());
    _queue = _startup!;
    show(_startup!);
  }
}
