import 'dart:async';
import 'dart:convert';

import 'package:http/http.dart' as http;

/// A reconnect always refreshes the complete authorized read model. There is no
/// lossy sequence cursor or recurring HTTP polling while the connection is idle.
class LiveUpdates {
  LiveUpdates({
    required this.url,
    required this.headers,
    required this.changed,
    required this.revoked,
    this.prepare,
    http.Client? client,
  }) : _client = client ?? http.Client();
  final Uri url;
  final Map<String, String> Function() headers;
  final void Function() changed, revoked;
  final Future<void> Function()? prepare;
  final http.Client _client;
  StreamSubscription<String>? _subscription;
  Timer? _retry, _debounce;
  bool _closed = false;
  int _backoff = 1;

  Future<void> connect() async {
    if (_closed) return;
    try {
      await prepare?.call();
      if (_closed) return;
      final r = http.Request('GET', url)..headers.addAll(headers());
      final response = await _client
          .send(r)
          .timeout(const Duration(seconds: 20));
      if (_closed) return;
      if (response.statusCode == 401) {
        unawaited(response.stream.drain<void>());
        _reconnect();
        return;
      }
      if (response.statusCode == 403) {
        revoked();
        close();
        return;
      }
      if (response.statusCode != 200) {
        throw StateError('Live updates unavailable');
      }
      _subscription = response.stream
          .transform(utf8.decoder)
          .transform(const LineSplitter())
          .listen(
            (line) {
              if (line == 'event: ready') {
                _backoff = 1;
                _change();
              }
              if (line == 'event: invalidate') _change();
              if (line == 'event: revoked') {
                // An upstream access token can expire while streaming. The
                // next connection revalidates/renews through the normal API.
                unawaited(_subscription?.cancel());
                _reconnect();
              }
            },
            onError: (_) => _reconnect(),
            onDone: _reconnect,
            cancelOnError: true,
          );
    } on Object {
      _reconnect();
    }
  }

  void _change() {
    _debounce?.cancel();
    _debounce = Timer(const Duration(milliseconds: 80), () {
      if (!_closed) changed();
    });
  }

  void _reconnect() {
    if (_closed || (_retry?.isActive ?? false)) return;
    _retry = Timer(Duration(seconds: _backoff), () {
      _retry = null;
      unawaited(connect());
    });
    _backoff = (_backoff * 2).clamp(1, 60);
  }

  void close() {
    _closed = true;
    _retry?.cancel();
    _debounce?.cancel();
    unawaited(_subscription?.cancel());
    _client.close();
  }
}
