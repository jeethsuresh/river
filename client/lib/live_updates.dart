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
    http.Client? client,
  }) : _client = client ?? http.Client();
  final Uri url;
  final Map<String, String> Function() headers;
  final void Function() changed, revoked;
  final http.Client _client;
  StreamSubscription<String>? _subscription;
  Timer? _retry, _debounce;
  bool _closed = false;
  int _backoff = 1;

  Future<void> connect() async {
    if (_closed) return;
    try {
      final r = http.Request('GET', url)..headers.addAll(headers());
      final response = await _client
          .send(r)
          .timeout(const Duration(seconds: 20));
      if (_closed) return;
      if (response.statusCode == 401 || response.statusCode == 403) {
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
                revoked();
                close();
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
