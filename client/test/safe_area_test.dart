import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:river/api.dart';
import 'package:river/home_widgets.dart';
import 'package:river/main.dart';
import 'package:river/rich_composer.dart';

import 'matrix_messaging_test.dart' show MemoryMatrixStorage;

void screen(WidgetTester tester, Size size, FakeViewPadding insets) {
  tester.view
    ..devicePixelRatio = 1
    ..physicalSize = size
    ..viewPadding = insets
    ..padding = insets;
}

RiverApi signedIn({String? kind}) =>
    RiverApi(live: false, matrixStorage: MemoryMatrixStorage())
      ..loading = false
      ..user = {'sub': 'alice', 'username': 'Alice'}
      ..groups = [
        if (kind != null)
          {
            'id': 'room',
            'name': 'Our room',
            'kind': kind,
            'membership': 'join',
            'members': <Json>[],
          },
      ]
      ..selected = kind == null ? null : 'room';

void main() {
  for (final device in [
    (
      name: 'portrait camera cutout',
      size: const Size(390, 844),
      insets: const FakeViewPadding(top: 48, bottom: 24),
    ),
    (
      name: 'landscape camera cutout',
      size: const Size(844, 390),
      insets: const FakeViewPadding(top: 24, left: 48, right: 12, bottom: 24),
    ),
    (
      name: 'tablet status bar',
      size: const Size(1200, 900),
      insets: const FakeViewPadding(top: 32, bottom: 24),
    ),
    (
      name: 'desktop without system insets',
      size: const Size(1440, 1000),
      insets: const FakeViewPadding(),
    ),
  ]) {
    for (final kind in ['dm', 'space']) {
      testWidgets('$kind controls clear the ${device.name}', (tester) async {
        screen(tester, device.size, device.insets);
        addTearDown(tester.view.reset);
        await tester.pumpWidget(
          RiverApp(api: signedIn(kind: kind), boot: false),
        );
        await tester.pumpAndSettle();

        for (final tooltip in [
          'Home',
          'Group options',
          if (device.size.width < 1000) 'Open navigation menu',
        ]) {
          final rect = tester.getRect(find.byTooltip(tooltip));
          expect(rect.top, greaterThanOrEqualTo(device.insets.top));
          expect(rect.left, greaterThanOrEqualTo(device.insets.left));
          expect(
            rect.right,
            lessThanOrEqualTo(device.size.width - device.insets.right),
          );
        }
        if (kind == 'dm') {
          expect(
            MediaQuery.paddingOf(tester.element(find.byType(RichComposer))).top,
            0,
          );
        }
        if (device.insets.top == 0) {
          expect(tester.getTopLeft(find.byTooltip('Home')).dy, lessThan(24));
        }
        expect(tester.takeException(), isNull);
        await tester.pumpWidget(const SizedBox());
      }, variant: TargetPlatformVariant.only(TargetPlatform.android));
    }
  }

  testWidgets('Home AppBar consumes the status bar inset only once', (
    tester,
  ) async {
    screen(
      tester,
      const Size(390, 844),
      const FakeViewPadding(top: 48, bottom: 24),
    );
    addTearDown(tester.view.reset);
    await tester.pumpWidget(RiverApp(api: signedIn(), boot: false));
    await tester.pumpAndSettle();
    expect(tester.getSize(find.byType(AppBar)).height, 48 + kToolbarHeight);
    expect(tester.getTopLeft(find.byType(RiverHome)).dy, 48 + kToolbarHeight);
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox());
  }, variant: TargetPlatformVariant.only(TargetPlatform.android));

  testWidgets('conversation adapts to rotation and keyboard insets', (
    tester,
  ) async {
    screen(tester, const Size(390, 844), const FakeViewPadding(top: 48));
    addTearDown(tester.view.reset);
    await tester.pumpWidget(RiverApp(api: signedIn(kind: 'dm'), boot: false));
    await tester.pumpAndSettle();
    screen(
      tester,
      const Size(844, 390),
      const FakeViewPadding(top: 24, left: 48, bottom: 24),
    );
    await tester.pumpAndSettle();
    expect(
      tester.getTopLeft(find.byTooltip('Home')).dy,
      greaterThanOrEqualTo(24),
    );
    expect(
      tester.getTopLeft(find.byTooltip('Open navigation menu')).dx,
      greaterThanOrEqualTo(48),
    );
    screen(tester, const Size(390, 844), const FakeViewPadding(top: 48));
    tester.view.viewInsets = const FakeViewPadding(bottom: 300);
    await tester.pumpAndSettle();
    expect(
      tester.getTopLeft(find.byTooltip('Home')).dy,
      greaterThanOrEqualTo(48),
    );
    expect(
      tester.getBottomLeft(find.byType(RichComposer)).dy,
      lessThanOrEqualTo(844 - 300),
    );
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox());
  }, variant: TargetPlatformVariant.only(TargetPlatform.android));
}
