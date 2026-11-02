import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:river/api.dart';
import 'package:river/main.dart';
import 'package:river/rich_composer.dart';
import 'matrix_messaging_test.dart' show MemoryMatrixStorage;

void main() {
  testWidgets('bubble chat keeps the composer visible with the keyboard open', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(360, 640);
    tester.view.devicePixelRatio = 1;
    tester.view.viewInsets = const FakeViewPadding(bottom: 280);
    addTearDown(tester.view.reset);
    final app = RiverApi(live: false, matrixStorage: MemoryMatrixStorage())
      ..loading = false
      ..user = {'sub': 'alice', 'user_id': '@alice:home', 'username': 'Alice'}
      ..groups = [
        {
          'id': 'chat',
          'name': 'Weekend plans',
          'kind': 'dm',
          'membership': 'join',
          'members': <Json>[],
        },
      ]
      ..selected = 'chat';
    await tester.pumpWidget(RiverApp(api: app, boot: false));
    await tester.pumpAndSettle();
    final composer = find.byType(RichComposer);
    expect(composer, findsOneWidget);
    expect(tester.getBottomLeft(composer).dy, lessThanOrEqualTo(360));
    expect(find.byKey(const ValueKey('message-timeline')), findsOneWidget);
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox());
  });
}
