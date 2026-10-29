import 'package:flutter_test/flutter_test.dart';
import 'package:river/connection_health.dart';

void main() {
  testWidgets('a transient failure and elapsed time alone stay quiet', (
    tester,
  ) async {
    final health = ConnectionHealth(() {});
    addTearDown(health.dispose);
    health.failed(health.begin());
    expect(health.retrying, isTrue);
    expect(health.unavailable, isFalse);
    await tester.pump(const Duration(seconds: 30));
    expect(health.unavailable, isFalse);
    health.succeeded(health.begin());
    expect(health.retrying, isFalse);
    health.failed(health.begin());
    expect(health.unavailable, isFalse);
    health.dispose();
  });

  testWidgets(
    'only another failure after the grace period confirms an outage',
    (tester) async {
      final health = ConnectionHealth(() {});
      addTearDown(health.dispose);
      health.failed(health.begin());
      health.failed(health.begin());
      await tester.pump(ConnectionHealth.grace);
      expect(health.unavailable, isFalse);
      health.failed(health.begin());
      expect(health.unavailable, isTrue);
      health.succeeded(health.begin());
      expect(health.unavailable, isFalse);
      expect(health.retrying, isFalse);
    },
  );

  testWidgets('an old failure cannot undo a newer successful request', (
    tester,
  ) async {
    final health = ConnectionHealth(() {});
    addTearDown(health.dispose);
    final slow = health.begin();
    health.succeeded(health.begin());
    health.failed(slow);
    await tester.pump(const Duration(seconds: 30));
    expect(health.retrying, isFalse);
    expect(health.unavailable, isFalse);
  });

  testWidgets(
    'a successful long poll can recover after a newer request failed',
    (tester) async {
      final health = ConnectionHealth(() {});
      addTearDown(health.dispose);
      final poll = health.begin();
      health.failed(health.begin());
      health.succeeded(poll);
      expect(health.retrying, isFalse);
    },
  );

  testWidgets(
    'account reset ignores old responses and disposal cancels timers',
    (tester) async {
      var changes = 0;
      final health = ConnectionHealth(() => changes++);
      final old = health.begin();
      health.failed(old);
      health.reset();
      health.failed(old);
      expect(health.retrying, isFalse);
      health.failed(health.begin());
      health.succeeded(old);
      expect(health.retrying, isTrue);
      health.dispose();
      final previous = changes;
      await tester.pump(const Duration(seconds: 30));
      health.failed(health.begin());
      expect(changes, previous);
    },
  );
}
