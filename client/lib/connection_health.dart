import 'dart:async';

/// A brief failure is retried quietly. A warning needs another failure after
/// the grace period; elapsed time alone does not establish an outage.
class ConnectionHealth {
  ConnectionHealth(this.changed);

  final void Function() changed;
  static const grace = Duration(seconds: 8);
  Timer? _grace;
  bool _retrying = false,
      _confirmed = false,
      _elapsed = false,
      _disposed = false;
  int _sequence = 0, _lastSuccess = 0, _minimum = 0;

  bool get retrying => _retrying;
  bool get unavailable => _confirmed;
  int begin() => ++_sequence;

  void failed(int request) {
    // A slow failure must not overturn a newer successful request.
    if (_disposed || request < _minimum || request < _lastSuccess) return;
    if (!_retrying) {
      _retrying = true;
      _grace = Timer(grace, () => _elapsed = true);
      changed();
    } else if (_elapsed && !_confirmed) {
      _confirmed = true;
      changed();
    }
  }

  void succeeded(int request) {
    if (_disposed || request < _minimum) return;
    if (request > _lastSuccess) _lastSuccess = request;
    if (!_retrying) return;
    _clear();
    changed();
  }

  void _clear() {
    _grace?.cancel();
    _grace = null;
    _retrying = _confirmed = _elapsed = false;
  }

  void reset() {
    _minimum = ++_sequence;
    _lastSuccess = _minimum;
    _clear();
  }

  void dispose() {
    _disposed = true;
    _clear();
  }
}
