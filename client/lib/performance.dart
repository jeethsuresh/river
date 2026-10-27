import 'dart:developer';

/// Bounded, local latency samples. Labels are fixed operation names: never
/// include message bodies, room/user IDs, URLs, credentials, or attachment data.
/// Timeline tasks appear in Flutter DevTools in profile builds.
class RiverPerformance {
  static const capacity = 256;
  static final _samples =
      <({String operation, int microseconds, bool failed})>[];

  static Future<T> measure<T>(
    String operation,
    Future<T> Function() run,
  ) async {
    final task = TimelineTask()..start(operation);
    final watch = Stopwatch()..start();
    var failed = false;
    try {
      return await run();
    } catch (_) {
      failed = true;
      rethrow;
    } finally {
      _samples.add((
        operation: operation,
        microseconds: watch.elapsedMicroseconds,
        failed: failed,
      ));
      if (_samples.length > capacity) _samples.removeAt(0);
      task.finish(arguments: {'failed': failed});
    }
  }

  static Map<String, Object> snapshot() {
    final names = _samples.map((s) => s.operation).toSet();
    return {for (final name in names) name: _summary(name)};
  }

  static Map<String, Object> _summary(String operation) {
    final samples = _samples.where((s) => s.operation == operation).toList();
    final times = samples.map((s) => s.microseconds).toList()..sort();
    int percentile(double p) => times[(times.length * p).ceil() - 1];
    return {
      'count': times.length,
      'failures': samples.where((s) => s.failed).length,
      'p50_us': percentile(.50),
      'p95_us': percentile(.95),
      'max_us': times.last,
    };
  }

  static void clear() => _samples.clear();
}
