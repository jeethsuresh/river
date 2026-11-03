import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:river/api.dart';
import 'package:river/main.dart';
import 'package:river/rich_composer.dart';

import 'matrix_messaging_test.dart' show MemoryMatrixStorage;

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

Future<void> phone(WidgetTester tester) async {
  await tester.binding.setSurfaceSize(const Size(390, 844));
  addTearDown(() => tester.binding.setSurfaceSize(null));
}

ScaffoldState shell(WidgetTester tester) => tester.state<ScaffoldState>(
  find.descendant(of: find.byType(RiverShell), matching: find.byType(Scaffold)),
);

Future<void> back(WidgetTester tester) async {
  await tester.binding.handlePopRoute();
  await tester.pumpAndSettle();
}

Future<GlobalKey<NavigatorState>> pushShell(
  WidgetTester tester,
  RiverApi app,
) async {
  final navigator = GlobalKey<NavigatorState>();
  await tester.pumpWidget(
    MaterialApp(
      navigatorKey: navigator,
      home: const Scaffold(body: Text('Previous view')),
    ),
  );
  navigator.currentState!.push<void>(
    MaterialPageRoute(builder: (_) => RiverShell(app: app)),
  );
  await tester.pumpAndSettle();
  addTearDown(app.dispose);
  return navigator;
}

void main() {
  for (final kind in [null, 'dm', 'space']) {
    testWidgets('two Backs open the sidebar then leave ${kind ?? 'Home'}', (
      tester,
    ) async {
      await phone(tester);
      final calls = <String>[];
      tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
        SystemChannels.platform,
        (call) async {
          calls.add(call.method);
          return null;
        },
      );
      addTearDown(
        () => tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
          SystemChannels.platform,
          null,
        ),
      );
      final app = signedIn(kind: kind);
      await tester.pumpWidget(RiverApp(api: app, boot: false));
      await tester.pumpAndSettle();
      if (kind == 'dm') {
        tester.widget<RichComposer>(find.byType(RichComposer)).controller.text =
            'Unsent draft';
        await tester.pumpAndSettle();
      }

      await back(tester);
      expect(shell(tester).isDrawerOpen, isTrue);
      expect(app.selected, kind == null ? null : 'room');
      expect(calls.where((method) => method == 'SystemNavigator.pop'), isEmpty);

      await back(tester);
      expect(shell(tester).isDrawerOpen, isFalse);
      expect(
        calls.where((method) => method == 'SystemNavigator.pop'),
        hasLength(1),
      );
      if (kind == 'dm') {
        expect(
          tester
              .widget<RichComposer>(find.byType(RichComposer))
              .controller
              .text,
          'Unsent draft',
        );
      }
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox());
    });
  }

  for (final opening in ['back', 'menu', 'edge swipe']) {
    testWidgets(
      'Back after opening with $opening returns to the previous view',
      (tester) async {
        await phone(tester);
        await pushShell(tester, signedIn(kind: 'dm'));
        if (opening == 'back') {
          await back(tester);
        } else if (opening == 'menu') {
          await tester.tap(find.byTooltip('Open navigation menu'));
          await tester.pumpAndSettle();
        } else {
          await tester.dragFrom(const Offset(1, 400), const Offset(300, 0));
          await tester.pumpAndSettle();
        }
        expect(shell(tester).isDrawerOpen, isTrue);

        await back(tester);
        expect(find.text('Previous view'), findsOneWidget);
        expect(find.byType(RiverShell), findsNothing);
        expect(tester.takeException(), isNull);
      },
    );
  }

  testWidgets('dismissing the sidebar rearms the first Back', (tester) async {
    await phone(tester);
    await pushShell(tester, signedIn());
    await back(tester);
    await tester.tapAt(const Offset(380, 400));
    await tester.pumpAndSettle();
    expect(shell(tester).isDrawerOpen, isFalse);

    await back(tester);
    expect(shell(tester).isDrawerOpen, isTrue);
    expect(find.byType(RiverShell), findsOneWidget);
    await back(tester);
    expect(find.text('Previous view'), findsOneWidget);
  });

  testWidgets('a second Back during the opening animation still goes back', (
    tester,
  ) async {
    await phone(tester);
    await pushShell(tester, signedIn());
    await tester.binding.handlePopRoute();
    await tester.pump(const Duration(milliseconds: 16));
    await back(tester);
    expect(find.text('Previous view'), findsOneWidget);
    expect(find.byType(RiverShell), findsNothing);
    expect(tester.takeException(), isNull);
  });

  testWidgets('Back dismisses a dialog before opening the sidebar', (
    tester,
  ) async {
    await phone(tester);
    await pushShell(tester, signedIn());
    showDialog<void>(
      context: tester.element(find.byType(RiverShell)),
      builder: (_) => const AlertDialog(title: Text('Dialog')),
    );
    await tester.pumpAndSettle();
    await back(tester);
    expect(find.text('Dialog'), findsNothing);
    expect(shell(tester).isDrawerOpen, isFalse);
    await back(tester);
    expect(shell(tester).isDrawerOpen, isTrue);
  });

  testWidgets('a detail route above River keeps its normal Back behavior', (
    tester,
  ) async {
    await phone(tester);
    final navigator = await pushShell(tester, signedIn());
    navigator.currentState!.push<void>(
      MaterialPageRoute(
        builder: (_) => const Scaffold(body: Text('Detail view')),
      ),
    );
    await tester.pumpAndSettle();
    await back(tester);
    expect(find.text('Detail view'), findsNothing);
    expect(shell(tester).isDrawerOpen, isFalse);
    await back(tester);
    expect(shell(tester).isDrawerOpen, isTrue);
  });

  testWidgets('wide layouts go back immediately with the sidebar visible', (
    tester,
  ) async {
    await tester.binding.setSurfaceSize(const Size(1200, 900));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    await pushShell(tester, signedIn());
    expect(find.byType(Drawer), findsNothing);
    await back(tester);
    expect(find.text('Previous view'), findsOneWidget);
    expect(find.byType(RiverShell), findsNothing);
  });

  testWidgets('signed-out River keeps its normal Back behavior', (
    tester,
  ) async {
    await phone(tester);
    await pushShell(tester, RiverApi(live: false)..loading = false);
    await back(tester);
    expect(find.text('Previous view'), findsOneWidget);
    expect(find.byType(RiverShell), findsNothing);
  });
}
