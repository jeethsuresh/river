import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_quill/flutter_quill.dart' as q;
import 'package:flutter_test/flutter_test.dart';
import 'package:river/api.dart';
import 'package:river/rich_composer.dart';
import 'package:river/workspace_widgets.dart';
import 'matrix_messaging_test.dart' show MemoryMatrixStorage, matrixProfile;

void main() {
  test(
    'Enter defaults to send and an opt-out survives restart for only that account',
    () async {
      final storage = MemoryMatrixStorage();
      RiverApi api(String sub) =>
          RiverApi(live: false, matrixStorage: storage)
            ..user = {...matrixProfile, 'sub': sub};
      final alice = api('alice');
      expect(alice.enterSendsMessages, true);
      await alice.setEnterSendsMessages(false);
      expect(alice.enterSendsMessages, false);
      final restored = api('alice');
      await restored.loadMessagingPreferences();
      expect(restored.enterSendsMessages, false);
      final bob = api('bob');
      await bob.loadMessagingPreferences();
      expect(bob.enterSendsMessages, true);
      await restored.setEnterSendsMessages(true);
      await alice.loadMessagingPreferences();
      expect(alice.enterSendsMessages, true);
      for (final value in [alice, restored, bob]) {
        value.dispose();
      }
    },
  );

  testWidgets('Settings toggle saves and updates without closing settings', (
    tester,
  ) async {
    final api = RiverApi(live: false, matrixStorage: MemoryMatrixStorage())
      ..user = Map.of(matrixProfile);
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(body: AccountPanel(app: api)),
      ),
    );
    final toggle = find.byKey(const ValueKey('enter-sends-messages'));
    expect(tester.widget<SwitchListTile>(toggle).value, true);
    await tester.tap(toggle);
    await tester.pumpAndSettle();
    expect(tester.widget<SwitchListTile>(toggle).value, false);
    expect(api.enterSendsMessages, false);
    await tester.pumpWidget(const SizedBox());
    api.dispose();
  });

  for (final mode in ['Write', 'Markdown']) {
    testWidgets(
      '$mode desktop Enter sends once, Shift+Enter inserts a line, opt-out restores newline',
      (tester) async {
        final controller = TextEditingController(text: 'Hello');
        var submits = 0;
        var sendOnEnter = true;
        late StateSetter rebuild;
        await tester.pumpWidget(
          MaterialApp(
            home: Scaffold(
              body: StatefulBuilder(
                builder: (context, setState) {
                  rebuild = setState;
                  return RichComposer(
                    controller: controller,
                    sendOnEnter: sendOnEnter,
                    onSubmit: () => submits++,
                  );
                },
              ),
            ),
          ),
        );
        await tester.pumpAndSettle();
        if (mode == 'Markdown') {
          await tester.tap(find.text('Markdown'));
          await tester.pumpAndSettle();
        }
        if (mode == 'Write') {
          final editor = tester.widget<q.QuillEditor>(
            find.byType(q.QuillEditor),
          );
          editor.focusNode.requestFocus();
          editor.controller.updateSelection(
            const TextSelection.collapsed(offset: 5),
            q.ChangeSource.local,
          );
        } else {
          await tester.tap(find.byType(TextField));
        }
        await tester.pumpAndSettle();
        await tester.sendKeyEvent(LogicalKeyboardKey.enter);
        await tester.pump();
        expect(submits, 1);
        expect(controller.text, 'Hello');
        await tester.sendKeyDownEvent(LogicalKeyboardKey.shiftLeft);
        await tester.sendKeyEvent(LogicalKeyboardKey.enter);
        await tester.sendKeyUpEvent(LogicalKeyboardKey.shiftLeft);
        await tester.pumpAndSettle();
        expect(submits, 1);
        // The framework lets Shift+Enter reach the platform text input.
        // Emulate the newline the platform delivers after that key event.
        tester.testTextInput.updateEditingValue(
          TextEditingValue(
            text: mode == 'Write' ? 'Hello\nnext\n' : 'Hello\nnext',
            selection: TextSelection.collapsed(offset: 10),
          ),
        );
        await tester.pumpAndSettle();
        expect(
          controller.text,
          allOf(contains('Hello'), contains('next'), contains('\n')),
        );
        rebuild(() => sendOnEnter = false);
        await tester.pumpAndSettle();
        await tester.sendKeyEvent(LogicalKeyboardKey.enter);
        await tester.pumpAndSettle();
        expect(submits, 1);
        await tester.sendKeyDownEvent(LogicalKeyboardKey.controlLeft);
        await tester.sendKeyEvent(LogicalKeyboardKey.enter);
        await tester.sendKeyUpEvent(LogicalKeyboardKey.controlLeft);
        await tester.pumpAndSettle();
        expect(submits, 2);
        await tester.pumpWidget(const SizedBox());
        await tester.pump(const Duration(milliseconds: 600));
        controller.dispose();
      },
      variant: TargetPlatformVariant.desktop(),
    );

    testWidgets(
      '$mode mobile Enter stays a newline even with desktop sending enabled',
      (tester) async {
        final controller = TextEditingController(text: 'Phone');
        var submits = 0;
        await tester.pumpWidget(
          MaterialApp(
            home: Scaffold(
              body: RichComposer(
                controller: controller,
                sendOnEnter: true,
                onSubmit: () => submits++,
              ),
            ),
          ),
        );
        await tester.pumpAndSettle();
        if (mode == 'Markdown') {
          await tester.tap(find.text('Markdown'));
          await tester.pumpAndSettle();
          await tester.tap(find.byType(TextField));
        } else {
          tester
              .widget<q.QuillEditor>(find.byType(q.QuillEditor))
              .focusNode
              .requestFocus();
        }
        await tester.pumpAndSettle();
        await tester.sendKeyEvent(LogicalKeyboardKey.enter);
        await tester.pumpAndSettle();
        expect(submits, 0);
        await tester.pumpWidget(const SizedBox());
        await tester.pump(const Duration(milliseconds: 600));
        controller.dispose();
      },
      variant: const TargetPlatformVariant({
        TargetPlatform.android,
        TargetPlatform.iOS,
      }),
    );

    testWidgets('$mode Enter does not send an active IME composition', (
      tester,
    ) async {
      final controller = TextEditingController(text: 'hello');
      var submits = 0;
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: RichComposer(
              controller: controller,
              sendOnEnter: true,
              onSubmit: () => submits++,
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      if (mode == 'Markdown') {
        await tester.tap(find.text('Markdown'));
        await tester.pumpAndSettle();
        await tester.tap(find.byType(TextField));
      } else {
        tester
            .widget<q.QuillEditor>(find.byType(q.QuillEditor))
            .focusNode
            .requestFocus();
      }
      await tester.pumpAndSettle();
      tester.testTextInput.updateEditingValue(
        const TextEditingValue(
          text: 'hello',
          selection: TextSelection.collapsed(offset: 5),
          composing: TextRange(start: 0, end: 5),
        ),
      );
      await tester.pump();
      await tester.sendKeyEvent(LogicalKeyboardKey.enter);
      await tester.pumpAndSettle();
      expect(submits, 0);
      tester.testTextInput.updateEditingValue(
        const TextEditingValue(
          text: 'hello',
          selection: TextSelection.collapsed(offset: 5),
        ),
      );
      await tester.pumpAndSettle();
      await tester.pumpWidget(const SizedBox());
      await tester.pump(const Duration(milliseconds: 600));
      controller.dispose();
    }, variant: TargetPlatformVariant.desktop());
  }
}
