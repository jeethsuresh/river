import 'package:flutter_test/flutter_test.dart';
import 'package:river/content_widgets.dart';
import 'editor_scenarios.dart';

void main() {
  editorScenarios();
  test(
    'content links support Orbit web/mail/relative links and reject unsafe schemes',
    () {
      for (final value in [
        'https://example.com/post',
        'mailto:friend@example.com',
        '/posts/hello',
        '#reply',
      ]) {
        expect(contentLink(value), isNotNull);
      }
      for (final value in [
        'javascript:alert(1)',
        'data:text/html,secret',
        'file:///secret',
        '//tracker.test/x',
        r'\evil.test\x',
        'https://user:password@example.com',
      ]) {
        expect(contentLink(value), isNull);
      }
    },
  );
}
